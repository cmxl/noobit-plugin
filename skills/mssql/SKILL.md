---
name: mssql
description: Use when working with SQL Server (MSSQL) — slow T-SQL queries, execution plans, index design, query rewrites and verifying they return identical data, blocking/locking, parameter sniffing, or tuning SQL Server for an ASP.NET Core app.
---

# SQL Server (MSSQL)

## Overview

Provider-specific SQL Server knowledge: performance workflows, index design, join correctness, and the mandatory data-equivalence check for query rewrites. ORM-level patterns (EF Core vs Dapper) live in `data-access`.

## Performance improvement workflow

Never tune blind — one change at a time, measured before and after:

1. **Reproduce with realistic volume.** A query that's fast on 1k rows tells you nothing about 10M.
2. **Measure**: actual execution plan (not estimated), plus `SET STATISTICS IO, TIME ON` for logical reads. On 2016+, Query Store (`ALTER DATABASE ... SET QUERY_STORE = ON`) finds regressed and top-resource queries historically.
3. **Identify the dominant issue** in the plan: scans where seeks are expected, key lookups in loops, hash/sort spills to tempdb (warnings), implicit conversion warnings, huge row-estimate skew (stale statistics or non-SARGable predicates).
4. **Fix one thing** (index, rewrite, statistics), re-measure logical reads — the stable metric; duration is noisy.
5. **If the query text changed, run the data-equivalence check below before shipping.**

## Query rewrite → data-equivalence check (mandatory)

A rewritten query must return the **same rows, same columns, same values**. Prove it, don't eyeball it:

1. **Row count**: `SELECT COUNT(*)` of old vs new must match.
2. **Column shape**: `EXEC sp_describe_first_result_set N'<query>'` for both — names, types, nullability must match.
3. **Cell-level data** — SQL Server has no `EXCEPT ALL`, and plain `EXCEPT` dedups (hides duplicate-row differences). Compare with grouped counts:

```sql
WITH old_q AS (<old query>), new_q AS (<new query>),
o AS (SELECT *, COUNT(*) AS cnt FROM old_q GROUP BY <all columns>),
n AS (SELECT *, COUNT(*) AS cnt FROM new_q GROUP BY <all columns>)
SELECT * FROM o FULL OUTER JOIN n ON <all o.cols = n.cols incl. cnt>
WHERE o.<key> IS NULL OR n.<key> IS NULL;   -- must return 0 rows
```

   When the result contains a unique key (making duplicates impossible), two-way `EXCEPT` is sufficient: `(old EXCEPT new) UNION ALL (new EXCEPT old)` → 0 rows. `EXCEPT` treats NULLs as equal — that's what you want here.
4. **Large sets**: `HASHBYTES('SHA2_256', ...)` over concatenated ordered rows, or `CHECKSUM_AGG(CHECKSUM(*))` as a cheap first pass only — `CHECKSUM` has real collision risk; a matching checksum is a hint, a mismatch is proof.
5. Comparisons are order-independent; `ORDER BY` differences only matter if the consumer depends on order — then compare with `ROW_NUMBER()` included.

## Joins — no cartesian explosions

- Every join predicate must cover the **complete** key — composite keys need every column (`ON a.TenantId = b.TenantId AND a.Id = b.OrderId`). A missing column silently multiplies rows.
- Detect fan-out: result count far above the largest base table, or repeated parent values in the output. Sanity-check counts per join as you compose.
- Aggregating over a fanned-out join double-counts — aggregate in a subquery/CTE *before* joining, or use `COUNT(DISTINCT key)` knowingly.
- `CROSS JOIN` only ever explicit and commented. Old-style comma joins are a review failure.
- EF note: multiple collection `Include`s in single-query mode = cartesian product — `AsSplitQuery()` (see `data-access`).

## Index design rules

- **Clustered index**: narrow, unique, non-volatile, ever-increasing (identity, sequential values). Random GUIDs as clustered keys cause fragmentation and page splits — use `NEWSEQUENTIALID()` or a surrogate int if GUIDs are required externally.
- **Nonclustered**: key columns = equality predicates first (most selective order), then range predicates; everything the query additionally selects goes in `INCLUDE(...)` to make it covering and kill key lookups.
- **Filtered indexes** (`WHERE IsDeleted = 0`, sparse statuses) for hot subsets — smaller, cheaper to maintain.
- Every index taxes writes. Prune with `sys.dm_db_index_usage_stats` (reads vs writes); the missing-index DMVs suggest, never blindly create (they over-include and ignore overlaps).
- Foreign key columns almost always deserve a nonclustered index (joins + cascades).
- Maintenance: fragmentation matters less on SSDs than folklore says; keep statistics fresh (`AUTO_UPDATE_STATISTICS` on; manual `UPDATE STATISTICS` after bulk loads).

## Common mistakes

| Mistake | Fix |
|---|---|
| `WHERE YEAR(OrderDate) = 2026` (non-SARGable) | Range predicate: `>= '2026-01-01' AND < '2027-01-01'` |
| `nvarchar` parameter vs `varchar` column | Implicit conversion → scan; match types exactly (Dapper: `DbString` with `IsAnsi`) |
| `NOLOCK` everywhere | Dirty/duplicate/missing reads; enable RCSI (`READ_COMMITTED_SNAPSHOT ON`) instead |
| Parameter sniffing bites a hot proc | Diagnose first; `OPTION (RECOMPILE)` for volatile predicates, `OPTIMIZE FOR` sparingly |
| Random GUID clustered PK | Sequential key; GUID as nonclustered unique |
| `SELECT *` in production queries | Explicit columns — enables covering indexes, stable contracts |
| Rewrite shipped because "it looks equivalent" | Run the data-equivalence check above |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- SQL Server docs: https://learn.microsoft.com/en-us/sql/
- Index architecture & design guide: https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide
- Query Store: https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before tuning or rewriting queries.**
