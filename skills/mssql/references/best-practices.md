# SQL Server Best Practices — Performance, Indexing, Query Correctness

Verified against official documentation, October 2026. All version-specific claims below were checked against
learn.microsoft.com/sql (ver17 docs): the Index Architecture and Design Guide, Query Store docs, Statistics,
Cardinality Estimation, Intelligent Query Processing (IQP), PSP optimization, tempdb, Table Hints, and the
T-SQL function reference. Full URLs in **Sources**. This file extends `../SKILL.md` — read that first.

## Current versions (verified October 2026)

- **SQL Server 2025 (17.x)** is the current release: GA **November 18, 2025** (RTM build 17.0.1000.7). Introduces
  database **compatibility level 170**. Docs moniker: `view=sql-server-ver17`. It ships monthly-ish cumulative
  updates (CU9 in September 2026) — check the current CU/GDR at
  https://learn.microsoft.com/troubleshoot/sql/releases/sqlserver-2025/build-versions instead of trusting a number here.
- 2025 engine additions relevant to tuning: PSP optimization extended to **DML** (DELETE/INSERT/MERGE/UPDATE, compat 170),
  **Optional Parameter Plan Optimization (OPPO)** (compat 170), **CE feedback for expressions** (compat 160),
  **OPTIMIZED_SP_EXECUTESQL** (compilation-storm relief for `sp_executesql`), **Query Store for secondary replicas**,
  **ADR in tempdb**, **tempdb space resource governance**, native **json**/**vector** types (allowed as INCLUDE columns,
  not as index keys). Standard edition now up to the lesser of 4 sockets / 32 cores (24 in 2022) and a 256 GB
  buffer pool, with Resource Governor; Express up to 50 GB per database.
- **SQL Server 2022 (16.x)** / compat 160: PSP optimization, CE feedback, DOP feedback, memory grant feedback
  percentile+persistence, optimized plan forcing, `ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY`.
- **Query Store is enabled by default** (`READ_WRITE`) for new databases starting with SQL Server 2022 and in
  Azure SQL Database / Managed Instance. Not enabled by default in 2016–2019 — turn it on.
- IQP features gate on **database compatibility level**, not just the server version
  (`ALTER DATABASE db SET COMPATIBILITY_LEVEL = 170;`). Several also require Query Store (see below). **And on
  edition**: in SQL Server 2025 the feedback features (CE, DOP, memory grant), batch mode on rowstore, batch-mode
  adaptive joins, automatic tuning and Query Store on secondary replicas are **Enterprise only** (plus Enterprise Developer / Evaluation; Standard Developer = Standard); PSP, OPPO, optimized plan
  forcing, optimized `sp_executesql`, scalar UDF inlining and table-variable deferred compilation are in all
  editions. Azure SQL Database / Managed Instance have the full set.

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
  memory grant feedback auto-corrects repeats on compat 140+ — Enterprise edition or Azure SQL only, see Current
  versions; on Standard fix the estimate yourself), **implicit conversion warnings** on predicates
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
  (percentile/persistence), optimized plan forcing. Free wins from compat level alone (edition permitting — see Current versions):
  batch-mode adaptive joins and memory grant feedback (140), table-variable deferred compilation, scalar UDF inlining, batch mode on
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
  versioning in tempdb (in the database's persistent version store when ADR is on) — size it accordingly.
  `READCOMMITTEDLOCK` hint opts a query back into locking read-committed under RCSI where write-then-read
  consistency demands it.
- Turning RCSI on: "only the connection executing the `ALTER DATABASE` command is allowed in the database" —
  use `ALTER DATABASE … SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE` in a maintenance window (it rolls
  back everyone else's open transactions). Default: ON in Azure SQL Database, OFF in SQL Server and Managed
  Instance. Behavior change to review first: readers no longer wait for writers, so logic that relied on that
  wait (read-then-write checks, `SELECT TOP 1 … ` work-queue polling) races — use `UPDLOCK, HOLDLOCK` /
  `READPAST`, `READCOMMITTEDLOCK`, or a unique constraint.

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
  collation-dependent. **`CHECKSUM_AGG` is order-independent and two identical values cancel out** (tested:
  `CHECKSUM_AGG` over `5,7` equals over `5,7,9,9`) — a result set that gains or loses a *pair* of duplicate
  rows keeps the same aggregate. Verdict: checksum match = hint only; checksum mismatch = proof of difference.
  Use `BINARY_CHECKSUM` (byte-exact) rather than `CHECKSUM` (collation-aware) for the first pass.
- **`CONCAT_WS` is unsafe for row hashing**: it *skips* NULL arguments **and their separator**, so
  `CONCAT_WS('|','a',NULL,'b')` = `CONCAT_WS('|','a','b',NULL)` = `'a|b'` — identical hashes (tested).
- **Implicit/default string conversion is lossy** (`CONCAT`, `CONCAT_WS`, `CONVERT` without a style): `datetime`
  becomes style 0 `Jan  1 2026 10:00AM` (no seconds), `float` style 0 keeps at most 6 digits (`1.0000001` →
  `1`). Rows that differ in seconds or in the 7th digit hash equal (tested). Use explicit styles:
  `CONVERT(varchar(30), dt, 126)` for `datetime`/`datetime2`/`datetimeoffset`, `CONVERT(varchar(30), f, 3)` for
  `float`/`real` (lossless, 2016+), `CONVERT(varchar(max), b, 1)` for `varbinary` (implicit conversion
  reinterprets the bytes as characters); `decimal`, integers, `datetime2`/`datetimeoffset` defaults and
  strings convert exactly.

```sql
-- 1. Cheap first pass (collision-prone, duplicate pairs cancel): hint only
SELECT CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM (<query>) q;

-- 2. Per-row hash: sentinel per nullable column, explicit styles, delimiter between every column
SELECT Id,
       HASHBYTES('SHA2_256', CONCAT(
           COALESCE(Name, N'~NULL~'),                                N'|',   -- COALESCE: ISNULL would truncate the sentinel to a short column's length
           ISNULL(CONVERT(nvarchar(30), CreatedAt, 126), N'~NULL~'), N'|',
           ISNULL(CONVERT(nvarchar(30), Score, 3), N'~NULL~'),       N'|',
           ISNULL(CONVERT(nvarchar(40), Amount), N'~NULL~'))) AS RowHash
FROM (<query>) q;   -- run for old and new, FULL OUTER JOIN on Id, report rows where hashes differ or a side is missing
```

Pick a sentinel that can't occur in the data, keep the delimiter so `('ab','c')` ≠ `('a','bc')`, and still
run the grouped-count comparison from `../SKILL.md` when `Id` isn't unique.

## Ready-to-run diagnostics

Top resource consumers from Query Store. `sys.query_store_runtime_stats` has one row per plan × interval ×
execution type, so aggregate per query and weight the averages by executions (durations are microseconds):

```sql
SELECT TOP (10) q.query_id,
       SUM(rs.count_executions) AS executions,
       SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS total_duration_ms,
       SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,
       SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,
       COUNT(DISTINCT p.plan_id) AS plans,
       MAX(qt.query_sql_text) AS query_sql_text
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
JOIN sys.query_store_query q ON q.query_id = p.query_id
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
WHERE i.start_time >= DATEADD(day, -1, SYSDATETIMEOFFSET())
GROUP BY q.query_id
ORDER BY total_duration_ms DESC;   -- total = what the server actually spends; switch to avg_duration_ms for "slowest single call"
```

Azure SQL Database also has **automatic tuning**: `FORCE_LAST_GOOD_PLAN` (automatic plan correction) is on by
Azure default and forces the last good Query Store plan on a detected plan-choice regression, verifying and
reverting itself; on SQL Server 2017+ (Enterprise edition) enable it with `ALTER DATABASE CURRENT SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);`.
Check `sys.dm_db_tuning_recommendations` before forcing plans by hand.

Missing-index suggestions (treat as *hints* — the DMV over-includes columns and ignores overlapping indexes; design per the index rules above, never create verbatim):

```sql
SELECT CONVERT(decimal(18,2), migs.avg_user_impact * migs.user_seeks) AS Impact,
       OBJECT_NAME(mid.object_id) AS TableName,
       mid.equality_columns, mid.inequality_columns, mid.included_columns
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON mig.index_group_handle = migs.group_handle
JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY Impact DESC;
```

Mass deletes in batches — one giant `DELETE` escalates to a table lock and bloats the log. Keep each batch
**below 5,000 rows** (the per-statement lock-escalation threshold; Microsoft's own example uses 1,000) and make
sure the predicate is **indexed** (`CreatedAt` here) — without an index every batch scans the table, which is
slow and can itself cross the threshold:

```sql
DECLARE @cutoff datetime2 = DATEADD(day, -90, SYSUTCDATETIME()), @rows int = 1;
WHILE @rows > 0
BEGIN
    DELETE TOP (2000) FROM dbo.Logs WHERE CreatedAt < @cutoff;   -- each statement autocommits its own batch
    SET @rows = @@ROWCOUNT;
    WAITFOR DELAY '00:00:00.200';   -- let other work breathe between batches
END
```

Don't wrap the loop in one transaction (that holds every lock and all the log until the end). Under the
**FULL** recovery model the log only truncates on **log backups** — run them during a long purge or the log
still grows; under SIMPLE, checkpoints reclaim it.

### Blocking and deadlock diagnostics

Live blocking chain and the head blocker (run while it's happening; needs `VIEW SERVER STATE`, or
`VIEW DATABASE STATE` on Azure SQL Database):

```sql
-- Who waits on whom, and on what
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time AS wait_ms, r.wait_resource,
       DB_NAME(r.database_id) AS db, t.text AS running_sql
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id <> 0;

-- Head blockers: block others but are not blocked themselves; often sleeping with an open transaction
SELECT s.session_id, s.status, s.open_transaction_count, s.login_name, s.host_name, s.program_name,
       s.last_request_end_time, t.text AS last_sql
FROM sys.dm_exec_sessions s
JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) t
WHERE s.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0)
  AND s.session_id NOT IN (SELECT session_id FROM sys.dm_exec_requests WHERE blocking_session_id <> 0);

-- What a session holds / waits for
SELECT resource_type, resource_description, request_mode, request_status,
       CASE WHEN l.resource_type = 'OBJECT' THEN OBJECT_NAME(l.resource_associated_entity_id)
            ELSE OBJECT_NAME(p.object_id) END AS obj   -- OBJECT locks carry the object_id, not a hobt_id
FROM sys.dm_tran_locks l
LEFT JOIN sys.partitions p ON p.hobt_id = l.resource_associated_entity_id
WHERE l.request_session_id = <head blocker id> AND l.resource_database_id = DB_ID();
```

A `sleeping` head blocker with `open_transaction_count > 0` is an application bug (transaction not committed
or disposed, often around an `await` that threw) — fix the code; `KILL` only relieves the symptom.

Deadlock graphs already captured by `system_health` (SQL Server / Managed Instance; the ring buffer holds
recent events, the `event_file` target keeps more):

```sql
SELECT x.ev.value('@timestamp', 'datetime2') AS utc_time,
       x.ev.query('(data/value/deadlock)[1]') AS deadlock_graph   -- save as .xdl to view graphically in SSMS
FROM (SELECT CAST(st.target_data AS xml) AS target_data
      FROM sys.dm_xe_session_targets st
      JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
      WHERE s.name = N'system_health' AND st.target_name = N'ring_buffer') d
CROSS APPLY d.target_data.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') x(ev)
ORDER BY utc_time DESC;
```

Azure SQL Database has no `system_health`: `CREATE EVENT SESSION … ON DATABASE ADD EVENT
sqlserver.database_xml_deadlock_report ADD TARGET package0.ring_buffer` (or `event_file` to blob storage).
Read the graph: victim, each process's `inputbuf` and isolation level, and the resource list — the usual fixes
are touching tables in the same order everywhere, shorter transactions, and an index that turns a scan
(many locks) into a seek. Optimized locking (default in Azure SQL Database/MI) and RCSI remove most
reader/writer deadlocks; writer/writer ones remain.

Wait statistics — cumulative since restart, so snapshot twice and diff. Unfiltered, the top of the list is
background idle waits; exclude them (the list below is a starting point, not exhaustive):

```sql
SELECT TOP (15) wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
FROM sys.dm_os_wait_stats              -- Azure SQL Database: sys.dm_db_wait_stats
WHERE wait_type NOT LIKE N'SLEEP[_]%' AND wait_type NOT LIKE N'BROKER[_]%' AND wait_type NOT LIKE N'XE[_]%'
  AND wait_type NOT LIKE N'QDS[_]%' AND wait_type NOT LIKE N'SQLTRACE[_]%' AND wait_type NOT LIKE N'HADR[_]%'
  AND wait_type NOT IN (N'SOS_WORK_DISPATCHER', N'DISPATCHER_QUEUE_SEMAPHORE', N'LOGMGR_QUEUE',
      N'DIRTY_PAGE_POLL', N'LAZYWRITER_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH', N'SERVER_IDLE_CHECK',
      N'CHECKPOINT_QUEUE', N'WAITFOR', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'SP_SERVER_DIAGNOSTICS_SLEEP')
ORDER BY wait_time_ms DESC;
```

`LCK_M_*` = blocking, `PAGEIOLATCH_*` = reading from disk (missing index / memory), `CXPACKET`/`CXCONSUMER` =
parallelism (usually a symptom), `WRITELOG` = log I/O or too many tiny commits, `RESOURCE_SEMAPHORE` = memory-grant
queueing. Per query: `sys.query_store_wait_stats` (Query Store, 2017+) by `wait_category_desc`.

Lock escalation: verify with the `lock_escalation` XEvent; per table `ALTER TABLE … SET (LOCK_ESCALATION =
AUTO | TABLE | DISABLE)` exists, but shrinking the statement's lock footprint (batching, seeks instead of
scans) is the documented first choice — disabling escalation risks lock-memory exhaustion (error 1204).

## Anti-patterns

- **`NOLOCK` as a go-faster switch** — dirty/double/missed reads and error 601 are documented behavior, not edge
  cases; deprecated on UPDATE/DELETE targets. Use RCSI or SNAPSHOT isolation.
- **Random-GUID clustered PK** — 16-byte key copied into every nonclustered index, not ever-increasing → page
  splits. Sequential surrogate key clustered; unique nonclustered on the GUID. **UUIDv7 counts as random
  here**: `uniqueidentifier` comparison treats the *last six bytes* as most significant (documented for
  `SqlGuid`; tested: `ORDER BY` sorts `03000000-…-000000000001` before `01000000-…-000000000003`), and v7 puts
  its timestamp in the *first* bytes. `NEWSEQUENTIALID()` (column `DEFAULT` only) and EF Core's default
  `SequentialGuidValueGenerator` produce SQL-Server-ordered values.
- **Non-SARGable predicates** — `YEAR(col) = 2026`, `LEFT(col,3) = 'ABC'`, `col + 0`, implicit conversions from
  mismatched parameter types (`nvarchar` param vs `varchar` column): all defeat seeks and wreck estimates.
- **Local variables in WHERE clauses** — documented CE blind spot (density guess, not histogram); use parameters,
  literals, or `sp_executesql`.
- **Trusting the missing-index DMVs / green plan hints verbatim** — they over-include, ignore overlap with existing
  indexes, and don't weigh write cost. Treat as input to a design, never `CREATE` verbatim.
- **Wide "just in case" INCLUDE lists** and over-indexing hot OLTP tables — every index taxes every write; docs:
  keep indexes narrow, few columns as possible; prune with `sys.dm_db_index_usage_stats`.
- **Treating a `CHECKSUM`/`CHECKSUM_AGG` match as equivalence proof** — dash-collision is guaranteed by design,
  duplicate pairs cancel in `CHECKSUM_AGG`; use `HASHBYTES` or the set-based comparison.
- **Hashing rows via `CONCAT_WS` or default conversions** — NULLs vanish with their separator, `datetime`
  loses seconds, `float` keeps 6 digits; different rows hash equal. Use the sentinel + explicit-style recipe.
- **Equality joins in a NULL-bearing diff** — `o.col = n.col` never matches NULLs, so every row with a NULL
  shows up as "missing" on both sides; join with `EXISTS (SELECT … INTERSECT SELECT …)` or `IS NOT DISTINCT FROM`.
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
- https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2025/build-versions
- https://learn.microsoft.com/en-us/troubleshoot/sql/releases/download-and-install-latest-updates
- https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2025?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/functions/concat-ws-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/functions/cast-and-convert-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/functions/checksum-agg-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/t-sql/queries/is-distinct-from-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide?view=sql-server-ver17
- https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/resolve-blocking-problems-caused-lock-escalation
- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-deadlocks-guide?view=sql-server-ver17
- https://learn.microsoft.com/en-us/azure/azure-sql/database/analyze-prevent-deadlocks
- https://learn.microsoft.com/en-us/sql/relational-databases/performance/optimized-locking?view=sql-server-ver17
- https://learn.microsoft.com/en-us/sql/relational-databases/automatic-tuning/automatic-tuning?view=sql-server-ver17
- https://learn.microsoft.com/en-us/azure/azure-sql/database/automatic-tuning-overview
- https://learn.microsoft.com/en-us/sql/t-sql/functions/newsequentialid-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/dotnet/framework/data/adonet/sql/comparing-guid-and-uniqueidentifier-values
- https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.valuegeneration.sequentialguidvaluegenerator
- https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-usage-stats-transact-sql?view=sql-server-ver17
- https://learn.microsoft.com/en-us/ef/core/querying/pagination
- https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-10.0/breaking-changes
