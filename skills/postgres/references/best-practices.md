# PostgreSQL Best Practices — Performance, Indexing, Query Correctness

Verified against official documentation, July 2026. Sources: PostgreSQL 18 manual (docs/current), PostgreSQL 18 release notes and versioning policy, Npgsql official docs. Full URLs in "Sources" at the end. Extends `SKILL.md` (workflow, equivalence check, join rules) with verified detail — read that first.

## Current versions (July 2026)

- **PostgreSQL 18 is current** (18.4; released 2025-09-25, EOL 2030-11-14). Supported majors: 14 (EOL **2026-11-12** — plan upgrades now), 15, 16, 17, 18. **PostgreSQL 19 Beta 1** released 2026-06-04 — not for production.
- PG 18 performance-relevant changes (release notes):
  - **Asynchronous I/O subsystem**: `io_method` (default `worker`; `io_uring` on Linux builds with liburing; `sync` for old behavior), `io_workers` (default 3). Covers sequential scans, bitmap heap scans, and vacuum; up to ~3x faster reads from storage. `effective_io_concurrency` default is now 16.
  - **B-tree skip scan**: multicolumn B-tree usable when `=` on a prefix column is omitted (helps, but proper column order still wins).
  - Hash join / `GROUP BY` performance and memory improvements (also speeds hashed `EXCEPT`); merge joins can use incremental sort; faster multi-relation locking; **parallel GIN index builds**.
  - `EXPLAIN ANALYZE` now **implies `BUFFERS`** (use `BUFFERS OFF` to suppress).
  - Vacuum can eagerly freeze all-visible pages (`vacuum_max_eager_freeze_failure_rate`), cutting later aggressive-freeze spikes.
- **Npgsql 10.0 is the current stable** .NET driver (drops .NET 6; OpenTelemetry-aligned tracing/metrics; `date`/`time` now map to `DateOnly`/`TimeOnly`).

## Established patterns

### Reading EXPLAIN (ANALYZE, BUFFERS)

