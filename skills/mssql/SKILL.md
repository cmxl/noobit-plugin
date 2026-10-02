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

### Reading `.sqlplan` exports

When given a `.sqlplan` file (SSMS / Query Store / Azure Data Studio export), first check whether the repo has a local plan-analyzer script — prefer it over hand-parsing the plan XML, and extend it rather than working around it. Whatever the tooling, the highest-value signals in a plan:
- `ParameterCompiledValue` vs `ParameterRuntimeValue` side by side — a large mismatch is the parameter-sniffing signature.
- Per-operator `ActualRowsRead` vs `ActualRows` (attributes of `RunTimeCountersPerThread`; estimated plans carry `EstimatedRowsRead` vs `EstimateRows` on the `RelOp`): rows read ≥ 10× rows returned means the predicate sits in the residual filter instead of the seek — fix key order or add the column to the index key.
- Warnings elements: spills, `PlanAffectingConvert` (implicit conversion), `NoJoinPredicate` (cartesian!), `ColumnsWithNoStatistics`, excessive memory grants.
- `StatementOptmEarlyAbortReason="TimeOut"` — the optimizer gave up; the plan may be far from optimal even if it looks reasonable.

## Query rewrite → data-equivalence check (mandatory)

A rewritten query must return the **same rows, same columns, same values**. Prove it, don't eyeball it:

1. **Row count**: `SELECT COUNT(*)` of old vs new must match.
2. **Column shape**: `EXEC sp_describe_first_result_set N'<query>', N'@p1 int, @p2 varchar(20)'` for both — names, types, nullability must match. Pass the second argument (`@params`) with the exact parameter declarations the app sends: untyped parameters fail with error 11521 or get inferred types that can differ from production.
3. **Cell-level data** — SQL Server has no `EXCEPT ALL`, and plain `EXCEPT` dedups (hides duplicate-row differences). Compare grouped counts; `=` never matches NULL to NULL, so join with `EXISTS … INTERSECT` (NULL-safe, any version):

```sql
WITH old_q AS (<old query>), new_q AS (<new query>),
o AS (SELECT c1, c2, COUNT(*) AS cnt FROM old_q GROUP BY c1, c2),
n AS (SELECT c1, c2, COUNT(*) AS cnt FROM new_q GROUP BY c1, c2)
SELECT * FROM o FULL OUTER JOIN n
  ON EXISTS (SELECT o.c1, o.c2, o.cnt INTERSECT SELECT n.c1, n.c2, n.cnt)
WHERE o.cnt IS NULL OR n.cnt IS NULL;   -- cnt is never NULL on a matched side; must return 0 rows
```

   The `EXISTS … INTERSECT` join has no equality the optimizer can hash or merge on (nested loops, ~O(N×M)) — put plain `=` on NOT NULL columns in the `ON` clause and keep `INTERSECT` for the nullable ones, or switch to step 4 for large sets. On 2022+ `o.c1 IS NOT DISTINCT FROM n.c1 AND …` is equivalent. List every column explicitly. `xml`, `text`/`ntext`/`image` can't be grouped or `INTERSECT`ed — compare `CONVERT(nvarchar(max), col)` instead. Strip `ORDER BY` from the old/new queries (a CTE rejects it without `TOP`/`OFFSET`).
   When the result contains a unique key (making duplicates impossible), two-way `EXCEPT` is sufficient: `(old EXCEPT new) UNION ALL (new EXCEPT old)` → 0 rows. `EXCEPT` treats NULLs as equal — that's what you want here.
4. **Large sets**: per-row `HASHBYTES('SHA2_256', …)` joined on the key — build the input with `ISNULL` sentinels and explicit `CONVERT` styles, never `CONCAT_WS` (it drops NULLs *and* their separator, so `('a',NULL,'b')` and `('a','b',NULL)` collide); recipe in [references/best-practices.md](references/best-practices.md). `CHECKSUM_AGG(BINARY_CHECKSUM(*))` is a cheap first pass only: collision-prone, and two identical rows cancel each other out, so a matching checksum proves nothing — a mismatch is proof.
5. Comparisons are order-independent; `ORDER BY` differences only matter if the consumer depends on order — then compare with `ROW_NUMBER()` included.

## Joins — no cartesian explosions

- Every join predicate must cover the **complete** key — composite keys need every column (`ON a.TenantId = b.TenantId AND a.Id = b.OrderId`). A missing column silently multiplies rows.
- Detect fan-out: result count far above the largest base table, or repeated parent values in the output. Sanity-check counts per join as you compose.
- Aggregating over a fanned-out join double-counts — aggregate in a subquery/CTE *before* joining, or use `COUNT(DISTINCT key)` knowingly.
- `CROSS JOIN` only ever explicit and commented. Old-style comma joins are a review failure.
- EF note: multiple collection `Include`s in single-query mode = cartesian product — `AsSplitQuery()` (see `data-access`).

## Index design rules

