# EF Core + Dapper — Best Practices Reference

Verified against official documentation, July 2026. Extends `SKILL.md` (same conventions: net10.0, C# latest, nullable enabled, async with `CancellationToken`, DTO projections for reads, parameterized SQL only). Primary sources: EF Core performance docs, EF Core 10 release notes, Dapper README, Npgsql docs, Microsoft.Data.Sqlite docs — full URL list at the bottom.

## Current versions (July 2026)

| Package | Version | Notes |
|---|---|---|
| Microsoft.EntityFrameworkCore | **10.0.9** (2026-06-09) | EF10 is LTS, released Nov 2025, supported until 2028-11-10. Requires .NET 10; will not run on earlier .NET or .NET Framework. 11.0 previews exist — do not use in production. |
| Dapper | **2.1.79** (2026-05-16) | Targets net10.0, net8.0, netstandard2.0, net461+. |
| Npgsql (ADO.NET) | **10.0.3** | `NpgsqlDataSource` is the entry point since Npgsql 7. |
| Npgsql.EntityFrameworkCore.PostgreSQL | **10.0.3** (2026-07-10) | Pairs with EF Core 10.x. |
| Microsoft.Data.Sqlite | **10.0.9** (2026-06-09) | Ships on the EF Core release train. |

## Established patterns

### Efficient querying (EF Core performance docs)

- **Indexes decide query speed** — EF adds no magic here. `StartsWith` can use an index; `EndsWith` cannot. Filters on expressions (`price / 2`) need a computed persisted column with an index, or a provider expression index. Composite index on (A, B) helps filters on A+B and A alone, not B alone.
- **Project only needed columns.** Querying full entities pulls every column; `.Select()` to a DTO pulls only what you use. This is the documented default for read paths.
- **Bound every resultset.** Untested-at-scale unbounded queries are a documented pitfall: always `Take(n)` or paginate. For page-at-a-time navigation the docs recommend **keyset pagination** over `Skip/Take` (OFFSET is inefficient for deep pages).
- **Eager-load, don't lazy-load.** Lazy loading is "particularly prone" to N+1 (one roundtrip per row) and the docs recommend avoiding it. Use `Include` (with *filtered include* to limit rows) or, better, a projection that pulls the related data in the same query.
- **Streaming vs buffering.** `ToListAsync`/`ToArrayAsync` buffer; `AsAsyncEnumerable` streams with fixed memory. EF buffers internally regardless when (a) a retrying execution strategy is active, or (b) split query is used without MARS — with `ToList` on top you buffer *twice*.
- **No-tracking for reads.** Docs benchmark: `AsNoTracking` ≈ 0.71x the time and ~60% of the allocations of tracking for a 10x20 row load. Caveat: no identity resolution — a row referenced by many parents materializes as duplicate instances. A `.Select()` DTO projection is untracked anyway, which is why projections are the preferred read shape.
- **Raw SQL is a last resort** — only when EF can't generate the SQL you need. `FromSql` (interpolated handler, auto-parameterized) composes with LINQ; EF10 adds an **analyzer warning for string concatenation inside `FromSqlRaw`** and friends.
- **Async everywhere, never mixed.** Sync APIs block threads; the docs explicitly warn that mixing sync and async database code triggers thread-pool starvation. Known caveat: Microsoft.Data.SqlClient's async path has documented perf issues with large text/binary values.

```csharp
public sealed record OrderRow(int Id, decimal Total, string CustomerName);

public async Task<IReadOnlyList<OrderRow>> GetTopOrdersAsync(int take, CancellationToken ct) =>
    await db.Orders
        .OrderByDescending(o => o.Total)
        .Take(take)
        .Select(o => new OrderRow(o.Id, o.Total, o.Customer.Name))  // projection: untracked, minimal columns
        .ToListAsync(ct);
```

### DbContext pooling

- `AddDbContextPool<T>()` resets and reuses context instances; docs benchmark ~2x faster and ~10x fewer allocations than non-pooled for a single-row fetch. Orthogonal to ADO.NET connection pooling.
- Default `poolSize` is **1024** (max retained instances); beyond it EF silently falls back to creating instances per request — size it to your concurrency, not higher.
- Pooled contexts behave like singletons: **`OnConfiguring` runs once**, and any per-request state (tenant ID, user) must be injected explicitly. Official pattern: `AddPooledDbContextFactory<T>()` (singleton) wrapped by a scoped `IDbContextFactory<T>` that stamps the state onto each context it hands out.
- EF resets its own state on return to the pool but **not ADO.NET state** — if you manually open a `DbConnection` on the context, close it before the context is disposed or state leaks across requests.
- Micro-optimizations from the docs, for measured hot paths only: use `PooledDbContextFactory` directly (skips DI overhead) and `EnableThreadSafetyChecks(false)` (only after proving no concurrent-use bugs).

### Compiled queries and query caching

- EF caches compiled queries by expression-tree shape; parameterized queries share one cache entry and one database plan. The `Query Cache Hit Rate` metric should sit at ~100% after startup — if it doesn't, something is defeating the cache (usually dynamically built trees embedding `Expression.Constant`, which the docs benchmark at >2x slower plus cache pollution).
- `EF.CompileAsyncQuery` bypasses even the cache lookup — the documented fastest way to run a query. Use for hot, shape-stable queries; gains grow with query complexity. Limitations: one EF model only; simple scalar parameters only (no member/method access expressions). The delegate is thread-safe across context instances.

```csharp
private static readonly Func<AppDbContext, int, CancellationToken, Task<OrderRow?>> GetOrder =
    EF.CompileAsyncQuery((AppDbContext db, int id, CancellationToken ct) =>
        db.Orders.Where(o => o.Id == id)
            .Select(o => new OrderRow(o.Id, o.Total, o.Customer.Name))
            .FirstOrDefault());
```

- Compiled **models** (`dotnet ef dbcontext optimize`) are a different feature: they cut *startup* time for very large models (hundreds+ entity types). Not worth it for small models; global query filters and lazy-loading/change-tracking proxies are unsupported; must be regenerated on every model change.

### Split vs single query — official position

- Default is single query. Sibling collection `Include`s at the same level produce a **cartesian explosion** (rows = product of the collections); nested `ThenInclude` chains do not. EF warns when a query loads multiple collections and no splitting behavior was configured.
- `AsSplitQuery()` trades the explosion for: no cross-query consistency guarantee (mitigate with a snapshot/serializable transaction if it matters), one extra roundtrip per collection (worse on high-latency links), and buffering of all but the last resultset unless MARS (SQL Server) allows concurrent readers. One-to-one navigations always stay as JOINs.
- The docs are explicit that **there is no one-size-fits-all**: choose per query; `UseQuerySplittingBehavior(QuerySplittingBehavior.SplitQuery)` sets a global default with `AsSingleQuery()` as per-query opt-out.
- EF10 fixed split-query ordering to be fully deterministic with `Skip`/`Take`; on EF ≤ 9 you must add a unique ordering (e.g. `.OrderBy(x => x.Date).ThenBy(x => x.Id)`) or split queries can return wrong rows.

### Set-based writes: ExecuteUpdate / ExecuteDelete

- `ExecuteUpdateAsync` / `ExecuteDeleteAsync` run a single UPDATE/DELETE without loading entities — the documented replacement for load-modify-save loops. They bypass change tracking and `SaveChanges` (no concurrency tokens, no interceptor `SavingChanges` events).
- EF10: the setters argument can be a **regular lambda** (not an expression tree), so conditional setters are plain code now:

```csharp
await db.Orders.Where(o => o.Id == id).ExecuteUpdateAsync(s =>
{
    s.SetProperty(o => o.Total, total);
    if (recalculateTax) s.SetProperty(o => o.Tax, total * taxRate);
}, ct);
```

- EF10 also supports `ExecuteUpdateAsync` into **JSON columns mapped as complex types** (not owned entities).
- For bulk *ingest*, EF has no first-class bulk-copy API: the documented levers are batched `SaveChanges` (EF batches automatically), `ExecuteUpdate/Delete` for set operations, and dropping to provider bulk APIs (`SqlBulkCopy`, Npgsql binary `COPY`) via the shared connection for measured hot paths.

### EF Core 10 changes that affect day-to-day code

- **Parameterized collections**: `ids.Contains(x.Id)` now translates to individual scalar parameters (`IN (@ids1, @ids2, ...)`) with padding — fixes both plan-cache bloat (pre-EF8 constants) and cardinality blindness (EF8 JSON-array). Override globally via `UseParameterizedCollectionMode(ParameterTranslationMode...)` or per query with `EF.Constant(...)` / `EF.Parameter(...)`.
- **`LeftJoin` / `RightJoin`** LINQ operators translate directly — no more `GroupJoin`/`SelectMany`/`DefaultIfEmpty` contortions.
- **Named query filters**: multiple filters per entity, selectively disabled — `HasQueryFilter("SoftDeletion", ...)` + `IgnoreQueryFilters(["SoftDeletion"])`.
- **Complex types** now support optional (`Address?`), structs, and JSON-column mapping; docs advise migrating owned-entity JSON/table-splitting to complex types (value semantics, `ExecuteUpdate` support).
- Logging redacts inlined constants by default (`?` placeholders); `EnableSensitiveDataLogging` restores them for debugging.
- Migrations no longer run in one spanning transaction (reverts an EF9 change).
- SQL Server 2025 / Azure SQL: native `vector` type (`SqlVector<float>` + `EF.Functions.VectorDistance`) and native `json` column type (default at compat level 170+; existing `nvarchar(max)` JSON columns get converted by the next migration unless you pin the column type).

### Interceptors

- Registered via `AddInterceptors(...)` on the options builder; each instance registered once even if it implements several `IInterceptor` interfaces. Use cases documented: command mutation (query hints via query tags), connection auth (Azure AD tokens), `SaveChanges` auditing, materialization hooks.
- Implement **both sync and async** method pairs or one path silently misses the behavior.
- `IMaterializationInterceptor`, `IQueryExpressionInterceptor`, `IIdentityResolutionInterceptor` are *singleton interceptors*: they become part of EF's internal service provider. **Reuse one instance** — passing `new MyInterceptor()` inside `AddDbContext` builds a new internal service provider each time (`ManyServiceProvidersCreatedWarning`, degraded performance). Stateless interceptors should be `static readonly` singletons regardless of kind.

### Migration deployment (official trade-offs)

| Option | Official position |
|---|---|
| **SQL scripts** (`dotnet ef migrations script [--idempotent]`) | *Recommended* for production: reviewable, tunable, DBA-friendly, CI-generatable. Idempotent scripts check the history table — use when target state is unknown or fleets of databases differ. Not covered by migration locking. |
| **Bundles** (`dotnet ef migrations bundle [--self-contained -r linux-x64]`) | Single-file executable; no SDK/EF tool/source (nor .NET runtime if self-contained) needed on the target. Good CI/CD fit; consistent transaction handling vs. ad-hoc script runners. Needs `appsettings.json` beside it (or `--connection`). |
| **CLI** (`dotnet ef database update`) | Dev/test only: applies SQL uninspected, needs SDK + source on the box. |
| **Runtime** (`Database.MigrateAsync()` at startup) | Documented as *inappropriate for production*: app needs schema-change (elevated) permissions, SQL applied uninspected, rollback is awkward. Since EF9, `Migrate`/bundles/CLI acquire a **database-wide migration lock**, so the old concurrent-instance corruption race is handled — the other objections stand. Never call `EnsureCreatedAsync()` before `MigrateAsync()`; it bypasses the history table and breaks migrations. |

Also since EF9: `Migrate()` throws if the model has pending changes vs. the last migration — gate CI with `dotnet ef migrations has-pending-model-changes`. SQLite caveat: the migration-lock table can be left abandoned if the process dies, blocking later migrations.

### Dapper (README-verified)

- **Buffered by default**: the whole reader is materialized on return — right default for typical result sizes. `buffered: false` streams for huge resultsets, but the connection stays busy until iteration completes.
- **Multi-mapping** (`QueryAsync<TParent, TChild, TResult>`) maps one row into multiple objects; `splitOn` names the column where the split starts (default `"Id"`). Use for 1:1 joins; for 1:N prefer `QueryMultiple` (one command, several result grids read in order via `ReadAsync<T>`).
- **List expansion**: passing `new { Ids = ids }` with `WHERE Id IN @Ids` expands to `(@Ids1, @Ids2, ...)` — same plan-cache caveats as EF's constant mode; fine for small, bounded lists.
- **Literal replacement** `{=Value}` inlines bool/numeric values for plan-sensitive predicates — literals only, never strings (injection-safe because it rejects non-numeric/bool).
- **`DynamicParameters`** for dynamic SQL composition and output/return parameters (`ExecuteAsync` + `param.Get<int>("@out")`); templates can combine anonymous objects and added parameters.
- Cancellation flows via `CommandDefinition` (as in SKILL.md) — the plain `QueryAsync(sql, args)` overloads have no token.

```csharp
public async Task<IReadOnlyList<OrderWithCustomer>> GetRecentAsync(int take, CancellationToken ct)
{
    await using var conn = await dataSource.OpenConnectionAsync(ct);
    var rows = await conn.QueryAsync<OrderRow, CustomerRow, OrderWithCustomer>(
        new CommandDefinition("""
            SELECT o.id, o.total, c.id, c.name
            FROM orders o JOIN customers c ON c.id = o.customer_id
            ORDER BY o.created_at DESC LIMIT @take
            """, new { take }, cancellationToken: ct),
        (o, c) => new OrderWithCustomer(o, c),
        splitOn: "id");
    return rows.AsList();
}
```

### Provider notes

**Npgsql / PostgreSQL**
- `NpgsqlDataSource` (Npgsql 7+) is the entry point: build **one thread-safe singleton** and use it everywhere; connections drawn from it are pooled — open/close freely per operation.
- Positional parameters (`$1`) are PostgreSQL-native and fastest; named (`@p`) are supported but require SQL rewriting (Dapper uses named — acceptable, just known overhead).
- EF: pass config through `UseNpgsql(...)`; with EF9+/EF10 configure the data source via `ConfigureDataSource(...)` inside `UseNpgsql` — the docs warn against *varying* configuration inside `ConfigureDataSource` (the data source is cached; per-invocation differences are ignored). Postgres enums map via `MapEnum<T>("name")`, and when supplying an external data source the enum must be configured at both the ADO.NET and EF layers.
- PostgreSQL has no implicit plan cache like SQL Server; Npgsql's automatic statement preparation gives the equivalent effect for repeated statements.

**Microsoft.Data.Sqlite / SQLite**
- **SQLite has no async I/O: the async ADO.NET methods execute synchronously — docs say avoid calling them.** Design SQLite paths sync (still accept and pass `CancellationToken` at your API boundary for portability); use WAL for the actual concurrency/perf win.
- WAL (`PRAGMA journal_mode = 'wal'`) is a per-database-file persistent setting, applied once after opening — and **enabled by default for databases created by EF Core**.
- `SqliteConnection`/`SqliteCommand`/`SqliteDataReader` are **not thread-safe**; the documented pattern is a new `SqliteConnection` per operation — built-in pooling makes open fast.
- Busy/locked errors are retried automatically until `CommandTimeout` (default 30 s, `0` = infinite); implicit commands (e.g. `BeginTransaction`) use `SqliteConnection.DefaultTimeout`. Expect these errors under any concurrent write load; keep transactions short and serialize writes.
- EF10: SQLite `AUTOINCREMENT` can now be disabled and works with value converters; `DateTimeOffset`/UTC read behavior changed (see EF10 breaking changes) — retest date round-trips when upgrading.

## Anti-patterns

| Anti-pattern | Why (per docs) | Fix |
|---|---|---|
| Lazy loading in loops | N+1: one roundtrip per row; docs recommend avoiding lazy loading | Projection or `Include` (filtered include for subsets) |
| Full tracked entities for read-only lists | ~1.4x time, ~1.6x allocations vs no-tracking; snapshot cost | `.Select()` to DTO (untracked by nature) or `AsNoTracking()` |
| `ToListAsync()` then more LINQ | Buffers everything, filters in memory | Compose the `IQueryable`; filter/order/page in SQL |
| Unbounded queries / OFFSET paging deep pages | Resultset size unknown; OFFSET scans skipped rows | `Take(n)`; keyset pagination for next/previous |
| Sibling collection `Include`s, warning ignored | Cartesian explosion (rows multiply) | `AsSplitQuery()` per query, or project narrower shapes |
| `Expression.Constant` in dynamically built predicates | Recompilation per value + query/plan cache pollution; benchmark >2x slower | Build a closure-based lambda, or wrap the value via a parameter expression |
| `new SingletonInterceptor()` per `AddDbContext` call | New internal service provider each time; `ManyServiceProvidersCreatedWarning` | One `static readonly` instance, registered once |
| Load-modify-save loops for set operations | One SELECT + N row updates | `ExecuteUpdateAsync` / `ExecuteDeleteAsync` |
| `EnsureCreatedAsync()` + migrations | Bypasses history table; `MigrateAsync()` then fails | Migrations only (script/bundle in prod) |
| Startup `Database.MigrateAsync()` in production | Elevated schema permissions, uninspected SQL, hard rollback (EF9+ lock removes only the race argument) | Idempotent script or bundle in the deploy pipeline |
| String concat into `FromSqlRaw` / Dapper SQL | SQL injection; EF10 ships an analyzer warning for exactly this | `FromSql` interpolated handler; Dapper anonymous-object parameters |
| Mixing sync and async EF/ADO.NET calls | Documented thread-pool starvation risk | Async end-to-end (exception: SQLite is effectively sync anyway) |
| Sharing a `DbContext` or `SqliteConnection` across threads | Neither is thread-safe; EF throws when its check catches it | Context per unit of work; connection per operation |
| `buffered: false` + long row processing (Dapper) | Connection held hostage for the whole iteration | Default buffering unless the resultset is genuinely huge |
| Relying on split-query ordering with Skip/Take on EF ≤ 9 | Non-unique ordering returns wrong rows across the split | Add unique tiebreaker ordering (fixed in EF10) |

## Sources

- https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-10.0/whatsnew
- https://learn.microsoft.com/en-us/ef/core/performance/efficient-querying
- https://learn.microsoft.com/en-us/ef/core/performance/advanced-performance-topics
- https://learn.microsoft.com/en-us/ef/core/querying/single-split-queries
- https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/applying
- https://learn.microsoft.com/en-us/ef/core/logging-events-diagnostics/interceptors
- https://github.com/DapperLib/Dapper
- https://www.npgsql.org/doc/basic-usage.html
- https://www.npgsql.org/efcore/index.html
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/async
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/database-errors
- https://www.nuget.org/packages/Microsoft.EntityFrameworkCore (10.0.9)
- https://www.nuget.org/packages/Dapper (2.1.79)
- https://www.nuget.org/packages/Npgsql.EntityFrameworkCore.PostgreSQL (10.0.3)
- https://www.nuget.org/packages/Microsoft.Data.Sqlite (10.0.9)