- `cost=startup..total` in arbitrary units (`seq_page_cost`=1.0, `cpu_tuple_cost`=0.01); a node's cost **includes all children**. `rows` is the estimated count **emitted** by the node (after filtering), not rows scanned; `width` is average row bytes.
- With `ANALYZE`: `actual time=.. rows=N loops=L` — time and rows are **per-loop averages; multiply by `loops` for totals**. A nested-loop inner index scan with `loops=10000` is where the time went even if per-loop time looks tiny.
- **Estimated vs actual rows skew is the first read**: order-of-magnitude gaps mean stale stats (`ANALYZE`), insufficient `default_statistics_target`, correlated columns (see extended statistics), or non-plannable predicates.
- `Buffers: shared hit=X read=Y dirtied=Z written=W` — counts for the node **and its children**; `hit` = found in `shared_buffers`, `read` = came from OS/disk. `temp read/written` = spill to temp files (sort/hash exceeded `work_mem` — plan shows "external merge Disk: NkB"; raise `work_mem` for the session and re-measure).
- Node vocabulary: Seq Scan, Index Scan, Index Only Scan, Bitmap Index/Heap Scan; Nested Loop, Hash Join, Merge Join; Sort, Incremental Sort, Memoize, Materialize, Gather/Gather Merge; SubPlan vs InitPlan.
- Annotated shape of a typical problem plan:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- Hash Join (cost=... rows=120 ...) (actual ... rows=48210 loops=1)  <- 400x misestimate: fix stats first
--   Buffers: shared hit=1520 read=8710                               <- mostly cold reads: cache/index question
--   -> Seq Scan on orders (...) Filter: (status = 'open')
--        Rows Removed by Filter: 2400000                             <- selective predicate + seq scan => index candidate
--   -> Hash (...) Buckets: ... Batches: 8                            <- Batches > 1 = hash spilled to disk (work_mem)
```

- Documented caveats: `BitmapAnd`/`BitmapOr` always report actual rows=0 (implementation limitation); nodes under `LIMIT` stop early so low actual rows there is normal; `EXPLAIN ANALYZE` excludes network transmission and adds timing overhead (check with `pg_test_timing`); `Execution Time` excludes parse/rewrite/plan. Don't extrapolate a plan measured on a small table to a big one — cost curves aren't linear.

### Planner statistics and CREATE STATISTICS

- `ANALYZE` populates `pg_statistic` (inspect via `pg_stats`). `default_statistics_target` = **100**; raise per column where estimates are bad, then re-`ANALYZE`:

```sql
ALTER TABLE orders ALTER COLUMN customer_id SET STATISTICS 500;
ANALYZE orders;
```

- The planner assumes columns are **independent**; correlated predicates multiply selectivities and underestimate rows → wrong join order/strategy. Fix with extended statistics (then `ANALYZE`):

```sql
CREATE STATISTICS s_geo (dependencies) ON city, zip FROM addresses;   -- one column implies another; equality/IN only
CREATE STATISTICS s_grp (ndistinct)    ON city, state FROM addresses; -- fixes GROUP BY a, b group-count estimates
CREATE STATISTICS s_mcv (mcv)          ON city, state FROM addresses; -- common combos; strongest fix for WHERE underestimates
ANALYZE addresses;
```

- Documented limits: `dependencies` applies only to simple `=` and `IN` clauses (not ranges, `LIKE`, column-to-column). Create these only for column combinations that actually co-occur in queries — each one costs `ANALYZE` and planning time.

### Index types — documented use cases

| Type | Use for | Notes |
|---|---|---|
| B-tree (default) | `<, <=, =, >=, >`, `BETWEEN`, `IN`, `IS NULL`, sorted output | `LIKE 'foo%'`/`~ '^foo'` only when anchored at start and C-collation-compatible (else `text_pattern_ops`); PG18 skip scan relaxes prefix-`=` requirement |
| Hash | `=` only | Stores 32-bit hash; smaller than B-tree for long values, equality-only |
| GiST | Geometry, ranges, exclusion constraints; `ORDER BY col <-> point` nearest-neighbor | Extensible framework |
| SP-GiST | Quadtrees/radix trees — points, IP ranges, text prefixes; also KNN | Non-balanced structures |
| GIN | "Multiple component values": arrays (`@>`, `&&`), `jsonb` containment, full-text | Parallel builds in PG18 |
| BRIN | Huge tables where values correlate with physical row order (append-only timestamps) | Stores min/max per block range; tiny |

- `LIKE '%abc'` never uses B-tree; use trigram GIN (`pg_trgm`) as in SKILL.md.

### Index-only scans, visibility map, INCLUDE

- Requirements: index type supports it (**B-tree always**; GiST/SP-GiST some opclasses; GIN/BRIN/hash never) and the query references **only columns stored in the index**.
- Even then it only pays off when heap pages are **all-visible in the visibility map** — otherwise each row falls back to a heap check ("Heap Fetches" in EXPLAIN ANALYZE). Only VACUUM sets those bits: high `Heap Fetches` ⇒ vacuum the table / tune autovacuum, not add more indexes.
- `INCLUDE` payload columns: not searchable/sortable, uniqueness applies to key columns only, **B-tree, GiST and SP-GiST only, no expressions in INCLUDE**. Docs advise being conservative — wide payloads bloat the index and can hit the index-tuple size limit; payload only helps if the table changes slowly enough that heap access is actually skipped.
- Expression-index caveat: the planner only considers index-only scans when all needed *columns* come from the index — `CREATE INDEX ON tab (f(x)) INCLUDE (x)` works around `SELECT f(x)` queries.

### CREATE INDEX CONCURRENTLY (production DDL)

- Performs **two table scans** and waits out every transaction that could modify the table (and, for the final validation, transactions with older snapshots) — long-running transactions stall it. Cannot run inside a transaction block (so: separate EF Core migration with `suppressTransaction: true`, or run manually).
- On failure it leaves an **`INVALID` index**: ignored by queries but still paid on every write. Fix: `DROP INDEX` and retry, or `REINDEX INDEX CONCURRENTLY`.

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_orders_customer ON orders (customer_id);
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;  -- find leftover invalid indexes
REINDEX INDEX CONCURRENTLY ix_orders_customer;                   -- also the bloat-repair tool for live indexes
```
- Unique builds enforce uniqueness against other transactions from the second scan onward — other sessions can see violation errors before the index exists; a failed invalid unique index **keeps enforcing** the constraint.
- Total work and wall time are higher than a plain build — that's the price for not blocking writes.

