---
name: postgres
description: Use when working with PostgreSQL — slow queries, EXPLAIN ANALYZE, index design (B-tree/GIN/BRIN/partial), query rewrites and verifying they return identical data, vacuum/bloat, locks/blocking and safe production DDL/migrations, or tuning Postgres for an ASP.NET Core app with Npgsql.
---

# PostgreSQL

## Overview

Provider-specific PostgreSQL knowledge: performance workflows, index design, join correctness, and the mandatory data-equivalence check for query rewrites. ORM-level patterns (EF Core vs Dapper, `NpgsqlDataSource`) live in `data-access`.

## Performance improvement workflow

One change at a time, measured before and after:

1. **Reproduce with realistic volume** and fresh statistics (`ANALYZE <table>` after bulk loads).
2. **Measure**: `EXPLAIN (ANALYZE, BUFFERS)` — actual rows vs estimated rows is the first thing to read; a large skew means stale/insufficient statistics or non-plannable predicates. Enable `pg_stat_statements` to find the top offenders fleet-wide; `auto_explain` logs slow plans in production.
3. **Identify the dominant issue**: seq scan where an index applies, misestimated join order, hash/sort spilling to disk (`work_mem` too small — visible as "external merge" in the plan), dead-tuple bloat (check `pg_stat_user_tables.n_dead_tup`).
4. **Fix one thing** (index, rewrite, statistics target, `work_mem` for the session), re-run `EXPLAIN (ANALYZE, BUFFERS)` and compare shared-buffer hits/reads.
5. **If the query text changed, run the data-equivalence check below before shipping.**

## Query rewrite → data-equivalence check (mandatory)

A rewritten query must return the **same rows, same columns, same values**. Prove it:

1. **Row count**: `SELECT COUNT(*)` of old vs new must match.
2. **Column shape**: run both with `\gdesc` in psql (or compare `pg_typeof()` per column) — names and types must match.
3. **Cell-level data** — Postgres has `EXCEPT ALL`, which respects duplicates; use it in both directions:

```sql
WITH old_q AS (<old query>), new_q AS (<new query>)
SELECT 'only_in_old' AS side, * FROM (SELECT * FROM old_q EXCEPT ALL SELECT * FROM new_q) o
UNION ALL
SELECT 'only_in_new' AS side, * FROM (SELECT * FROM new_q EXCEPT ALL SELECT * FROM old_q) n;
-- must return 0 rows
```

   `EXCEPT` treats NULLs as equal — correct for this comparison. Types without an equality operator (`json`, `point`, …) fail with "could not identify an equality operator" — cast them (`::jsonb`, `::text`) identically on both sides.
4. **Large sets**: order-independent checksum, e.g. `SELECT md5(string_agg(t::text, ',' ORDER BY t::text)) FROM (<query>) t` on both sides — order by the whole row text, not a "unique key" (after a fan-out the key repeats → nondeterministic order → false mismatches); or count + per-column aggregates as a cheap first pass.
5. Comparisons are order-independent; if the consumer depends on order, compare with `row_number() OVER (ORDER BY ...)` included.

## Joins — no cartesian explosions

- Join predicates must cover the **complete** key — composite keys need every column. A missing column silently multiplies rows.
- Detect fan-out: `EXPLAIN ANALYZE` actual row counts ballooning at a join node far beyond both inputs; repeated parent values in output.
- Aggregating over a fanned-out join double-counts — aggregate in a subquery/CTE *before* joining, or `COUNT(DISTINCT key)` knowingly. (Since PG12 a non-recursive, side-effect-free CTE referenced **once** is inlined; one referenced twice — like `old_q`/`new_q` above — is materialized. Force with `[NOT] MATERIALIZED`.)
- `CROSS JOIN`/`LATERAL` only ever explicit and intentional; comma joins are a review failure.
- EF note: multiple collection `Include`s in single-query mode = cartesian product — `AsSplitQuery()` (see `data-access`).

