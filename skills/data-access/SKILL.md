---
name: data-access
description: Use when writing database code in .NET — choosing between EF Core and Dapper, writing queries, DbContext setup, migrations, slow queries, N+1 problems, or working with SQL Server (MSSQL), PostgreSQL, or SQLite.
---

# Data Access — EF Core & Dapper

## Overview

EF Core is the default (change tracking, migrations, LINQ safety). Dapper is the escalation for **measured** hot paths. Both always: parameterized, async with `CancellationToken`, project to DTOs.

## EF Core vs Dapper decision

Use **Dapper** when any of these hold, otherwise **EF Core**:
- Profiled hot read path where EF materialization/translation overhead matters
- Hand-tuned SQL (window functions, CTEs, provider-specific hints, bulk ops)
- Dashboard/reporting queries with wide joins and custom shapes

Both can share one database and one migration story (EF owns the schema; Dapper just reads/writes it). Put Dapper queries in dedicated `*Queries` classes so the split stays visible.

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
- Apply on deploy via `dotnet ef database update` or `migrationBundle` — **not** `Database.Migrate()` in multi-instance production startup (race between instances). For single-instance/dev, startup migrate is fine.

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

## Provider notes

| | MSSQL | PostgreSQL | SQLite |
|---|---|---|---|
| Use for | Enterprise/existing estates | Default for new server projects | Embedded, tools, small single-node apps |
| Concurrency token | `rowversion` | `xmin` | manual version column |
| Naming | PascalCase | snake_case (naming-convention package) | either |
| Gotchas | `MultipleActiveResultSets` off; use `datetime2` | case-sensitive identifiers; `timestamptz` vs `timestamp` | one writer at a time — enable WAL via `PRAGMA journal_mode=WAL;` once after opening (persists per DB file; it is NOT a connection-string keyword); no `TimeSpan`/decimal precision in SQL |

SQLite in production: it's fine for single-node, low-write apps, but put all writes through one connection/queue and keep transactions short.

## Common mistakes

| Mistake | Fix |
|---|---|
| Tracking + full entity for read-only lists | `AsNoTracking` + projection |
| `.ToList()` then filtering in memory | Compose the `IQueryable`, filter in SQL |
| Repository wrapping every DbSet 1:1 | Use DbContext directly in slices; add query classes only where shapes are shared |
| `Database.Migrate()` on multi-instance startup | Migration bundle / deploy step |
| Dapper with interpolated SQL | Parameters via anonymous object |
| Opening one shared `DbConnection` singleton (MSSQL/SQLite) | Connection per operation; ADO.NET pools for you (Postgres: singleton `NpgsqlDataSource` is the exception and correct) |
