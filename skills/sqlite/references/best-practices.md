# SQLite Best Practices — Performance, Indexing, Query Correctness

Verified against official documentation, July 2026. Sources: sqlite.org (optoverview, queryplanner, eqp, wal, pragma, lang_analyze, partialindex, expridx, withoutrowid, datatype3, lang_transaction) and learn.microsoft.com Microsoft.Data.Sqlite docs. Full URLs in **Sources** at the end.

## Current versions (July 2026)

- **SQLite 3.53.3** — released 2026-06-26 (current release on sqlite.org).
- **Microsoft.Data.Sqlite 10.0.9** — current stable NuGet package (2026-06-09); 11.0.0-preview.5 available. The `Vfs` connection-string keyword was added in 10.0.
- EXPLAIN QUERY PLAN output format is explicitly **not stable across releases** ("Applications should not depend on the output format") — treat plans as a diagnostic, never parse them in code.

## Established patterns

### Query planner facts (documented behavior)

- **Joins are nested loops, always.** SQLite implements joins only as nested loops; the planner picks the loop order (outer/inner) based on available indexes and statistics. A join with no usable index on the inner table is O(N×M) — the planner may build an **automatic (transient) index** for one query when it estimates the lookup will run more than log(N) times, which is a signal you're missing a real index.
- **One index per table per query** — except the OR optimization, which can evaluate OR terms with separate indexes and UNION the results. `column = a OR column = b` may also be converted to `IN`.
- **CROSS JOIN forces join order.** "SQLite chooses to never reorder tables in a CROSS JOIN" — the documented escape hatch to pin the loop order. Only use it when that is the intent; comma joins and accidental cross joins are review failures.
- **Next-generation query planner** (3.8.0+, current): join-order search uses a polynomial-time approximation algorithm, so even 50–60-way joins plan in microseconds; its choices are driven by ANALYZE statistics — stale stats mean bad plans.
- **Skip-scan** (with ANALYZE data): an index can be used even when its leftmost column is unconstrained, but only when stats show the left column has many duplicates (≈18+ per value). Don't design for it; it's a fallback.
- **MIN/MAX optimization**: a lone `MIN(x)`/`MAX(x)` where `x` is the leftmost column of an index is a single index lookup.
- **BETWEEN** is rewritten to `>= AND <=` virtual terms and can drive an index range scan.

### Reading EXPLAIN QUERY PLAN

```sql
EXPLAIN QUERY PLAN SELECT ... ;
```

- `SEARCH t USING INDEX ...` — subset of rows visited (good). `SCAN t` — full pass (fine for small/whole-table reads, a smell on large tables with selective predicates).
- `USING COVERING INDEX` — no table lookup at all; the docs put the win at roughly a doubling of speed.
- `USE TEMP B-TREE FOR ORDER BY/GROUP BY/DISTINCT` — a sort an index could often eliminate; an index matching the ORDER BY returns rows in order with no temp storage.
- `MATERIALIZE` vs `CO-ROUTINE` for FROM-clause subqueries; `CORRELATED SCALAR SUBQUERY` runs per outer row — hoist it if it shows up on a hot query.
- The CLI's `.expert` mode proposes indexes for a given query.

### Index design (queryplanner.html rules)

- **Left-prefix, no gaps**: index columns must be constrained by equality (`=`, `IN`, `IS`) from the left; the first unconstrained column ends index usability ("there cannot be gaps in the columns of the index that are used").
- **At most one range column**: the rightmost used column may take inequalities (up to two, bracketing a range). So: equality columns first, then the single range/ORDER BY column.
- **Never keep two indexes where one is a left prefix of the other** — drop the shorter one; the longer index serves both.
- **Covering index**: include the selected columns so the row lookup disappears (`USING COVERING INDEX` in the plan).
- `INTEGER PRIMARY KEY` **is** the rowid — no extra index, fastest key. `AUTOINCREMENT` adds overhead and only matters if rowid reuse must be prevented.
- Every index taxes the single writer — prune indexes that never appear in `EXPLAIN QUERY PLAN` over your real query set.

### Partial and expression indexes

```sql
CREATE INDEX ix_orders_open ON orders(customer_id, created_at) WHERE status = 'open';
CREATE INDEX ix_users_email_ci ON users(lower(email));
```

- A **partial index** is used only when the query's WHERE clause *provably implies* the index's WHERE clause — and "SQLite does not do algebra": terms must match essentially verbatim. Special case: an `x IS NOT NULL` index WHERE clause is implied by any `=, <, >, <=, >=, <>, IN, LIKE, GLOB` constraint on `x`.
- Partial-index WHERE clauses cannot contain subqueries, other tables, non-deterministic functions, or bound parameters. Partial unique indexes enforce uniqueness on a subset ("one leader per team").
- **Expression indexes** are used only when the query contains the expression *exactly as written* (whitespace aside) — `x+y` indexed will not match `y+x` queried. Deterministic functions only; no subqueries; expressions are allowed in `CREATE INDEX` but not in UNIQUE/PRIMARY KEY table constraints.

