---
name: data-access
description: Use when writing .NET data-access code — choosing between EF Core and Dapper, LINQ/Dapper queries, DbContext setup and lifetime, migrations, transactions, N+1 or ORM-level slow queries, bulk inserts — against SQL Server, PostgreSQL, or SQLite. SQL/index/plan tuning belongs to the provider skills.
---

# Data Access — EF Core & Dapper

## Overview

EF Core is the default (change tracking, migrations, LINQ safety). Dapper is the escalation for **measured** hot paths. Both always: parameterized, async with `CancellationToken`, project to DTOs. **SQLite is the exception to async:** Microsoft.Data.Sqlite's async methods run synchronously (documented — avoid them), so SQLite data paths are synchronous internally (see `sqlite`).

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

**No repository ceremony**: use the `DbContext` directly — it already is the unit of work and `DbSet`s are the repositories. No generic `IRepository<T>` wrapping every `DbSet` 1:1; add query classes only where shapes are shared.

Scope guard: this stance applies to new code. A codebase that already has a repository/specification layer keeps it — work within the local pattern and keep it consistent; migrating away is its own explicitly-agreed task.

## Decision table — EF read patterns

| Situation | Pattern |
|---|---|
| Data leaves the process (API response) | `AsNoTracking()` + `.Select()` to DTO |
| Entity you will mutate and save | Tracked query (`FindAsync`/`SingleAsync`) |
| Same hot query shape, stable parameters | `EF.CompileAsyncQuery` |
| Multiple collection `Include`s | `.AsSplitQuery()` — or project instead of including |
| Very large result set, streamed out | `AsAsyncEnumerable()` end-to-end (no `ToList`) — only truly streams on a context **without** `EnableRetryOnFailure` (retries buffer the whole result set) |
| Query cannot be translated | Don't drop to client-eval — move it to Dapper with real SQL |

## EF Core rules

### DbContext registration — the one canonical block

```csharp
// Postgres: ONE singleton NpgsqlDataSource feeds EF and Dapper (one pool, one place for type mappings)
builder.Services.AddNpgsqlDataSource(cs);   // Npgsql.DependencyInjection; configure enums/JSON via its builder overload
// ONE registration per context. AddPooledDbContextFactory registers (EF Core 10 source):
//   IDbContextFactory<AppDbContext>  singleton — workers, cache factories, parallel units of work
//   AppDbContext                     scoped, leased from the same pool — request code injects it directly
builder.Services.AddPooledDbContextFactory<AppDbContext>((sp, o) => o
    .UseNpgsql(sp.GetRequiredService<NpgsqlDataSource>(), npgsql => npgsql.EnableRetryOnFailure())
    .UseSnakeCaseNamingConvention());       // EFCore.NamingConventions package
```

