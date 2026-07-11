# EF Core + Dapper — the seam, deep dive

Verified against official documentation, July 2026 (learn.microsoft.com EF Core & SqlClient docs, npgsql.org, DapperLib README/source, nuget.org). Full URLs in **Sources**. Conventions for all samples: net10.0, C# latest, nullable enabled, async with `CancellationToken` threaded, DTO projections.

## Current versions (July 2026)

| Package | Version | Notes |
|---|---|---|
| Microsoft.EntityFrameworkCore | 10.0.9 (2026-06-09) | EF 11 in preview (11.0.0-preview.5) |
| Dapper | 2.1.79 (2026-05-16) | |
| Npgsql.EntityFrameworkCore.PostgreSQL | 10.0.3 (2026-07-10) | depends on Npgsql ≥ 10.0.3 |
| Microsoft.Data.SqlClient | 7.0.2 (2026-06-25) | |
| Microsoft.Data.Sqlite | 10.0.x | ships with the EF 10 release train |

## Established patterns

### 1. One connection, one transaction (EF owns it)

`Database.GetDbConnection()` returns the ADO.NET `DbConnection` EF uses; `IDbContextTransaction.GetDbTransaction()` returns the underlying `DbTransaction` — both are the documented interop surface (EF "Transactions" page, cross-context and external-`DbTransaction` sections). Ownership rule from the API docs: **do not dispose the connection if EF created it** (i.e. you passed a connection string to `UseSqlServer`/`UseNpgsql`); if you passed a `DbConnection` in, disposing it is your job. Inside `BeginTransactionAsync` the connection is open for the transaction's lifetime; outside a transaction, bracket Dapper calls with `Database.OpenConnectionAsync(ct)` / `CloseConnectionAsync()` so EF's open/close bookkeeping stays consistent.

With `EnableRetryOnFailure`, `BeginTransactionAsync` outside the strategy throws `InvalidOperationException: The configured execution strategy '...RetryingExecutionStrategy' does not support user-initiated transactions. Use the execution strategy returned by 'DbContext.Database.CreateExecutionStrategy()' ...` — the delegate is the retriable unit and must be re-runnable from the top (no captured dirty state):

```csharp
public sealed class OrderService(AppDbContext db)
{
    public async Task PlaceAsync(Order order, CancellationToken ct)
    {
        var strategy = db.Database.CreateExecutionStrategy();
        // Overload: ExecuteAsync<TState>(TState, Func<TState, CancellationToken, Task>, CancellationToken)
        // — pass ct as the LAST argument so the strategy itself observes cancellation between retries.
        await strategy.ExecuteAsync((db, order), static async (state, token) =>
        {
            var (db, order) = state;
            await using var tx = await db.Database.BeginTransactionAsync(token);

            db.Orders.Add(order);
            await db.SaveChangesAsync(token);

            var conn = db.Database.GetDbConnection();            // EF's connection — do not dispose
            await conn.ExecuteAsync(new CommandDefinition(
                "INSERT INTO outbox_messages (id, type, payload) VALUES (@Id, @Type, @Payload)",
                new { order.Id, Type = "order.created", Payload = Serialize(order) },
                transaction: tx.GetDbTransaction(),              // EF's transaction
                cancellationToken: token));

            await tx.CommitAsync(token);
        }, ct);
    }
}
```

`ExecuteAsync<TState>(TState, Func<TState, Task>)` also exists, so passing the token *as the state* compiles and delivers it to your delegate — but then the strategy has no token of its own (retry delays are uncancellable). Prefer the overload above.

### 2. Transaction interop, ranked

1. **EF owns** — `Database.BeginTransactionAsync` + `GetDbConnection()`/`GetDbTransaction()` (pattern 1). Default; keeps savepoint-on-`SaveChanges` behavior (note: savepoints are disabled under SQL Server MARS).
2. **Your code owns** — open a `DbConnection` yourself, `BeginTransactionAsync` on it, run Dapper, then enlist EF: build options with `UseSqlServer(connection)`/`UseNpgsql(connection)` and call `Database.UseTransactionAsync(dbTransaction)`. This is the docs' "Using external DbTransactions" pattern; use it when Dapper is the primary actor or several contexts share one transaction.
3. **Ambient `TransactionScope`** — documented but last resort. Officially listed limitations: provider support varies (SqlClient yes; test yours), distributed transactions require .NET 7+ **and Windows only**, and `TransactionScope` has **no async commit/rollback** — disposal blocks the thread. If used with async code you must pass `TransactionScopeAsyncFlowOption.Enabled` or the ambient transaction will not flow across `await`. Under retries, wrap the whole scope in `CreateExecutionStrategy().ExecuteAsync(...)` (docs show this combination explicitly).
4. **Cross-service** — never a distributed transaction; outbox + broker.