### Autovacuum tuning and bloat

- Autovacuum triggers (documented defaults): **vacuum** when dead tuples > `autovacuum_vacuum_threshold` (50) + `autovacuum_vacuum_scale_factor` (0.2) × reltuples, capped by `autovacuum_vacuum_max_threshold` (100,000,000; new in PG18); **analyze** when changed rows > `autovacuum_analyze_threshold` (50) + `autovacuum_analyze_scale_factor` (0.1) × reltuples; **insert-driven** vacuums (`autovacuum_vacuum_insert_threshold` 1000 + `_insert_scale_factor` 0.2 of unfrozen pages) keep append-only tables frozen and the visibility map set. `autovacuum_max_workers` = 3, `autovacuum_naptime` = 1min.
- A percent-of-table scale factor means **big tables vacuum too rarely** — override per table:

```sql
ALTER TABLE events SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.005);
```

- Autovacuum is throttled by `autovacuum_vacuum_cost_delay` (2ms) / `autovacuum_vacuum_cost_limit` (shared across workers) — if bloat grows while autovacuum runs constantly, it's throttled too hard; lower the delay / raise the limit rather than adding workers.
- Monitor:

```sql
SELECT relname, n_dead_tup, n_live_tup, last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;        -- bloat pressure
SELECT c.oid::regclass, age(c.relfrozenxid)
FROM pg_class c WHERE c.relkind IN ('r','m')
ORDER BY 2 DESC LIMIT 20;                                          -- wraparound headroom
```

- Plain `VACUUM` reclaims space for **reuse**, it does not shrink files (except trailing pages); `VACUUM FULL` rewrites the table under an exclusive lock — emergency tool, not maintenance. Frequent cheap vacuums beat rare heavy ones. Never disable autovacuum: XID wraparound protection depends on it (`track_counts = on` is required for it to work at all); `log_autovacuum_min_duration` and `pg_stat_progress_vacuum` show what it is doing.

### Memory and planner cost settings (as documented)

- `shared_buffers` (default 128MB): docs recommend **~25% of RAM** on a dedicated server with ≥1GB; **>40% is unlikely to help** because PostgreSQL also uses the OS cache. Raising it "usually require[s] a corresponding increase in `max_wal_size`".
- `work_mem` (default 4MB): limit **per sort/hash operation**, not per query or connection — one query can run several concurrently, times many sessions. Set a modest global value and raise per session/transaction (`SET LOCAL work_mem = '256MB'`) for known heavy queries. Hash operations get `work_mem × hash_mem_multiplier` (default 2.0; docs suggest 2.0–8.0 where spilling persists after `work_mem` ≥ 40MB).
- `maintenance_work_mem` (default 64MB): VACUUM, `CREATE INDEX`, FK adds — safe to set much higher than `work_mem`, but autovacuum may allocate it × `autovacuum_max_workers` (cap workers via `autovacuum_work_mem`).
- `effective_cache_size` (default 4GB): planner-only estimate of total cache (shared_buffers + OS cache); allocates nothing. Set to ~50–75% of RAM so index scans price correctly.
- `random_page_cost` (default 4.0): docs say lower it when data is likely fully cached or on storage with cheap random reads (SSD/NVMe — commonly 1.1); keep higher for magnetic disks.

### JIT and parallel query

