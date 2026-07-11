---
name: data-access
description: Use when writing database code in .NET — choosing between EF Core and Dapper, writing queries, DbContext setup, migrations, slow queries, N+1 problems, or working with SQL Server (MSSQL), PostgreSQL, or SQLite.
---

# Data Access — EF Core & Dapper

## Overview

EF Core is the default (change tracking, migrations, LINQ safety). Dapper is the escalation for **measured** hot paths. Both always: parameterized, async with `CancellationToken`, project to DTOs.

## Decision table — which tool for which operation

EF Core is the default; escalate only on a measurement or a clear SQL-shape need. EF always owns the schema (migrations) — Dapper reads/writes the same tables, never defines them.

| Operation | Use | Why |
|---|---|---|
| CRUD on aggregates you'll mutate | EF Core, tracking | Change tracking + `SaveChanges` batching |
| Reads for API responses / lists | EF Core, `AsNoTracking` + `Select` projection | No tracking overhead, only needed columns |
| Profiled hot read path | Dapper | No LINQ translation/materialization overhead |
| Hand-tuned SQL (window fns, CTEs, hints) | Dapper | Full SQL control |
| Reporting/dashboard custom shapes | Dapper (multi-mapping / `QueryMultiple`) | Wide joins, arbitrary shapes |
| Set-based update/delete | EF `ExecuteUpdateAsync`/`ExecuteDeleteAsync` | One statement, no load-modify-save |
| Bulk insert (≳1k rows) | Provider bulk API — see table below | Orders of magnitude over row-by-row |
| Dynamically composed search filters | EF Core LINQ composition | Safe composition, no SQL string building |
| Schema & migrations | EF Core, always | Single migration story |

Put Dapper queries in dedicated `*Queries` classes so the split stays visible and grep-able.

Scope guard: the "no repository ceremony" stance applies to new code. A codebase that already has a repository/specification layer keeps it — work within the local pattern and keep it consistent; migrating away is its own explicitly-agreed task.

## Decision table — EF read patterns

| Situation | Pattern |
|---|---|
| Data leaves the process (API response) | `AsNoTracking()` + `.Select()` to DTO |
| Entity you will mutate and save | Tracked query (`FindAsync`/`SingleAsync`) |
| Same hot query shape, stable parameters | `EF.CompileAsyncQuery` |
| Multiple collection `Include`s | `.AsSplitQuery()` — or project instead of including |
| Very large result set, streamed out | `AsAsyncEnumerable()` end-to-end (no `ToList`) |
| Query cannot be translated | Don't drop to client-eval — move it to Dapper with real SQL |

## EF Core rules

```csharp
builder.Services.AddDbContextPool<AppDbContext>(o => o
    .UseNpgsql(cs, npgsql => npgsql.EnableRetryOnFailure())
    .UseSnakeCaseNamingConvention());   // Postgres only
```

- `AddDbContextPool` (not `AddDbContext`) for request-scoped contexts.
- **Reads**: `AsNoTracking()` + `.Select()` projection to DTOs. Tracking is only for entities you'll mutate.
- **No lazy loading, ever.** Explicit `Include` or projections. N+1 shows up as one query per row — if you see `Include` chains exploding row counts, add `.AsSplitQuery()`.
- **Set-based writes**: `ExecuteUpdateAsync`/`ExecuteDeleteAsync` instead of load-modify-save loops.
- Hot, parameter-stable queries: `EF.CompileAsyncQuery`.
- Concurrency: rowversion (`[Timestamp]`) on MSSQL, `xmin` on Postgres; handle `DbUpdateConcurrencyException`.
- Configuration via `IEntityTypeConfiguration<T>` classes, not a 1000-line `OnModelCreating`.
- Never string-interpolate into `FromSqlRaw` — use `FromSql` (interpolated-handler, parameterizes automatically).

### Migrations