### 3. Connection pool mechanics at the seam

Sharing EF's connection for in-transaction Dapper work isn't just about atomicity — a second connection per request doubles pool pressure and can deadlock the pool under load (request holds slot A while queueing for slot B).

- **SqlClient**: one pool per *exact* connection string text (keyword order matters), further split by Windows identity and by transaction enlistment. `Max Pool Size` default **100**, `Min Pool Size` 0; on exhaustion the open call queues up to `Connect Timeout` (default **15 s**) then throws. After a login failure the pool blocks new attempts for 5 s, doubling up to 1 min (`PoolBlockingPeriod`). Pool *fragmentation*: per-user integrated security and per-database connection strings each mint a new pool — connect to one database and `USE`/schema-switch instead. `SqlConnection.ClearPool(conn)` / `ClearAllPools()` discard connections (e.g. after failover; fatal errors already auto-clear).
- **Npgsql**: the pool lives behind the `NpgsqlDataSource` / connection string. Defaults: `Pooling=true`, `Maximum Pool Size` **100**, `Minimum Pool Size` 0, `Connection Idle Lifetime` 300 s, pruned every 10 s. One **singleton** `NpgsqlDataSource` = one pool; `NpgsqlConnection.ClearPool` / `ClearAllPools` exist.
- **SQLite (Microsoft.Data.Sqlite)**: pooled by default since 6.0 (`Pooling=False` to opt out; `SqliteConnection.ClearPool`). The real constraint is the single writer — keep write batches in one transaction.

**Postgres wiring** — one data source feeds both sides (`UseNpgsql(NpgsqlDataSource)` is a documented overload; the Npgsql EF docs direct you to create and pass an external data source whenever configuration varies or the source is shared). Dapper's snake_case mapping: `DefaultTypeMap.MatchNamesWithUnderscores` is a real static property on `Dapper.DefaultTypeMap` ("Should column names like User_Id be allowed to match properties/fields like UserId?").

```csharp
var dsBuilder = new NpgsqlDataSourceBuilder(cs);   // enums, JSON, interceptors — configured once
builder.Services.AddSingleton(dsBuilder.Build());
builder.Services.AddDbContextPool<AppDbContext>((sp, o) => o
    .UseNpgsql(sp.GetRequiredService<NpgsqlDataSource>(), npgsql => npgsql.EnableRetryOnFailure())
    .UseSnakeCaseNamingConvention());
DefaultTypeMap.MatchNamesWithUnderscores = true;   // once at startup
```

### 4. Streaming without buffering

- **Dapper**: default behavior "buffers the entire reader on return" (README) — right for small/medium sets. For large sets use `QueryUnbufferedAsync<T>` (extension on `DbConnection`, returns `IAsyncEnumerable<T>`) or `buffered: false` on sync `Query`. Both are lazy: **the connection (and any transaction) must stay open until enumeration completes** — an `await using var conn` that closes before the consumer finishes enumerating is a bug. Thread cancellation via `WithCancellation(ct)` / `[EnumeratorCancellation]`.
- **EF**: `AsNoTracking().Select(...).AsAsyncEnumerable()` streams rows. Caveat straight from the resiliency page: enabling retry on failure "causes EF to internally buffer the resultset" — retries and streaming are mutually exclusive; run genuinely-streaming endpoints on a context/strategy without retries (or accept buffering).

```csharp
public async IAsyncEnumerable<OrderRowDto> ExportAsync([EnumeratorCancellation] CancellationToken ct = default)
{
    await using var conn = await dataSource.OpenConnectionAsync(ct);  // outlives the enumeration
    await foreach (var row in conn.QueryUnbufferedAsync<OrderRowDto>(
        "SELECT id, total, created_at FROM orders").WithCancellation(ct))
    {
        yield return row;
    }
}
```