- `jit` = on by default; kicks in above `jit_above_cost` (100,000), inlining/optimization above `jit_inline_above_cost`/`jit_optimize_above_cost` (500,000). `EXPLAIN ANALYZE` prints a `JIT:` block with compile times — if JIT time rivals execution time on mid-cost queries (classic OLTP misfire), raise `jit_above_cost` or `SET jit = off` for that workload; `pg_stat_statements` exposes `jit_*` columns fleet-wide.
- Parallel query: planner adds `Gather`/`Gather Merge` with `Workers Planned`; capped by `max_parallel_workers_per_gather` (default 2), drawn from `max_parallel_workers` (8) within `max_worker_processes` (8). Workers come from a shared pool — **`Workers Launched` can be less than planned** (check in EXPLAIN ANALYZE); if that recurs, raise the pool or lower per-gather. Tables below `min_parallel_table_scan_size` (8MB) don't get parallel scans. `work_mem` applies **per worker**.

### Keyset pagination (not OFFSET)

`OFFSET n` always generates and discards `n` rows — cost grows linearly with page depth. Keyset uses a row-value comparison that a matching index satisfies directly:

```sql
CREATE INDEX ON items (created_at DESC, id DESC);
SELECT * FROM items
WHERE (created_at, id) < (@last_created_at, @last_id)   -- cursor from previous page
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

The tie-breaker column (`id`) is mandatory for a stable order; the `ORDER BY` must match the index. Trade-off: no random page jumps — fine for infinite scroll / API cursors.

### Data-equivalence checks: EXCEPT ALL semantics (verified)

Per the SELECT reference: `EXCEPT ALL` returns a row with *m* duplicates on the left and *n* on the right **max(m−n, 0)** times; `INTERSECT ALL` returns **min(m, n)**; without `ALL`, all set operations de-duplicate. That is exactly why the mandatory rewrite check in SKILL.md uses `EXCEPT ALL` in **both directions** — plain `EXCEPT` would hide duplicate-count regressions (a fanned-out join returning each row twice passes `EXCEPT`, fails `EXCEPT ALL`). Set operations match NULLs as equal, which is what you want when diffing result sets.

### Bulk loading (populate docs)

`COPY` over `INSERT` ("almost always faster... even if PREPARE is used and multiple insertions are batched"); load into a fresh table **then** create indexes; drop/re-add FK constraints for very large loads (trigger queue can exhaust memory); raise `maintenance_work_mem` and `max_wal_size` for the load; single transaction, and `wal_level = minimal` if archiving can be off; **`ANALYZE` immediately afterwards** — autovacuum hasn't seen the data yet. From .NET use Npgsql binary COPY: `connection.BeginBinaryImport("COPY t (a, b) FROM STDIN (FORMAT BINARY)")`.

### pg_stat_statements (find the top offenders)

- Enable (server restart required for the preload):

```sql
-- postgresql.conf: shared_preload_libraries = 'pg_stat_statements'
--                  compute_query_id = on   (or auto)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

- Defaults: `pg_stat_statements.max` = 5000, `.track` = `top` (`all` includes nested statements), `.track_utility` = on, `.track_planning` = off (has overhead), `.save` = on.
- Queries are normalized (constants → `$1`) and keyed by `queryid` — **not stable across major versions**, so persist query text, not ids. Triage query:

```sql
SELECT queryid, calls, round(mean_exec_time)::text AS mean_ms,
       round(total_exec_time)::text AS total_ms, rows,
       shared_blks_read, temp_blks_written
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 20;
```

- `temp_blks_written` > 0 ⇒ spilling (`work_mem`); high `shared_blks_read` vs `hit` ⇒ working set exceeds cache; pair with `auto_explain` to capture the actual slow plans.

### Npgsql specifics (.NET)

