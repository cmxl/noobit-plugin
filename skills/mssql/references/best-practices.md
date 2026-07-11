# SQL Server Best Practices — Performance, Indexing, Query Correctness

Verified against official documentation, July 2026. All version-specific claims below were checked against
learn.microsoft.com/sql (ver17 docs): the Index Architecture and Design Guide, Query Store docs, Statistics,
Cardinality Estimation, Intelligent Query Processing (IQP), PSP optimization, tempdb, Table Hints, and the
T-SQL function reference. Full URLs in **Sources**. This file extends `../SKILL.md` — read that first.

## Current versions (July 2026)

- **SQL Server 2025 (17.x)** is the current release: GA **November 18, 2025**, build 17.0.1000.7. Introduces
  database **compatibility level 170**. Docs moniker: `view=sql-server-ver17`.
- 2025 engine additions relevant to tuning: PSP optimization extended to **DML** (DELETE/INSERT/MERGE/UPDATE, compat 170),
  **Optional Parameter Plan Optimization (OPPO)** (compat 170), **CE feedback for expressions** (compat 160),
  **OPTIMIZED_SP_EXECUTESQL** (compilation-storm relief for `sp_executesql`), **Query Store for secondary replicas**,
  **ADR in tempdb**, **tempdb space resource governance**, native **json**/**vector** types (allowed as INCLUDE columns,
  not as index keys). Standard edition now up to 32 cores / 256 GB with Resource Governor; Express up to 50 GB/db.
- **SQL Server 2022 (16.x)** / compat 160: PSP optimization, CE feedback, DOP feedback, memory grant feedback
  percentile+persistence, optimized plan forcing, `ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY`.
- **Query Store is enabled by default** (`READ_WRITE`) for new databases starting with SQL Server 2022 and in
  Azure SQL Database / Managed Instance. Not enabled by default in 2016–2019 — turn it on.
- IQP features gate on **database compatibility level**, not just the server version
  (`ALTER DATABASE db SET COMPATIBILITY_LEVEL = 170;`). Several also require Query Store (see below).

## Established patterns

### Index design (per the official Index Architecture and Design Guide)

- Desirable clustered index key properties (verbatim doc list): **narrow, unique, ever-increasing, immutable,
  and not-nullable columns only**. A non-unique clustered key gets a hidden 4-byte uniqueifier in every index;
  the clustered key is stored inside every nonclustered index, so its width taxes all of them. An `int`/`bigint`
  identity or sequence satisfies all properties; `uniqueidentifier` is 16 bytes and only ever-increasing if
  generated sequentially. Heaps are "generally not recommended". A PRIMARY KEY defaults to clustered — declare it
  `NONCLUSTERED` if a better clustered key exists.
- Nonclustered key column order (doc wording): columns used in an **equality (=), inequality (>, >=, <, <=),
  or BETWEEN predicate, or in a join, go first**; remaining key columns ordered **most-distinct to least-distinct**.
  SARGable columns belong in the key; non-SARGable columns the query merely returns belong in `INCLUDE(...)`.
- Limits (verified): key max **32 columns**; **900 bytes clustered / 1,700 bytes nonclustered** key size
  (900 for everything up to SQL Server 2014). Included columns don't count against either limit; up to **1,023**
  INCLUDE columns. LOB types (`varchar(max)`, `nvarchar(max)`, `varbinary(max)`, `xml`, and 2025's `json`, `vector`)
  are INCLUDE-only. Don't repeat the clustered key in a nonclustered definition — it's added automatically.
- **Covering index** = query satisfied entirely from the index (key + INCLUDE) → no key lookups. But wide INCLUDE
  lists (especially MAX types) duplicate data into the leaf level; cover the hot queries, not `SELECT *`.
- **Filtered indexes**: for well-defined subsets (sparse statuses, mostly-NULL columns, `IsDeleted = 0`).
  Filter supports simple comparison operators only. A column used in the filter expression must also be a key or
  INCLUDE column **if the query returns it**. The optimizer uses a filtered index only when the query predicate
  provably selects a subset of the filter — hinting one that doesn't cover the query's rows raises error 8622.
  Filtered statistics are more accurate than full-table statistics for the subset.
- A **unique** index (vs non-unique on the same keys) gives the optimizer extra information — declare uniqueness
  when it's true.
- When the optimizer *can't* seek: predicate not on a leading key column; function/expression wrapped around the
  column; implicit conversion of the column side (type-mismatched parameter). Documented poor-estimate constructs
  (CE doc): comparing two columns of the same table, `!=`/`NOT`, functions with non-constant arguments, joining on
  arithmetic/concatenated expressions, and **local variables in predicates** (values unknown at compile time —
  use parameters, literals, or `sp_executesql`).

### Query Store — configuration

```sql
ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = AUTO);
```

Defaults (SQL Server 2019+ unless noted): `MAX_STORAGE_SIZE_MB = 1000` (100 in 2016/2017),
`QUERY_CAPTURE_MODE = AUTO` (ALL in 2016/2017 — AUTO filters out insignificant ad hoc queries; prefer it),
`INTERVAL_LENGTH_MINUTES = 60`, `DATA_FLUSH_INTERVAL_SECONDS = 900`, `STALE_QUERY_THRESHOLD_DAYS = 30`,
`SIZE_BASED_CLEANUP_MODE = AUTO`, `MAX_PLANS_PER_QUERY = 200`, `WAIT_STATS_CAPTURE_MODE = ON` (2017+).
Custom capture policy (2019+) AUTO thresholds: 30 executions, 1,000 ms total compile CPU, or 100 ms total
execution CPU within a 1-day stale-capture window.

Query Store silently flips to READ_ONLY when the size quota is hit (`readonly_reason = 65536`) — monitor it:

```sql
SELECT actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb
FROM sys.database_query_store_options;  -- actual != desired means it changed mode on its own
```

### Query Store — regression workflow

1. **Regressed Queries** / **Top Resource Consuming Queries** views in SSMS, or query
   `sys.query_store_runtime_stats` joined to `sys.query_store_plan` / `sys.query_store_query` /
   `sys.query_store_query_text`, comparing metrics across `runtime_stats_interval_id`.
2. If a query ran fast with an earlier plan and regressed after a plan change: force the good plan —
   `EXEC sp_query_store_force_plan @query_id = ..., @plan_id = ...;` (undo: `sp_query_store_unforce_plan`).
3. Forcing is not a guarantee — schema changes break it and the engine silently falls back to recompilation.
   Audit regularly: `SELECT plan_id, query_id, force_failure_count, last_force_failure_reason_desc
   FROM sys.query_store_plan WHERE is_forced_plan = 1;`
4. If estimates (not plan choice) are the problem: update statistics, fix the non-SARGable construct, or apply a
   **Query Store hint** (`sys.sp_query_store_set_hints @query_id, N'OPTION(...)'`) — hints without code changes.
5. Hygiene rules from the docs: use `ALTER PROC`, never DROP/CREATE (re-created objects get new query entries,
   losing history and forced plans); don't rename databases that have forced plans (plans reference
   `db.schema.object` — forcing starts failing); parameterize your workload or enable
   `optimize for ad hoc workloads` — unparameterized query floods blow the size quota and push QS read-only.

### Execution plan reading

- Use the **actual** execution plan (or Query Store/`sys.dm_exec_query_stats`) — only actual plans carry runtime
  information: actual row counts, resource usage, and runtime warnings. `SET STATISTICS IO, TIME ON` for logical reads.
- Operator warnings to chase first: **sort/hash spills to tempdb** (fix = better estimates or more memory —
  memory grant feedback auto-corrects repeats on compat 140+), **implicit conversion warnings** on predicates
  (type-affecting converts break seeks and estimates), **no join predicate** (accidental cartesian product),
  **excessive/insufficient memory grants**, **missing statistics**.
- **Estimate skew**: compare *Estimated* vs *Actual Number of Rows* per operator. Documented workflow: check the
  root node's `CardinalityEstimationModelVersion` property, ask whether the estimate is off by 1% or by 10x, and
  walk toward the lowest operator where the skew starts (stale stats, non-SARGable predicate, local variable,
  or CE model assumption). SSMS **"Analyze Actual Execution Plan"** automates finding inaccurate-CE scenarios.
- Costs shown on operators are the optimizer's **estimates** even in actual plans — treat percentages as hints,
  measure logical reads and per-operator actual time instead.
- Fixing estimates beats hinting: prefer up-to-date stats → SARGable rewrite → Query Store hint → forced plan →
  `LEGACY_CARDINALITY_ESTIMATION` (scoped config or `USE HINT`) as a last resort. Never lower the whole database
  compatibility level to fix one query.

### Statistics

- Keep `AUTO_CREATE_STATISTICS` and `AUTO_UPDATE_STATISTICS` ON (defaults). With auto-update OFF the engine still
  *marks* stats stale but keeps using them — documented cause of degraded plans.
- **Auto-update thresholds** (recompilation thresholds, verified): tables ≤ 500 rows → 500 modifications.
  Compat level ≤ 120 (old rule): `500 + 0.20 * n`. **Compat 130+ (all current versions):
  `MIN(500 + 0.20*n, SQRT(1000 * n))`** — e.g. a 2M-row table updates stats every 44,721 modifications instead
  of 400,500. Trace flag 2371 only matters below compat 130.
- Auto-update is triggered by a query *compiling against* stale stats, not by the writes themselves. After bulk
  loads, run `UPDATE STATISTICS` (or `sp_updatestats`) manually instead of waiting.
- `AUTO_UPDATE_STATISTICS_ASYNC` moves the stats update off the query's critical path — reasonable for OLTP with
  frequent short queries; the triggering query uses the old stats once. Temp-table stats always update synchronously.
- Sampled updates can under-represent skew; `UPDATE STATISTICS ... WITH FULLSCAN` for problem columns, and
  `PERSIST_SAMPLE_PERCENT = ON` (2016 SP1 CU4+) to pin a sampling rate for future auto-updates.

### Parameter-sensitive plans / IQP (status as of SQL Server 2025)

- **PSP optimization** (2022+, compat 160, on by default): for skewed columns, compiles a *dispatcher* plan that
  bucketizes runtime parameter cardinality (low/medium/high boundaries from the histogram) into separate cached
  *query variants* — multiple active plans for one statement, largely defusing classic parameter sniffing.
  Verified constraints: **equality predicates only**; at most **3 predicates** chosen per query (the most skewed);
  SELECT-only until 2025 — **compat 170 adds DML statements**. Variants show
  `OPTION (PLAN PER VALUE(...))` in showplan; map parents to variants via `sys.query_store_query_variant`.
  Disable per-database (`ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF`)
  or per-query (`USE HINT('DISABLE_PARAMETER_SENSITIVE_PLAN')`). `OPTION (RECOMPILE)` and disabled parameter
  sniffing both switch PSP off for that query. Query Store strongly recommended for visibility; watch
  `max_plans_per_query` (200) with many variants.
- So the classic sniffing playbook (`OPTION (RECOMPILE)`, `OPTIMIZE FOR`) is now the *fallback* for what PSP
  doesn't cover: range predicates, pre-160 compat, or residual skew.
- **OPPO** (2025, compat 170): separate optimal plans depending on whether a parameter is NULL or NOT NULL —
  fixes the `WHERE (@p IS NULL OR col = @p)`-style optional-filter pattern.
- IQP features that **require Query Store READ_WRITE**: CE feedback, DOP feedback, memory grant feedback
  (percentile/persistence), optimized plan forcing. Free wins from compat level alone: batch-mode adaptive joins
  and memory grant feedback (140), table-variable deferred compilation, scalar UDF inlining, batch mode on
  rowstore (150), CE/DOP feedback + PSP (160), OPPO + CE feedback for expressions (170).

### RCSI vs NOLOCK (as officially documented)

- `NOLOCK` = `READUNCOMMITTED`. Documented effects: dirty reads (uncommitted data, possibly rolled back), and it
  "might generate errors for your transaction, present users with data that was never committed, or cause users to
  **see records twice (or not at all)**"; error 601 (data movement) must be retried. It does *not* avoid all
  blocking — Sch-S locks are still taken, so DDL blocks NOLOCK readers and vice versa.
- NOLOCK/READUNCOMMITTED are **ignored on the target table of UPDATE/DELETE** and their use there is deprecated
  ("will be removed in a future version").
- The documented alternative, verbatim intent: minimize locking contention while protecting from dirty reads by
  using **`READ COMMITTED` with `READ_COMMITTED_SNAPSHOT ON` (RCSI)** or **`SNAPSHOT` isolation**. Both use row
  versioning in tempdb — size tempdb's version store accordingly. `READCOMMITTEDLOCK` hint opts a query back into
  locking read-committed under RCSI where write-then-read consistency demands it.

### tempdb

- What lands in tempdb: sort/hash **spill** work files, temp tables and table variables, cursors, online index
  builds (`SORT_IN_TEMPDB`), MARS, triggers, and the **version store** for RCSI/snapshot isolation.
- Data files: one per logical processor **up to 8**; beyond that add in multiples of 4 only if allocation
  contention (PAGELATCH on PFS/GAM/SGAM) persists. All files same initial size and same autogrowth (proportional
  fill breaks otherwise; `AUTOGROW_ALL_FILES` is always on for tempdb). Preallocate to workload size; enable
  instant file initialization. Setup has done multi-file tempdb by default since 2016.
- Contention relief by version: 2019 — concurrent PFS updates (always on) and opt-in **memory-optimized tempdb
  metadata** (enable only when metadata contention is proven; has limitations, e.g. no columnstore on temp tables);
  2022 — concurrent GAM/SGAM updates (always on); 2025 — **ADR in tempdb** (instant rollback, aggressive log
  truncation) and **tempdb space resource governance** (cap a workload's tempdb usage via Resource Governor).
- Monitor: `sys.dm_db_file_space_usage` (version store vs internal objects), `sys.dm_db_task_space_usage` to find
  the offending session. IQP memory-grant feedback reduces recurring spills; fixing estimates reduces them at the source.

### Verifying rewritten queries return identical data (function caveats)

The mandatory workflow (row count → `sp_describe_first_result_set` → grouped-count FULL OUTER JOIN or two-way
`EXCEPT`) is in `../SKILL.md`. Verified function facts for the large-set shortcuts:

- **HASHBYTES**: only `SHA2_256`/`SHA2_512` are non-deprecated since SQL Server 2016 (MD2/MD4/MD5/SHA/SHA1
  deprecated); the former 8,000-byte input limit was removed in 2016; returns `varbinary` (32/64 bytes).
- **CHECKSUM/BINARY_CHECKSUM/CHECKSUM_AGG** return `int` and are *not* injective. Documented caveats: "If at least
  one of the values in the expression list changes, the list checksum will **probably** change... not guaranteed";
  use `CHECKSUM` "only if your application can tolerate an occasional missed change. Otherwise, consider using
  HASHBYTES". Worse, `CHECKSUM` **ignores the nchar/nvarchar dash character** (`N'-'` → collision *guaranteed* for
  strings differing only by dashes; `CHECKSUM(N'1') = CHECKSUM(N'-1')`), trims trailing spaces, and is
  collation-dependent. Verdict: checksum match = hint only; checksum mismatch = proof of difference.

```sql
-- Cheap first pass (collision-prone), then per-row hash for a real comparison:
SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM (<query>) q;          -- hint only
SELECT Id, HASHBYTES('SHA2_256', CONCAT_WS('|', Col1, Col2, Col3)) -- NULL-safe delimited concat
FROM (<query>) q;                                                  -- join old vs new on Id, compare hashes
```

`CONCAT_WS` treats NULL as empty string — if `NULL` vs `''` must be distinguished, wrap columns with
`ISNULL(CONVERT(nvarchar(max), Col), N'~NULL~')` before concatenating, and always include a delimiter so
`('ab','c')` ≠ `('a','bc')`.

## Anti-patterns

- **`NOLOCK` as a go-faster switch** — dirty/double/missed reads and error 601 are documented behavior, not edge
  cases; deprecated on UPDATE/DELETE targets. Use RCSI or SNAPSHOT isolation.
- **Random-GUID clustered PK** — 16-byte key copied into every nonclustered index, not ever-increasing → page
  splits. Sequential surrogate key clustered; unique nonclustered on the GUID.
- **Non-SARGable predicates** — `YEAR(col) = 2026`, `LEFT(col,3) = 'ABC'`, `col + 0`, implicit conversions from
  mismatched parameter types (`nvarchar` param vs `varchar` column): all defeat seeks and wreck estimates.
- **Local variables in WHERE clauses** — documented CE blind spot (density guess, not histogram); use parameters,
  literals, or `sp_executesql`.
- **Trusting the missing-index DMVs / green plan hints verbatim** — they over-include, ignore overlap with existing
  indexes, and don't weigh write cost. Treat as input to a design, never `CREATE` verbatim.
- **Wide "just in case" INCLUDE lists** and over-indexing hot OLTP tables — every index taxes every write; docs:
  keep indexes narrow, few columns as possible; prune with `sys.dm_db_index_usage_stats`.
- **Treating a `CHECKSUM`/`CHECKSUM_AGG` match as equivalence proof** — dash-collision is guaranteed by design;
  use `HASHBYTES` or the set-based comparison.
- **DROP/CREATE instead of ALTER on procs/functions/triggers** — resets Query Store tracking and kills forced plans.
- **Renaming a database with forced plans** — forcing fails (three-part-name references), silent recompiles.
- **Unparameterized ad hoc floods** — plan cache and Query Store bloat, capture-mode fallout; parameterize, or use
  `optimize for ad hoc workloads` / forced parameterization; 2025 adds `OPTIMIZED_SP_EXECUTESQL`.
- **Fixing one regressed query by lowering database compatibility level** — loses all IQP for the whole database;
  use a Query Store hint or forced plan on the one query instead.
- **Blanket `OPTION (RECOMPILE)` on compat-160+ databases** — it opts the query out of PSP optimization and pays
  compile cost on every execution; let PSP handle equality-predicate skew first.
- **Sizing tempdb by folklore** ("always 8 files, always more") — files = logical processors capped at 8, grow in
  fours only on measured PAGELATCH contention; equal sizes or proportional fill defeats the point.

## Sources

- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/sql-server/maximum-capacity-specifications-for-sql-server?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/best-practice-with-the-query-store?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-set-options?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/statistics/statistics?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/cardinality-estimation-sql-server?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/intelligent-query-processing?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/parameter-sensitive-plan-optimization?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/analyze-an-actual-execution-plan?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/queries/hints-transact-sql-table?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/databases/tempdb-database?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/functions/hashbytes-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/functions/checksum-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2025-release-notes?view=sql-server-ver17
