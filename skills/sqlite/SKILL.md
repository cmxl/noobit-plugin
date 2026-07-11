---
name: sqlite
description: Use when working with SQLite — slow queries, EXPLAIN QUERY PLAN, index design, query rewrites and verifying they return identical data, WAL/locking/busy errors, or embedding SQLite in a .NET app via Microsoft.Data.Sqlite.
---

# SQLite

## Overview

Provider-specific SQLite knowledge: performance workflows, index design, join correctness, and the mandatory data-equivalence check for query rewrites. ORM-level patterns (EF Core vs Dapper) live in `data-access`. SQLite is embedded and single-writer — most "performance problems" are transaction handling, not query speed.

## Performance improvement workflow

1. **Transactions first.** The most common SQLite fix: batch writes into one transaction. N individual inserts = N fsyncs; one transaction = one. This routinely turns minutes into milliseconds.
2. **Pragmas baseline**: `journal_mode=WAL` (readers don't block the writer), `synchronous=NORMAL` (safe with WAL), `busy_timeout` set (never let `SQLITE_BUSY` bubble as a crash). `PRAGMA optimize;` before closing short-lived connections; long-lived connections run `PRAGMA optimize=0x10002;` on open plus periodic `PRAGMA optimize;`.
3. **Measure**: `EXPLAIN QUERY PLAN <query>` — look for `SCAN` on large tables where `SEARCH ... USING INDEX` is expected, and `USE TEMP B-TREE` for ORDER BY/GROUP BY that an index could satisfy. The CLI's `.expert` mode suggests indexes for a query.
4. **Statistics**: `ANALYZE` (with `SQLITE_ENABLE_STAT4` where available) so the planner has real selectivity data; re-run after data-shape changes.
5. **Fix one thing**, re-check the plan. In hot loops, reuse the same parameterized `SqliteCommand` object — subsequent executions reuse the first compilation.
6. **If the query text changed, run the data-equivalence check below before shipping.**

## Query rewrite → data-equivalence check (mandatory)

A rewritten query must return the **same rows, same columns, same values**. Prove it:

1. **Row count**: `SELECT COUNT(*)` of old vs new must match.
2. **Column shape**: compare the prepared statement's column names/declared types (in .NET: `SqliteDataReader.GetName(i)`/`GetDataTypeName(i)` across both readers; in the CLI: `.mode column` headers or `pragma table_info` for table-backed shapes).
3. **Cell-level data** — SQLite's `EXCEPT` is set-based (dedups), so make rows unique by **including a unique key column** in both queries, then compare both directions:

```sql
SELECT 'only_in_old' AS side, * FROM (<old query> EXCEPT <new query>)
UNION ALL
SELECT 'only_in_new' AS side, * FROM (<new query> EXCEPT <old query>);
-- must return 0 rows
```

   If no unique key exists in the result, group both sides by all columns with `COUNT(*)` and compare the grouped sets instead — duplicates differ invisibly under plain `EXCEPT`.
4. **No built-in hash aggregate**: for large sets compare via the EXCEPT pattern, or checksum in the app layer (read both, hash ordered rows). `total()`/`sum()` per numeric column is a cheap first-pass signal only.
5. Mind **type affinity**: `'1'` and `1` can compare equal in some contexts and differ in others — keep column types consistent rather than relying on affinity coercion.

## Joins — no cartesian explosions

- Join predicates must cover the **complete** key — composite keys need every column. A missing column silently multiplies rows.
- Detect fan-out: result count far above the largest input table; repeated parent values in output. `EXPLAIN QUERY PLAN` showing a `SCAN` on the inner table of a nested loop with no index is both a correctness smell and a performance killer (SQLite only implements nested-loop joins — a bad join is O(N×M)).
- Aggregating over a fanned-out join double-counts — aggregate in a subquery *before* joining, or `COUNT(DISTINCT key)` knowingly.
- Comma joins and implicit cross joins are a review failure; `CROSS JOIN` in SQLite additionally **forces** join order (documented behavior) — only use it when that's intended.
- EF note: multiple collection `Include`s in single-query mode = cartesian product — `AsSplitQuery()` (see `data-access`).

## Index design rules

- `INTEGER PRIMARY KEY` **is** the rowid — the fastest possible key; don't add `AUTOINCREMENT` unless you truly need no-reuse guarantees (it adds overhead).
- Composite index order: equality columns first, then at most one range column — same left-prefix rule as everywhere. One index per query shape usually beats many single-column indexes (SQLite typically picks one index per table per query).
- **Covering indexes** (all selected columns in the index) avoid the table lookup entirely — visible as `USING COVERING INDEX` in the plan.
- **Partial indexes** (`WHERE deleted = 0`) and **expression indexes** (`ON t(lower(email))`) are fully supported — the query predicate must match the expression exactly.
- `WITHOUT ROWID` tables for large composite-natural-key lookup tables (saves the rowid indirection); measure, don't default to it.
- `LIKE 'abc%'` only uses an index with case-sensitivity alignment (`PRAGMA case_sensitive_like` or a `COLLATE NOCASE` index matching the column's collation).
- Indexes tax the single writer — prune unused ones; verify usage via `EXPLAIN QUERY PLAN` on your real query set.

## Common mistakes

| Mistake | Fix |
|---|---|
| Row-by-row inserts, no transaction | One transaction per batch — the classic SQLite fix |
| `SQLITE_BUSY` crashes under concurrency | `busy_timeout` pragma + WAL; one writer by design |
| Treating it as a network DB (chatty N+1 fear) | Local N+1 is cheap — but transactions still matter |
| `AUTOINCREMENT` by default | Plain `INTEGER PRIMARY KEY` |
| Relying on type affinity coercion | Declare and insert consistent types |
| Multiple connections sharing one `SqliteConnection` object | Connections are not thread-safe; one per unit of work (pooling is built in) |
| Rewrite shipped because "it looks equivalent" | Run the data-equivalence check above |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- SQLite docs: https://sqlite.org/docs.html
- Query optimizer overview: https://sqlite.org/optoverview.html
- Query planner: https://sqlite.org/queryplanner.html
- Microsoft.Data.Sqlite: https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before tuning or rewriting queries.**