- Never combine it with `AddDbContext`/`AddDbContextPool`/`AddDbContextFactory` for the same context — one registration, one pool. Every other skill (caching factories, workers, tenant stamping) builds on this block.
- Pooled instances are reused: `OnConfiguring` runs once per instance, so per-request state (tenant id) is stamped by a scoped registration that wraps the factory — pattern in `bff-security` → references/authorization.md (the EF docs' "pooling with state" pattern).
- Contexts from `CreateDbContext[Async]()` are yours to dispose (`await using`) — disposal returns them to the pool; the scoped one is disposed with the scope.

MSSQL: the same block with `UseSqlServer(cs, sql => sql.EnableRetryOnFailure())` — and the connection string **must carry an explicit `Application Name=`**: since EF 10, EF injects one when it's absent, so EF and Dapper using the "same" string land in **different SqlClient pools**, and mixing them in a `TransactionScope` escalates to a distributed transaction (EF10 breaking change). With an explicit name EF leaves the string untouched.

### Query and write rules

- **Reads**: `AsNoTracking()` + `.Select()` projection to DTOs. Tracking is only for entities you'll mutate.
- **No lazy loading, ever.** N+1 (one query per row) is the lazy-loading failure mode — fix with a projection or explicit `Include`.
- **Cartesian explosion** is the opposite failure: sibling collection `Include`s multiply rows in one query — fix with `.AsSplitQuery()` or a narrower projection.
- **Set-based writes**: `ExecuteUpdateAsync`/`ExecuteDeleteAsync` instead of load-modify-save loops.
- Hot, parameter-stable queries: `EF.CompileAsyncQuery`.
- Concurrency: `[Timestamp] byte[]` (rowversion) on MSSQL; on Postgres `[Timestamp] uint Version` maps to the `xmin` system column. Catch `DbUpdateConcurrencyException` and resolve deliberately (reload + tell the user, or refresh original values and retry) — example in [references/best-practices.md](references/best-practices.md).
- **Outside a request** (hosted/background services, singletons, cache factories): never capture a `DbContext` — `await using var db = await dbFactory.CreateDbContextAsync(ct)` per unit of work (the factory from the canonical block), or `IServiceScopeFactory.CreateAsyncScope()` when other scoped services are needed too.
- Configuration via `IEntityTypeConfiguration<T>` classes, not a 1000-line `OnModelCreating`.
- Never string-interpolate into `FromSqlRaw` — use `FromSql` (interpolated-handler, parameterizes automatically).

### Migrations

- `dotnet ef migrations add <Name>` — review the generated code, especially destructive ops.
- One provider per project; if a project supports multiple providers, keep migrations in provider-specific assemblies (`Migrations/Mssql`, `Migrations/Postgres`).
- Apply on deploy via SQL scripts or a migration bundle — **not** `Database.Migrate()` at production startup. (EF 9+'s migration lock fixed the old multi-instance race, but runtime migration remains officially discouraged: it needs elevated schema permissions, applies uninspected SQL, and has no clean rollback.) For single-instance/dev, startup migrate is fine.
- CI/CD: `has-pending-model-changes` gate, idempotent script or bundle built once as an artifact, applied as a one-shot step before the rollout with a separate schema-owner identity: [references/migrations-ci.md](references/migrations-ci.md).

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
- **Transient faults**: `EnableRetryOnFailure` covers only EF's own commands. Dapper on its *own* connection gets a Polly v8 `ResiliencePipeline` around the whole unit (open → execute → commit); Dapper on EF's connection runs inside `CreateExecutionStrategy().ExecuteAsync` like the seam example. Details: [references/efcore-dapper-seam.md](references/efcore-dapper-seam.md).

## EF Core + Dapper together — the seam

They are one data layer, not two. Rules that keep the seam fast and correct:

**One connection, one transaction.** When Dapper work belongs to an EF unit of work (e.g. outbox insert), run it on EF's connection inside EF's transaction — a second connection means a second pool slot and *no atomicity*:

```csharp
public sealed class OrderService(AppDbContext db)
{
    public async Task PlaceAsync(Order order, CancellationToken ct)
    {
        db.Orders.Add(order);   // outside the delegate — a retry must not Add again

        // EnableRetryOnFailure requires the execution strategy to own the whole transaction —
        // BeginTransaction without it throws with retries enabled. Use the (state, token) overload
        // with ct LAST: passing ct AS the state compiles but hides cancellation from the retry machinery.
        // static lambda + tuple state: nothing captured
        // The outbox row id is the AMQP MessageId: one fresh id PER MESSAGE, never the aggregate id (a second
        // event for the same order would hit the PK / be deduped away by the consumer inbox). Created BEFORE
        // the strategy so a replay reuses it. v7 is also fine on SQL Server here: dbo.OutboxMessages clusters
        // on Seq and Id is a NONCLUSTERED PK (rabbitmq-messaging → outbox-inbox.md); an outbox clustered on
        // Id would need a SQL-Server-sequential Guid instead (mssql → Index design).
        var messageId = Guid.CreateVersion7();
        var strategy = db.Database.CreateExecutionStrategy();
        await strategy.ExecuteAsync((Db: db, Order: order, MessageId: messageId), static async (s, token) =>
        {
            await using var tx = await s.Db.Database.BeginTransactionAsync(token);

            // acceptAllChangesOnSuccess: false keeps the entities Added, so a retry after a
            // failed commit replays the same insert instead of finding nothing to save
            await s.Db.SaveChangesAsync(acceptAllChangesOnSuccess: false, token);

            var conn = s.Db.Database.GetDbConnection();         // EF's connection — never dispose it
            await conn.ExecuteAsync(new CommandDefinition(
                "INSERT INTO outbox_messages (id, type, payload) VALUES (@Id, @Type, @Payload)",
                new { Id = s.MessageId, Type = "order.created", Payload = Serialize(s.Order) },
                transaction: tx.GetDbTransaction(),             // EF's transaction
                cancellationToken: token));

            await tx.CommitAsync(token);
        }, ct);

        db.ChangeTracker.AcceptAllChanges();   // only after the commit succeeded
    }

    // static: called from the static lambda
    private static string Serialize(Order order) =>
        JsonSerializer.Serialize(new OrderCreated(order.Id, order.Quantity), AppJsonContext.Default.OrderCreated);
}
```

A connection drop *during* commit leaves the outcome unknown and the strategy retries as if rolled back — make the replay fail loudly with **client-generated keys assigned before the strategy runs**, or verify with `ExecuteInTransactionAsync(..., verifySucceeded: ...)` (seam reference). The key generator depends on the provider:
- **PostgreSQL / SQLite**: `Guid.CreateVersion7()` (time-ordered, index-friendly), set when the entity is created.
- **SQL Server**: **not** UUIDv7 — `uniqueidentifier` sorts by its last bytes, so v7 fragments a clustered index like `NEWID()`. Keep EF's default for `Guid` keys, `SequentialGuidValueGenerator`: it generates the value client-side when the entity is tracked as `Added` (`db.Orders.Add(order)`, outside the strategy), and the `acceptAllChangesOnSuccess: false` replay reuses it. Or a non-clustered Guid PK with a sequential clustered key (`mssql` → Index design rules).

**Shared plumbing per provider:**
- **Postgres**: one singleton `NpgsqlDataSource` feeds *both* — `UseNpgsql(dataSource)` for EF and inject it for Dapper. One pool, one place for enum/JSON mappings. Snake_case seam: `DefaultTypeMap.MatchNamesWithUnderscores = true;` once at startup so Dapper maps `customer_name` → `CustomerName`.
- **MSSQL**: explicit `Application Name=` in the connection string (EF10 otherwise rewrites EF's copy → separate pool, see above). Dapper string parameters are `nvarchar` by default — against `varchar` columns that's an implicit conversion → index scan. Use `new DbString { Value = v, IsAnsi = true }` (see `mssql`).
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
| Naming | PascalCase | snake_case (`EFCore.NamingConventions` → `UseSnakeCaseNamingConvention()`) | either |

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
| `DbContext` captured in a singleton / `BackgroundService` | `IDbContextFactory<T>` (canonical block) or a scope per unit of work |
| Two registrations for one context (`AddDbContextPool` + `AddDbContextFactory`) | One `AddPooledDbContextFactory` — it provides both the factory and the scoped context |
| EF InMemory provider or SQLite-in-memory standing in for MSSQL/Postgres in tests | Real engine via Testcontainers — EF docs discourage InMemory; SQLite differs in translation, case-sensitivity, raw SQL |
| MSSQL connection string without `Application Name` (EF 10) | Set it explicitly — otherwise EF and Dapper use two pools |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- EF Core: https://learn.microsoft.com/en-us/ef/core/
- Dapper: https://github.com/DapperLib/Dapper
- Npgsql: https://www.npgsql.org/doc/ (EF Core provider: https://www.npgsql.org/efcore/)
- Microsoft.Data.Sqlite: https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
- **EF Core + Dapper seam deep-dive (verified October 2026): [references/efcore-dapper-seam.md](references/efcore-dapper-seam.md) — read it when mixing the two or moving bulk data.**
- **Migrations in CI/CD (verified October 2026): [references/migrations-ci.md](references/migrations-ci.md).**