### 5. Parameter typing — the silent index killers

The database can't seek an index when the parameter type outranks the column type; it converts the *column side* → scan. EF gets types from the model; raw Dapper parameters are inferred from the CLR type, so Dapper is where this bites.

- **MSSQL, strings**: .NET strings become `nvarchar` parameters. Against a `varchar` column that's an implicit widening conversion → scan. Dapper README: for varchar predicates pass `new DbString { Value = v, IsAnsi = true }` (plus `IsFixedLength`/`Length` for `char(n)`); "On SQL Server it is crucial to use the unicode when querying unicode and ANSI when querying non unicode."
- **MSSQL, DateTime**: `DateTime` infers legacy `datetime`; against `datetime2` columns set `DbType.DateTime2` explicitly to avoid conversion and precision loss.
- **Decimal**: inferred precision/scale can truncate or mismatch — declare `HasPrecision(18, 2)` in the EF model and pass explicit precision/scale (`DbType.Decimal` + sized `DbString`-style typing or a typed `DbParameter`) in hand-written commands.
- **PostgreSQL**: `timestamptz` requires `DateTime.Kind == Utc`; unspecified/local kinds map to `timestamp` and Npgsql throws on mismatch (fail-fast, unlike MSSQL's silent scan). `text`/`varchar` are the same type family — no ANSI trap.

### 6. Bulk ingestion — the documented fast paths

Row-by-row APIs (including EF `Add` loops) are wrong from ~1k rows. After any bulk load, refresh statistics (provider skills).

**MSSQL — `SqlBulkCopy`** ("significant performance advantage" over INSERTs per the docs; can run inside an existing transaction via the constructor that takes a `SqlTransaction`):

```csharp
public async Task BulkLoadAsync(IReadOnlyList<MeasurementDto> rows, CancellationToken ct)
{
    await using var conn = new SqlConnection(cs);
    await conn.OpenAsync(ct);
    using var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.TableLock, externalTransaction: null)
    {
        DestinationTableName = "dbo.Measurements",
        BatchSize = 10_000,
    };
    bulk.ColumnMappings.Add(nameof(MeasurementDto.SensorId), "SensorId");   // always map explicitly
    bulk.ColumnMappings.Add(nameof(MeasurementDto.Value), "Value");
    await bulk.WriteToServerAsync(ToDataReader(rows), ct);                  // IDataReader source streams
}
```

`TableLock` enables minimally-logged loads into empty/heap targets; drop it for concurrent-write tables.

**PostgreSQL — binary COPY** (npgsql.org: the efficient binary format; all-async API verified: `BeginBinaryImportAsync`, `StartRowAsync`, `WriteAsync<T>(value, NpgsqlDbType, ct)`, `WriteNullAsync`, `CompleteAsync` → `ValueTask<ulong>`). Disposing without `Complete` rolls the import back — that is the documented cancellation/failure path. Always pass `NpgsqlDbType`; wrong types mean exceptions or "silent data corruption" (docs' words):

```csharp
await using var conn = await dataSource.OpenConnectionAsync(ct);
await using var writer = await conn.BeginBinaryImportAsync(
    "COPY measurements (sensor_id, value) FROM STDIN (FORMAT BINARY)", ct);
foreach (var row in rows)
{
    await writer.StartRowAsync(ct);
    await writer.WriteAsync(row.SensorId, NpgsqlDbType.Integer, ct);
    await writer.WriteAsync(row.Value, NpgsqlDbType.Double, ct);
}
await writer.CompleteAsync(ct);   // no Complete => rollback on dispose
```

**SQLite** — no bulk API; the docs' pattern is one transaction + one reused parameterized command (subsequent executions reuse the first compilation):

```csharp
await using var tx = (SqliteTransaction)await conn.BeginTransactionAsync(ct);
var cmd = conn.CreateCommand();
cmd.Transaction = tx;
cmd.CommandText = "INSERT INTO measurements (sensor_id, value) VALUES ($sensorId, $value)";
var pSensor = cmd.Parameters.Add("$sensorId", SqliteType.Integer);
var pValue  = cmd.Parameters.Add("$value", SqliteType.Real);
foreach (var row in rows)
{
    (pSensor.Value, pValue.Value) = (row.SensorId, row.Value);
    await cmd.ExecuteNonQueryAsync(ct);
}
await tx.CommitAsync(ct);
```

**Medium batches (any provider)** — EF `AddRange` + one `SaveChangesAsync` is fine into the low thousands: EF batches all pending changes into minimal roundtrips. Batch size is provider-tuned — SQL Server defaults to at most **42 statements per batch** (measured optimum; batching is skipped below 4 statements) — and adjustable via `MinBatchSize`/`MaxBatchSize` on the provider options; benchmark before changing. `ExecuteUpdateAsync`/`ExecuteDeleteAsync` are the set-based escape hatch: per the docs they "are completely unaware of EF's change tracker", execute immediately, don't batch with each other, and start **no implicit transaction** — wrap multiple calls (or mixes with `SaveChanges`) in an explicit transaction, and expect stale tracked entities afterwards.

### 7. Keeping Dapper SQL in sync with EF migrations

The schema is EF's; Dapper strings can't be compile-checked. Enforce with process + tests:

- Dapper SQL lives only in `*Queries` classes — grep surface per migration (`rg -l 'old_column' src/**/ *Queries*`).
- Integration tests on a real database (Testcontainers): apply **all migrations** to a fresh container, then execute every `*Queries` method — a renamed/retyped column fails the run. Cheap variant: one parameterized test that walks all query classes and asserts each executes (LIMIT 0 / TOP 0 where needed).
- Never assert on EF-generated SQL text; assert on data equivalence (row count, columns, cell values) per the provider skills.

## Anti-patterns

- Dapper on its own connection inside an EF unit of work — no atomicity, two pool slots per request, pool-exhaustion deadlocks under load.
- Disposing the connection from `GetDbConnection()` when EF created it (ownership is EF's — documented in the API remarks).
- `BeginTransactionAsync` with `EnableRetryOnFailure` outside `CreateExecutionStrategy().ExecuteAsync` — throws `InvalidOperationException` by design.
- Passing the `CancellationToken` as the *state* argument of `ExecuteAsync` — compiles, but the strategy itself never sees the token; use an overload with a real `CancellationToken` parameter.
- Retry-enabled context for streaming endpoints — retries buffer the entire resultset.
- Returning a lazy `buffered: false` / `QueryUnbufferedAsync` sequence after the connection is disposed.
- Plain `string` Dapper parameters against `varchar` columns on MSSQL — implicit `nvarchar` conversion flips seeks to scans; use `DbString { IsAnsi = true }`.
- `ExecuteUpdate`/`ExecuteDelete` sequences without an explicit transaction when they must be atomic — each runs in its own implicit transaction.
- Bulk loads via row-by-row `INSERT` or per-row `SaveChanges` — use `SqlBulkCopy` / binary COPY / SQLite single-transaction pattern.
- Many near-identical connection strings (per user, per database) — pool fragmentation; one canonical string per role.

## Sources

- https://learn.microsoft.com/en-us/ef/core/saving/transactions
- https://learn.microsoft.com/en-us/ef/core/miscellaneous/connection-resiliency
- https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.executionstrategyextensions
- https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.relationaldatabasefacadeextensions.getdbconnection
- https://learn.microsoft.com/en-us/ef/core/performance/efficient-updating
- https://learn.microsoft.com/en-us/ef/core/saving/execute-insert-update-delete
- https://learn.microsoft.com/en-us/sql/connect/ado-net/sql-server-connection-pooling
- https://learn.microsoft.com/en-us/sql/connect/ado-net/sql/bulk-copy-operations-sql-server
- https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/bulk-insert
- https://www.npgsql.org/efcore/index.html
- https://www.npgsql.org/doc/copy.html
- https://www.npgsql.org/doc/connection-string-parameters.html
- https://www.npgsql.org/doc/api/Npgsql.NpgsqlBinaryImporter.html
- https://www.npgsql.org/doc/api/Npgsql.NpgsqlConnection.html
- https://github.com/DapperLib/Dapper (README; Dapper/DefaultTypeMap.cs)
- https://www.nuget.org/packages/Microsoft.EntityFrameworkCore | /Dapper | /Npgsql.EntityFrameworkCore.PostgreSQL | /Microsoft.Data.SqlClient