- Pooling is on by default; returned connections are reset via `DISCARD ALL`. Prefer a singleton `NpgsqlDataSource` (see `data-access`).
- **Prepared statements are the top documented driver win.** Automatic preparation is **off by default**: `Max Auto Prepare=0`; enable with e.g. `Max Auto Prepare=100;Auto Prepare Min Usages=5` (defaults shown) — this benefits Dapper/EF too since they don't call `Prepare()`. Explicit `Prepare()` is still faster when coding ADO.NET directly. Prepared statements persist across pooled opens. Transaction-mode PgBouncer breaks session-scoped prepared statements — align pooler mode before enabling.
- Batching: `NpgsqlBatch` sends multiple statements in one round trip. Large rows: `CommandBehavior.SequentialAccess` streams instead of buffering (read columns in order); or raise `Read Buffer Size`.
- Always use parameters — interpolated SQL defeats auto-preparation (every literal is a new statement) besides the injection risk. `Enlist=false` if you never use TransactionScope and cycle connections heavily.

## Ready-to-run diagnostics

Top offenders from `pg_stat_statements`:

```sql
SELECT substring(query, 1, 100) AS query, calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS avg_ms, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Unused indexes (write tax with zero read benefit — verify over a representative workload window before dropping):

```sql
SELECT schemaname || '.' || relname AS "table", indexrelname AS index,
       idx_scan AS times_used,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND indexrelname NOT LIKE '%_pkey'
ORDER BY pg_relation_size(indexrelid) DESC;
```

## Anti-patterns

- `OFFSET`/`LIMIT` for deep pagination — linear cost; use keyset (above).
- Verifying a rewrite with `EXCEPT` instead of bidirectional `EXCEPT ALL` — silently ignores duplicate-count changes.
- Trusting a plan whose estimated rows are off by 10x+ — fix statistics (target, extended stats, `ANALYZE`) before adding indexes.
- Plain `CREATE INDEX`/`REINDEX` on a busy production table — write-blocking lock; use `CONCURRENTLY` and clean up `INVALID` leftovers.
- `INCLUDE`-everything covering indexes — index bloat, dead weight on every write, and no win unless the visibility map is well maintained.
- Setting `work_mem` high globally "to stop spills" — it multiplies per operation × per session × per parallel worker; scope raises to the session.
- `shared_buffers` > 40% of RAM, or leaving `effective_cache_size`/`random_page_cost` at defaults on cached/SSD workloads.
- Disabling or starving autovacuum, or "fixing" bloat with routine `VACUUM FULL` (exclusive lock, full rewrite).
- Relying on an index-only scan while the table never gets vacuumed — `Heap Fetches` climbs and the scan degrades to worse-than-index-scan.
- Spraying `CREATE STATISTICS` on every column pair — each costs ANALYZE and planning time; target proven misestimates only.
- Benchmarking with `EXPLAIN ANALYZE` numbers alone — timing overhead and no network cost; confirm with `pg_stat_statements` under real load.
- Interpolating values into SQL from .NET — breaks auto-prepare cache and invites injection; parameters always.
- Running PostgreSQL 14 without an upgrade plan (EOL 2026-11-12), or adopting PG 19 beta in production.

## Sources

- https://www.postgresql.org/support/versioning/
- https://www.postgresql.org/docs/current/release-18.html
- https://www.postgresql.org/about/news/postgresql-18-released-3142/
- https://www.postgresql.org/docs/current/using-explain.html
- https://www.postgresql.org/docs/current/planner-stats.html
- https://www.postgresql.org/docs/current/indexes-types.html
- https://www.postgresql.org/docs/current/indexes-index-only-scans.html
- https://www.postgresql.org/docs/current/sql-createindex.html
- https://www.postgresql.org/docs/current/routine-vacuuming.html
- https://www.postgresql.org/docs/current/runtime-config-vacuum.html
- https://www.postgresql.org/docs/current/runtime-config-resource.html
- https://www.postgresql.org/docs/current/runtime-config-query.html
- https://www.postgresql.org/docs/current/populate.html
- https://www.postgresql.org/docs/current/pgstatstatements.html
- https://www.postgresql.org/docs/current/how-parallel-query-works.html
- https://www.postgresql.org/docs/current/sql-select.html
- https://www.npgsql.org/doc/performance.html
- https://www.npgsql.org/doc/prepare.html
- https://www.npgsql.org/doc/release-notes/10.0.html