- **Clustered index**: narrow, unique, non-volatile, ever-increasing (identity, sequential values). Random GUIDs as clustered keys cause fragmentation and page splits — prefer a surrogate `int`/`bigint` clustered key with the GUID as a unique nonclustered index. If the GUID must be the clustered key, generate it SQL-Server-sequential: `NEWSEQUENTIALID()` (only valid as a column `DEFAULT`), or let EF Core generate it (its SQL Server default for `Guid` keys is `SequentialGuidValueGenerator`). **UUIDv7 (`Guid.CreateVersion7()`) is *not* sequential for SQL Server**: `uniqueidentifier` sorts by the *last* 6 bytes first, where v7 carries random bits — it fragments like `NEWID()`.
- **Nonclustered**: key columns = equality predicates first (most selective order), then range predicates; everything the query additionally selects goes in `INCLUDE(...)` to make it covering and kill key lookups.
- **Filtered indexes** (`WHERE IsDeleted = 0`, sparse statuses) for hot subsets — smaller, cheaper to maintain.
- Every index taxes writes. Prune with `sys.dm_db_index_usage_stats` (reads vs writes) — its counters reset on every instance restart (and database detach/close), so check `sqlserver_start_time` in `sys.dm_os_sys_info` and don't drop an "unused" index on a short uptime that missed month-end jobs. The missing-index DMVs suggest, never blindly create (they over-include and ignore overlaps).
- Foreign key columns almost always deserve a nonclustered index (joins + cascades).
- Maintenance: fragmentation matters less on SSDs than folklore says; keep statistics fresh (`AUTO_UPDATE_STATISTICS` on; manual `UPDATE STATISTICS` after bulk loads).

## Blocking, deadlocks, waits

Diagnose before "fixing" with hints. Ready-to-run queries are in [references/best-practices.md](references/best-practices.md#blocking-and-deadlock-diagnostics).
- **Live blocking**: `sys.dm_exec_requests.blocking_session_id` gives the chain; find the **head blocker** (blocks others, isn't blocked) — often a session *sleeping* with an open transaction (app forgot to commit/dispose), so it has no request row; check `sys.dm_exec_sessions.open_transaction_count`. `sys.dm_tran_locks` shows what it holds.
- **Deadlocks**: the `system_health` Extended Events session (on by default in SQL Server / Managed Instance) already captures every `xml_deadlock_report` with the graph — read it before adding traces. Azure SQL Database: create a database-scoped session on `database_xml_deadlock_report`. Fix with consistent access order, shorter transactions, covering indexes; retry error 1205 in the app.
- **Lock escalation**: one statement holding ≥ 5,000 locks on one table reference escalates to a *table* lock (never page). Batch large DML below that; `ROWLOCK` hints don't prevent it. Optimized locking (on in Azure SQL Database/MI; opt-in on SQL Server 2025 with ADR) makes escalation rare.
- **Wait stats** say *what* the server waits on: `sys.dm_os_wait_stats` (cumulative since restart — diff two snapshots) or per query in Query Store (`sys.query_store_wait_stats`, 2017+).
- **RCSI** removes reader/writer blocking, but: enabling it needs no other active connections (`… SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE` kills their transactions — maintenance window); it's already ON by default in Azure SQL Database (OFF in SQL Server and MI); readers now see the last committed version instead of waiting, so code that relied on blocking (check-then-insert, hand-rolled queues) needs `UPDLOCK`/`READCOMMITTEDLOCK` or a constraint; the version store grows (tempdb, or the database when ADR is on).

## Common mistakes

| Mistake | Fix |
|---|---|
| `WHERE YEAR(OrderDate) = 2026` (non-SARGable) | Range predicate: `>= '2026-01-01' AND < '2027-01-01'` |
| `nvarchar` parameter vs `varchar` column | Implicit conversion → scan; match types exactly (EF: map `varchar` columns with `IsUnicode(false)` / `HasColumnType("varchar(n)")` so parameters match; Dapper `DbString { IsAnsi = true }` and `datetime` vs `datetime2`: `data-access/references/efcore-dapper-seam.md`) |
| `NOLOCK` everywhere | Dirty/duplicate/missing reads; enable RCSI (`READ_COMMITTED_SNAPSHOT ON`) instead — mind its side effects (see Blocking above) |
| Parameter sniffing bites a hot proc | Diagnose first; `OPTION (RECOMPILE)` for volatile predicates, `OPTIMIZE FOR` sparingly |
| Random GUID / UUIDv7 clustered PK | Sequential key; GUID as nonclustered unique |
| Deep `OFFSET … FETCH` paging | The engine still reads every skipped row — keyset pagination (`WHERE (SortCol > @last) OR (SortCol = @last AND Id > @lastId)`) with an index on the sort key |
| Connection string without `Application Name=` | EF Core 10+ injects one when missing → EF and Dapper/ADO.NET on the "same" string use different pools, and a `TransactionScope` spanning both escalates to a distributed transaction. Always set an explicit `Application Name=` (see `data-access`) — it also labels sessions in `sys.dm_exec_sessions.program_name` |
| Mass `DELETE`/`UPDATE` in one statement | Batch under 5,000 rows per statement (lock-escalation threshold), indexed predicate — see reference |
| `SELECT *` in production queries | Explicit columns — enables covering indexes, stable contracts |
| Rewrite shipped because "it looks equivalent" | Run the data-equivalence check above |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- SQL Server docs: https://learn.microsoft.com/en-us/sql/
- Index architecture & design guide: https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide
- Query Store: https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before tuning or rewriting queries.**