### LIKE, GLOB, and collation (optoverview.html conditions)

`LIKE 'abc%'` becomes an index range scan only when **all** documented conditions hold:

- The pattern does not begin with a wildcard, and the RHS is a literal or a parameter bound to a string (not a column).
- Collation alignment: with `PRAGMA case_sensitive_like=ON`, the column/index must use BINARY collation; with the default (case-insensitive LIKE), the index must be `COLLATE NOCASE`.
- The LHS must have TEXT affinity (numbers don't sort lexicographically).
- No application-defined `like()` override is installed.

Comparison collation is chosen by: explicit `COLLATE` operator first, else the left operand's column collation, else BINARY. NOCASE is ASCII-only. A common working pattern is `lower(col)` expression index + `WHERE lower(col) LIKE 'abc%'` — but remember exact-expression matching.

### WITHOUT ROWID (withoutrowid.html)

- Single B-tree clustered on the PRIMARY KEY (no hidden rowid, no separate PK index) — for non-integer or composite natural keys this can halve storage and nearly double lookup speed because the key is stored once.
- **Documented size rule**: average row size should be **less than ~1/20th of the page size** (≈200 bytes at 4 KiB pages); larger rows perform *worse* than ordinary rowid tables.
- Requires an explicit PRIMARY KEY; `AUTOINCREMENT` is prohibited; PK columns reject NULL.
- Docs advise treating it as a late-stage, measured optimization — benchmark, don't default.

### WAL mode and checkpointing (wal.html)

- Readers don't block the writer and the writer doesn't block readers — but there is still **exactly one writer at a time**.
- WAL is **persistent**: set once (`PRAGMA journal_mode=WAL;`) and it survives connection close/reopen — no per-connection setup needed.
- Automatic checkpoint runs when the WAL reaches ~1000 pages (`PRAGMA wal_autocheckpoint` to tune). Manual `PRAGMA wal_checkpoint(PASSIVE|FULL|RESTART|TRUNCATE)` for controlled maintenance windows.
- **Long-running read transactions block checkpointing** → unbounded WAL growth; large WALs also slow reads (readers must search the WAL). Keep read transactions short; watch the `-wal` file size.
- Constraints: all processes must be on the **same host** (shared memory); WAL does not work over network filesystems.
- `PRAGMA synchronous=NORMAL` is the documented sweet spot in WAL mode: transactions stay atomic/consistent/isolated; only durability of the very last commits can be lost on power failure; syncs happen at checkpoints, not per commit.

### Connection baseline (pragmas)

```sql
PRAGMA journal_mode=WAL;      -- once per database (persistent)
PRAGMA synchronous=NORMAL;    -- per connection; safe with WAL
PRAGMA busy_timeout=5000;     -- per connection; never let SQLITE_BUSY crash
PRAGMA optimize=0x10002;      -- long-lived connections: on open (see below)
```

### ANALYZE and PRAGMA optimize (current recommendation)

The docs now steer you to `PRAGMA optimize` instead of hand-run ANALYZE — it runs ANALYZE only on tables whose statistics look out of date. Current documented pattern:

- **Short-lived connections**: run `PRAGMA optimize;` once just before closing each connection.
- **Long-lived connections**: run `PRAGMA optimize=0x10002;` when the connection opens (the 0x10000 bit checks all tables), then plain `PRAGMA optimize;` periodically — "perhaps once per day or once per hour".
- **Always** run `PRAGMA optimize;` after schema changes, especially after `CREATE INDEX`.
- `PRAGMA analysis_limit=N` (N in 100–1000) makes ANALYZE approximate and fast on large databases; note `sqlite_stat4` histograms are **not** computed with a non-zero limit. STAT4 requires the `SQLITE_ENABLE_STAT4` compile option.
- Statistics do not self-update — re-run after significant data-shape changes; the NGQP's join ordering is only as good as `sqlite_stat1`.

### Transactions and write batching

- Autocommit means every standalone statement is its own transaction (its own commit/fsync). Batching N inserts in one transaction is the single biggest SQLite write optimization.
- `BEGIN DEFERRED` (default) starts as a read transaction and upgrades on the first write — the upgrade can fail with `SQLITE_BUSY` if another writer got there first. For transactions you *know* will write, `BEGIN IMMEDIATE` takes the write lock up front, so contention surfaces at BEGIN where `busy_timeout` can wait it out instead of failing mid-transaction.
- `BEGIN EXCLUSIVE` additionally blocks readers in non-WAL modes; rarely needed under WAL.

### Type affinity and data-equivalence comparisons (datatype3.html)

- Affinity from declared type, first match wins: contains `INT` → INTEGER; `CHAR`/`CLOB`/`TEXT` → TEXT; `BLOB` or none → BLOB; `REAL`/`FLOA`/`DOUB` → REAL; else NUMERIC. (`CHARINT` → INTEGER — rule 1 beats rule 2.)
- Before comparison: a numeric-affinity operand converts a TEXT/BLOB/no-affinity operand to NUMERIC; a TEXT-affinity operand converts a no-affinity operand to TEXT; otherwise values compare as-is. So `'1' = 1` is true against an INTEGER column but **`'500' < 600` compared via a TEXT column is a lexicographic string compare** — a classic silent-wrongness bug.
- Consequence for rewrites: declare and insert consistent types; when verifying a rewrite (EXCEPT-based equivalence check in SKILL.md), a value stored as TEXT `'1'` and one stored as INTEGER `1` are *different values* to EXCEPT even if some comparisons coerce them equal.
- Collation only affects TEXT comparisons; BINARY is memcmp, NOCASE is ASCII-only, RTRIM ignores trailing spaces.

### Microsoft.Data.Sqlite specifics

- **No true async I/O**: "SQLite doesn't support asynchronous I/O. Async ADO.NET methods will execute synchronously in Microsoft.Data.Sqlite. Avoid calling them." Use WAL for concurrency instead (EF Core enables WAL by default on databases it creates).
- **Connection pooling is on by default** since version 6.0 (`Pooling=True` is the default; `Pooling=False` to disable). Open/close freely; the pool keeps the native handle warm.
- **Prepared-statement reuse is per command object**: "Reuse the same parameterized command. Subsequent executions will reuse the compilation of the first one." Bulk-write shape:

```csharp
using var tx = connection.BeginTransaction();
var cmd = connection.CreateCommand();
cmd.CommandText = "INSERT INTO data VALUES ($value)";
var p = cmd.CreateParameter(); p.ParameterName = "$value"; cmd.Parameters.Add(p);
for (var i = 0; i < 150_000; i++) { p.Value = Next(); cmd.ExecuteNonQuery(); }
tx.Commit();
```

- `Default Timeout` (seconds, default 30) is the command/busy timeout; override per command via `CommandTimeout`.
- **Do not combine `Cache=Shared` with WAL** — the docs explicitly discourage mixing shared-cache mode and write-ahead logging; drop `Cache=Shared` when WAL is on.
- `SqliteConnection` objects are not thread-safe — one per unit of work; let the pool do the sharing.

## Anti-patterns

- Row-by-row autocommit writes (one fsync per statement) instead of one transaction per batch.
- Letting `SQLITE_BUSY` bubble up as an exception: missing `busy_timeout`, or a DEFERRED transaction upgrading to write mid-flight — use `BEGIN IMMEDIATE` for writers.
- Long-lived read transactions (or never-disposed readers) under WAL — checkpoint starvation and unbounded `-wal` growth.
- Two indexes where one is a left prefix of the other; gaps in composite-index usage; more than one range column expected to use the index.
- Expecting `LIKE '%abc'` or a mismatched-collation `LIKE 'abc%'` to use an index.
- Expression index written as `lower(email)` but queried as `LOWER(TRIM(email))` — exact-expression match required; same for partial-index WHERE clauses ("SQLite does not do algebra").
- `WITHOUT ROWID` on wide rows (> ~1/20th page size) or as a default rather than a measured choice.
- Hand-running full `ANALYZE` in production paths instead of the documented `PRAGMA optimize` pattern; or never refreshing stats at all.
- Relying on affinity coercion (`'1'` vs `1`) instead of consistent declared/inserted types — breaks equivalence checks and range comparisons.
- Calling `ExecuteReaderAsync`/`ToListAsync` on SQLite expecting I/O parallelism — it runs synchronously; also recreating `SqliteCommand` per loop iteration in hot write paths.
- Parsing EXPLAIN QUERY PLAN output programmatically (format is documented as unstable).
- `AUTOINCREMENT` by default; `Cache=Shared` combined with WAL; comma joins / unintended `CROSS JOIN` (which also pins join order).

## Sources

- https://sqlite.org/index.html (current version 3.53.3, 2026-06-26)
- https://sqlite.org/optoverview.html
- https://sqlite.org/queryplanner.html
- https://sqlite.org/eqp.html
- https://sqlite.org/withoutrowid.html
- https://sqlite.org/wal.html
- https://sqlite.org/pragma.html#pragma_optimize
- https://sqlite.org/lang_analyze.html
- https://sqlite.org/partialindex.html
- https://sqlite.org/expridx.html
- https://sqlite.org/datatype3.html
- https://sqlite.org/lang_transaction.html
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/async
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/connection-strings
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/bulk-insert
- https://www.nuget.org/packages/Microsoft.Data.Sqlite (10.0.9 stable, 2026-06-09)