## Index design rules

- **B-tree** (default) for equality/range: composite key order = equality columns first, then the range column; columns after a range predicate in the key don't help filtering.
- **Covering**: `INCLUDE (...)` payload columns to enable index-only scans — which also require a recently-vacuumed visibility map to actually skip the heap.
- **Partial indexes** (`WHERE status = 'active'`) for hot sparse subsets; **expression indexes** (`ON lower(email)`) when queries filter on expressions — the query must use the identical expression.
- **GIN** for `jsonb` containment, arrays, full-text; **GiST** for ranges/geometry/nearest-neighbor; **BRIN** for huge append-only tables with natural ordering (timestamps) — tiny and cheap.
- `LIKE 'abc%'` uses a B-tree only with the C collation or a `text_pattern_ops` index; `LIKE '%abc'` never does (trigram GIN via `pg_trgm` if needed).
- Don't index churn-heavy columns unnecessarily — updates to indexed columns defeat HOT updates and inflate bloat.
- Production DDL: `CREATE INDEX CONCURRENTLY` (and `REINDEX CONCURRENTLY` for bloat) — plain `CREATE INDEX` takes a write-blocking lock. Never with `IF NOT EXISTS`: a re-run silently skips a failed `INVALID` leftover (see reference).
- FK columns are **not** auto-indexed by Postgres — index them explicitly (joins + FK checks on parent deletes).

## Locks and production DDL

- Most `ALTER TABLE` forms take `ACCESS EXCLUSIVE`. Waiting behind one long transaction, the DDL **queues every later query on the table behind it** (even plain `SELECT`s) — a "fast" migration becomes an outage.
- Migrations: `SET lock_timeout = '5s'` (fail fast, retry) and a `statement_timeout`; set `idle_in_transaction_session_timeout` for app roles so forgotten transactions can't pin locks — except where idling inside a transaction is the design: the outbox dispatcher holds its `SKIP LOCKED` claim open while awaiting broker confirms (≤ 10 s per row, up to batch × 10 s), so it raises the timeout with `SET LOCAL` for that transaction (`rabbitmq-messaging` → outbox-inbox.md) — or use smaller batches.
- Diagnose with `pg_blocking_pids(pid)` over `pg_stat_activity` — query in the reference.
- Big tables: `ADD CONSTRAINT … NOT VALID` (FK/CHECK; NOT NULL on PG 18+), then `VALIDATE CONSTRAINT` (lighter lock, writes keep going).
- Queue/outbox polling: `SELECT … FOR UPDATE SKIP LOCKED` so workers don't block each other — queue tables only.

## Common mistakes

| Mistake | Fix |
|---|---|
| `timestamp` vs `timestamptz` mixing | `timestamptz` everywhere (UTC); casts in predicates kill indexes |
| `OFFSET 100000 LIMIT 20` pagination | Keyset pagination (`WHERE (created, id) < (@created, @id) ORDER BY created DESC, id DESC`; `@name` is Npgsql/Dapper parameter syntax — positional `$1, $2` only inside `PREPARE`/function bodies (or psql 16+ `\bind`), not in a plain psql query) |
| Function on an indexed column in WHERE | Expression index with the identical expression, or rewrite the predicate |
| Assuming FKs are indexed | Index FK columns explicitly |
| `count(*)` as a cheap existence check | `EXISTS (SELECT 1 ...)` |
| Bulk load then immediate slow queries | `ANALYZE` after bulk loads; autovacuum hasn't caught up |
| Rewrite shipped because "it looks equivalent" | Run the data-equivalence check above |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- PostgreSQL manual (current): https://www.postgresql.org/docs/current/
- Performance tips chapter: https://www.postgresql.org/docs/current/performance-tips.html
- Indexes chapter: https://www.postgresql.org/docs/current/indexes.html
- Npgsql: https://www.npgsql.org/doc/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before tuning or rewriting queries.**