- `dotnet ef migrations add <Name>` — review the generated code, especially destructive ops.
- One provider per project; if a project supports multiple providers, keep migrations in provider-specific assemblies (`Migrations/Mssql`, `Migrations/Postgres`).
- Apply on deploy via SQL scripts or a migration bundle — **not** `Database.Migrate()` at production startup. (EF 9+'s migration lock fixed the old multi-instance race, but runtime migration remains officially discouraged: it needs elevated schema permissions, applies uninspected SQL, and has no clean rollback.) For single-instance/dev, startup migrate is fine.

## Dapper rules

```csharp
public sealed class OrderQueries(NpgsqlDataSource dataSource)
{
    public async Task<IReadOnlyList<OrderSummary>> TopOrdersAsync(int take, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<OrderSummary>(new CommandDefinition("""
            SELECT o.id, o.total, c.name AS customer_name
            FROM orders o
            JOIN customers c ON c.id = o.customer_id
            ORDER BY o.total DESC
            LIMIT @take
            """, new { take }, cancellationToken: ct));
        return rows.AsList();
    }
}
```

- Postgres: inject `NpgsqlDataSource` (singleton); MSSQL/SQLite: open a new `SqlConnection`/`SqliteConnection` per operation (pooling handles reuse).
- Always `CommandDefinition` with `cancellationToken`.
- Multi-row shapes: multi-mapping (`QueryAsync<TFirst, TSecond, TResult>` with `splitOn`) or `QueryMultiple` — never N+1 loops.
- Parameters only — string concatenation into SQL is an automatic review failure.

## EF Core + Dapper together — the seam

They are one data layer, not two. Rules that keep the seam fast and correct:

**One connection, one transaction.** When Dapper work belongs to an EF unit of work (e.g. outbox insert), run it on EF's connection inside EF's transaction — a second connection means a second pool slot and *no atomicity*:

```csharp
public sealed class OrderService(AppDbContext db)
{
    public async Task PlaceAsync(Order order, CancellationToken ct)
    {
        // EnableRetryOnFailure requires the execution strategy to own the whole transaction —
        // BeginTransaction without it throws with retries enabled. Use the (state, token) overload:
        // passing ct AS the state compiles but hides cancellation from the retry machinery.
        var strategy = db.Database.CreateExecutionStrategy();
        await strategy.ExecuteAsync(order, async (o, token) =>
        {
            await using var tx = await db.Database.BeginTransactionAsync(token);

            db.Orders.Add(o);
            await db.SaveChangesAsync(token);

            var conn = db.Database.GetDbConnection();           // same connection EF uses
            await conn.ExecuteAsync(new CommandDefinition(
                "INSERT INTO outbox_messages (id, type, payload) VALUES (@Id, @Type, @Payload)",
                new { o.Id, Type = "order.created", Payload = Serialize(o) },
                transaction: tx.GetDbTransaction(),             // same transaction
                cancellationToken: token));

            await tx.CommitAsync(token);
        }, ct);
    }
}
```

**Shared plumbing per provider:**
- **Postgres**: one singleton `NpgsqlDataSource` feeds *both* — `UseNpgsql(dataSource)` for EF and inject it for Dapper. One pool, one place for enum/JSON mappings. Snake_case seam: `DefaultTypeMap.MatchNamesWithUnderscores = true;` once at startup so Dapper maps `customer_name` → `CustomerName`.
- **MSSQL**: Dapper string parameters are `nvarchar` by default — against `varchar` columns that's an implicit conversion → index scan. Use `new DbString { Value = v, IsAnsi = true }` (see `mssql`).
- **SQLite**: both go through the same pooled connection string; keep write batches in one transaction regardless of which tool writes (see `sqlite`).

**Schema is EF's.** Dapper SQL must follow the EF model — after a rename/retype migration, grep the `*Queries` classes; the compiler won't catch stale SQL, the integration tests must (real-DB tests per `dotnet-testing`).

## Decision table — transactions across the seam

| Scenario | Pattern |
|---|---|
| Single `SaveChangesAsync` | Nothing — EF wraps it in a transaction already |
| Multiple saves / EF + Dapper atomically | `Database.BeginTransactionAsync` + `GetDbConnection()`/`GetDbTransaction()` as above |
| `EnableRetryOnFailure` active | Wrap the whole transaction in `CreateExecutionStrategy().ExecuteAsync(...)` |
| Dapper-only unit of work | Own connection + `BeginTransactionAsync` on it |
| Cross-service consistency | Never a distributed transaction — outbox + RabbitMQ (see `rabbitmq-messaging`) |

## Decision table — bulk ingestion

Row-by-row APIs are the wrong tool from ~1k rows; after any bulk load, refresh statistics (provider skills).

| Provider | Tool | Notes |
|---|---|---|
| MSSQL | `SqlBulkCopy` | `TABLOCK` for empty-target loads; map columns explicitly |
| PostgreSQL | `NpgsqlBinaryImporter` (binary `COPY`) | Fastest documented path; via the shared `NpgsqlDataSource` |
| SQLite | One transaction + reused prepared `SqliteCommand` | The transaction *is* the bulk API here |
| Any, medium batches | EF `AddRange` + single `SaveChanges` | Fine to ~low thousands; EF batches statements |

## Provider choice — then load the provider skill

| | MSSQL | PostgreSQL | SQLite |
|---|---|---|---|
| Use for | Enterprise/existing estates | Default for new server projects | Embedded, tools, small single-node apps |
| Concurrency token | `rowversion` | `xmin` | manual version column |
| Naming | PascalCase | snake_case (naming-convention package) | either |

Everything deeper is provider-specific and lives in the dedicated skills — **load the matching one whenever you tune, index, rewrite, or debug SQL**: `mssql`, `postgres`, `sqlite`. They carry the performance workflows, index design rules, join/cartesian pitfalls, and the mandatory data-equivalence verification for query rewrites (same row count, same columns, same cell data).

## Common mistakes

| Mistake | Fix |
|---|---|
| Tracking + full entity for read-only lists | `AsNoTracking` + projection |
| `.ToList()` then filtering in memory | Compose the `IQueryable`, filter in SQL |
| Repository wrapping every DbSet 1:1 | Use DbContext directly in slices; add query classes only where shapes are shared |
| `Database.Migrate()` on multi-instance startup | Migration bundle / deploy step |
| Dapper with interpolated SQL | Parameters via anonymous object |
| Opening one shared `DbConnection` singleton (MSSQL/SQLite) | Connection per operation; ADO.NET pools for you (Postgres: singleton `NpgsqlDataSource` is the exception and correct) |
| Dapper on its **own** connection inside an EF unit of work | Not atomic + burns a pool slot — `GetDbConnection()` + `GetDbTransaction()` |
| Manual `BeginTransaction` with `EnableRetryOnFailure` | Wrap in `CreateExecutionStrategy().ExecuteAsync` |
| Row-by-row inserts for bulk data | Provider bulk API (bulk ingestion table above) |
| EF migration renames a column, Dapper SQL still old | Grep `*Queries` on every migration; integration tests on real DB catch the rest |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- EF Core: https://learn.microsoft.com/en-us/ef/core/
- Dapper: https://github.com/DapperLib/Dapper
- Npgsql: https://www.npgsql.org/doc/ (EF Core provider: https://www.npgsql.org/efcore/)
- Microsoft.Data.Sqlite: https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
- **EF Core + Dapper seam deep-dive (verified July 2026): [references/efcore-dapper-seam.md](references/efcore-dapper-seam.md) — read it when mixing the two or moving bulk data.**
