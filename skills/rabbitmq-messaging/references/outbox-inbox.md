# Outbox dispatcher + inbox — compilable reference

Verified October 2026 against the RabbitMQ.Client 7.x API reference (`ConnectionFactory.CreateConnectionAsync`, `CreateChannelOptions`, `IChannel.BasicPublishAsync`/`IsOpen`, `PublishException`), rabbitmq.com confirms/reliability guides, PostgreSQL (`FOR UPDATE SKIP LOCKED`, `ON CONFLICT`), SQL Server table hints (`UPDLOCK`, `READPAST`), and EF Core connection-resiliency docs. Extends `SKILL.md` → Outbox pattern / Consumer; confirm semantics in [best-practices.md](best-practices.md#publisher-confirms--what-a-basicack-actually-means).

Both tables belong to the EF model (EF owns the schema — add them through a migration, e.g. `migrationBuilder.Sql(...)` for the partial index).

## Outbox table

The row is written in the business transaction (`data-access` → "EF Core + Dapper together — the seam" inserts `id, type, payload`); everything else has defaults.

```sql
-- PostgreSQL
CREATE TABLE outbox_messages (
    id              uuid        PRIMARY KEY,                       -- becomes the AMQP MessageId
    seq             bigint      GENERATED ALWAYS AS IDENTITY,      -- dispatch order
    type            text        NOT NULL,                          -- routing key, e.g. order.created
    payload         text        NOT NULL,                          -- JSON (AppJsonContext)
    correlation_id  text        NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    attempts        int         NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error      text        NULL,
    sent_at         timestamptz NULL
);
CREATE INDEX ix_outbox_pending ON outbox_messages (next_attempt_at, seq) WHERE sent_at IS NULL;
```

```sql
-- SQL Server (Id: the app-generated UUIDv7 message id is fine here - the PK is NONCLUSTERED and the table clusters on Seq; see data-access / mssql)
CREATE TABLE dbo.OutboxMessages (
    Id            uniqueidentifier NOT NULL CONSTRAINT PK_OutboxMessages PRIMARY KEY NONCLUSTERED,
    Seq           bigint IDENTITY  NOT NULL,
    Type          varchar(200)     NOT NULL,
    Payload       nvarchar(max)    NOT NULL,
    CorrelationId varchar(100)     NULL,
    CreatedAt     datetime2        NOT NULL CONSTRAINT DF_Outbox_CreatedAt DEFAULT SYSUTCDATETIME(),
    Attempts      int              NOT NULL CONSTRAINT DF_Outbox_Attempts DEFAULT 0,
    NextAttemptAt datetime2        NOT NULL CONSTRAINT DF_Outbox_NextAttempt DEFAULT SYSUTCDATETIME(),
    LastError     nvarchar(2000)   NULL,
    SentAt        datetime2        NULL
);
CREATE UNIQUE CLUSTERED INDEX CX_OutboxMessages_Seq ON dbo.OutboxMessages (Seq);
CREATE INDEX IX_OutboxMessages_Pending ON dbo.OutboxMessages (NextAttemptAt, Seq) WHERE SentAt IS NULL;
```

## Dispatcher (PostgreSQL + RabbitMQ.Client 7)

Claim a batch with `FOR UPDATE SKIP LOCKED` (replicas never block each other or double-claim), publish each row with confirms, mark it sent **inside the claiming transaction**, commit. A failed publish pushes that row back with exponential backoff and ends the batch (keeps per-batch order). A crash after a confirm but before the commit republishes the row — harmless, consumers dedupe on `MessageId` (inbox below). The same holds for any failure other than a publish rejection (e.g. `AlreadyClosedException` when the channel or connection drops mid-batch): it escapes `DispatchBatchAsync`, the whole claim rolls back, and rows already confirmed earlier in that batch are republished on the next tick — equally harmless with the inbox.

```csharp
public sealed class OutboxDispatcher(
    NpgsqlDataSource dataSource,
    IOptions<RabbitOptions> options,
    ResiliencePipelineProvider<string> pipelines,       // "rabbit-connect": Polly v8 retry for the FIRST connect
    ILogger<OutboxDispatcher> logger) : BackgroundService
{
    private const int BatchSize = 50;
    private const string Exchange = "orders.events";     // {service}.events
    private static readonly ActivitySource Source = new("Orders.Outbox");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var factory = new ConnectionFactory
        {
            Uri = new Uri(options.Value.ConnectionString),
            ClientProvidedName = "orders-outbox",
        };
        // auto-recovery covers later drops, not the initial connect
        await using var connection = await pipelines.GetPipeline("rabbit-connect")
            .ExecuteAsync(async token => await factory.CreateConnectionAsync(token), stoppingToken);

        IChannel? channel = null;
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            do
            {
                try
                {
                    // closed channels are not recovered by the client — recreate
                    if (channel is not { IsOpen: true })
                    {
                        if (channel is not null) await channel.DisposeAsync();
                        // publish-only channel: the ctor's consumerDispatchConcurrency default (1) is irrelevant
                        // here — a consuming channel must pass consumerDispatchConcurrency explicitly (best-practices.md)
                        channel = await connection.CreateChannelAsync(new CreateChannelOptions(
                            publisherConfirmationsEnabled: true,
                            publisherConfirmationTrackingEnabled: true), stoppingToken);
                    }

                    int dispatched;
                    do { dispatched = await DispatchBatchAsync(channel, stoppingToken); }
                    while (dispatched == BatchSize);               // drain a backlog without waiting a tick
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;                                          // claimed rows roll back → republished later
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Outbox dispatch failed; retrying on the next tick");
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        finally
        {
            if (channel is not null) await channel.DisposeAsync();
        }
    }

    private async Task<int> DispatchBatchAsync(IChannel channel, CancellationToken ct)
    {
        using var activity = Source.StartActivity("outbox.dispatch");
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        // The claim sits "idle in transaction" while each confirm is awaited (≤ 10 s per row, the whole claim
        // up to BatchSize × 10 s). A role-level idle_in_transaction_session_timeout (postgres) below that
        // would kill the session mid-batch — lift it for THIS transaction only (SET LOCAL: pool-safe).
        await conn.ExecuteAsync(new CommandDefinition(
            "SET LOCAL idle_in_transaction_session_timeout = '30s'", transaction: tx, cancellationToken: ct));

        var rows = (await conn.QueryAsync<OutboxRow>(new CommandDefinition("""
            SELECT id, type, payload, correlation_id
            FROM outbox_messages
            WHERE sent_at IS NULL AND next_attempt_at <= now()
            ORDER BY seq
            LIMIT @batch
            FOR UPDATE SKIP LOCKED
            """, new { batch = BatchSize }, tx, cancellationToken: ct))).AsList();

        var handled = 0;
        foreach (var row in rows)
        {
            try
            {
                await PublishAsync(channel, row, ct);
            }
            catch (Exception ex) when (ex is PublishException
                                       || (ex is OperationCanceledException && !ct.IsCancellationRequested))
            {
                // nacked/returned, or confirm timed out (outcome unknown) → back off this row, stop the batch
                await conn.ExecuteAsync(new CommandDefinition("""
                    UPDATE outbox_messages
                    SET attempts = attempts + 1,
                        next_attempt_at = now() + make_interval(secs => least(300, power(2, least(attempts + 1, 9)))),
                        last_error = @error
                    WHERE id = @id
                    """, new { id = row.Id, error = ex.GetType().Name }, tx, cancellationToken: ct));
                logger.LogWarning(ex, "Outbox message {MessageId} not confirmed; backing off", row.Id);
                break;
            }

            await conn.ExecuteAsync(new CommandDefinition(
                "UPDATE outbox_messages SET sent_at = now() WHERE id = @id",
                new { id = row.Id }, tx, cancellationToken: ct));
            handled++;
        }

        await tx.CommitAsync(ct);
        return handled == rows.Count ? rows.Count : 0;   // a backoff ends the drain loop
    }

    private static async Task PublishAsync(IChannel channel, OutboxRow row, CancellationToken ct)
    {
        var props = new BasicProperties
        {
            MessageId = row.Id.ToString(),                    // consumers dedupe on this
            Type = row.Type,
            ContentType = "application/json",
            DeliveryMode = DeliveryModes.Persistent,
            CorrelationId = row.CorrelationId,
        };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));    // the confirm await has no timeout of its own
        await channel.BasicPublishAsync(Exchange, row.Type, mandatory: true, props,
            Encoding.UTF8.GetBytes(row.Payload), timeout.Token);   // awaits the broker confirm (tracking on)
    }

    private sealed record OutboxRow(Guid Id, string Type, string Payload, string? CorrelationId);
}
```

Wiring: `builder.Services.AddHostedService<OutboxDispatcher>();` + `builder.Services.AddResiliencePipeline("rabbit-connect", p => p.AddRetry(new() { MaxRetryAttempts = 10, BackoffType = DelayBackoffType.Exponential, UseJitter = true, ShouldHandle = new PredicateBuilder().Handle<BrokerUnreachableException>() }));`. `DefaultTypeMap.MatchNamesWithUnderscores = true` maps `correlation_id` (`data-access`).

- Confirms are serialized per row (each await waits for the broker's fsync-batched ack — hundreds of ms under load). If throughput demands more, run more dispatcher replicas (SKIP LOCKED spreads the rows) before getting clever with in-flight batching.
- **Postgres timeouts vs. the open claim:** the claim transaction is *idle in transaction* during every confirm wait (≤ 10 s each) and can stay open for `BatchSize` × 10 s in total. The dispatcher therefore raises `idle_in_transaction_session_timeout` with `SET LOCAL` for its own transaction (keep it above the confirm timeout; `0` disables it), and the dispatcher role must not have a `transaction_timeout` (PG 17+) below `BatchSize` × 10 s — or lower `BatchSize`. Otherwise the server terminates the session mid-batch and every row of the claim is republished.
- Sent rows: a daily cleanup deletes `sent_at < now() - interval '7 days'`; alert on the age of the oldest unsent row and on `attempts` above a threshold (`aspnet-backend` → observability).
- **SQL Server claim** — same loop, inside a transaction:
  `SELECT TOP (@batch) Id, Type, Payload, CorrelationId FROM dbo.OutboxMessages WITH (UPDLOCK, READPAST, ROWLOCK) WHERE SentAt IS NULL AND NextAttemptAt <= SYSUTCDATETIME() ORDER BY Seq;`
  backoff: `NextAttemptAt = DATEADD(second, IIF(Attempts >= 8, 300, POWER(2, Attempts + 1)), SYSUTCDATETIME())`.

## Inbox — dedupe inside the handler's transaction

```sql
-- PostgreSQL
CREATE TABLE inbox_messages (
    message_id   text        NOT NULL,
    consumer     text        NOT NULL,              -- several handlers in one service may see the same message
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (message_id, consumer)
);
```

```sql
-- SQL Server
CREATE TABLE dbo.InboxMessages (
    MessageId   varchar(64)  NOT NULL,
    Consumer    varchar(100) NOT NULL,
    ProcessedAt datetime2    NOT NULL CONSTRAINT DF_Inbox_ProcessedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_InboxMessages PRIMARY KEY (MessageId, Consumer)
);
```

```csharp
public sealed class OrderCreatedHandler(IDbContextFactory<AppDbContext> dbFactory)
{
    private const string Consumer = "billing.order-created";

    // Returns normally for both "processed now" and "already processed" — the caller acks either way.
    public async Task HandleOnceAsync(string messageId, OrderCreated evt, CancellationToken ct)
    {
        await using var db = await dbFactory.CreateDbContextAsync(ct);
        // multi-tenant app only: db.TenantId = evt.TenantId; — from the event envelope (no request here)
        var strategy = db.Database.CreateExecutionStrategy();          // EnableRetryOnFailure owns the tx
        await strategy.ExecuteAsync((Db: db, MessageId: messageId, Evt: evt), static async (s, token) =>
        {
            s.Db.ChangeTracker.Clear();                                // a replay starts from a clean context
            await using var tx = await s.Db.Database.BeginTransactionAsync(token);

            // The INSERT is the check: a concurrent duplicate blocks on the key until the first
            // transaction ends, then inserts nothing. Never SELECT-then-INSERT.
            var inserted = await s.Db.Database.ExecuteSqlAsync($"""
                INSERT INTO inbox_messages (message_id, consumer) VALUES ({s.MessageId}, {Consumer})
                ON CONFLICT (message_id, consumer) DO NOTHING
                """, token);
            if (inserted == 0)
                return;                                                // duplicate: rollback on dispose, ack

            s.Db.Invoices.Add(Invoice.For(s.Evt));                     // the actual work, same transaction
            await s.Db.SaveChangesAsync(token);
            await tx.CommitAsync(token);
        }, ct);
    }
}
```

- SQL Server has no `ON CONFLICT`: run a plain `INSERT` and treat `SqlException` numbers **2627/2601** (unique violation) as "already processed" — catch it inside the delegate and return without committing. Map `MessageId` as non-Unicode (`IsUnicode(false)`) so the parameter matches the `varchar` key (`mssql`).
- **Multi-tenant apps:** a factory-created context has no request, so under `bff-security`'s tenant model (`references/authorization.md`) its `TenantId` is `Guid.Empty` — the work sees no rows and tenant-owned inserts throw. Carry the tenant id in the event and set `db.TenantId` right after `CreateDbContextAsync`, before any query or `SaveChangesAsync`.
- Retention: keep inbox rows longer than any realistic redelivery horizon (retry tiers + DLQ replays), e.g. 14–30 days, then delete in batches.
- Handlers that are naturally idempotent (pure upserts keyed by the event's own ids) may skip the inbox — say so in a comment.

## Sources

- https://rabbitmq.github.io/rabbitmq-dotnet-client/api/RabbitMQ.Client.ConnectionFactory.html · …/RabbitMQ.Client.IChannel.html · …/RabbitMQ.Client.CreateChannelOptions.html
- https://www.rabbitmq.com/docs/confirms · https://www.rabbitmq.com/docs/reliability
- https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE (SKIP LOCKED)
- https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT
- https://learn.microsoft.com/en-us/sql/t-sql/queries/hints-transact-sql-table (UPDLOCK, READPAST)
- https://learn.microsoft.com/en-us/ef/core/miscellaneous/connection-resiliency
- https://learn.microsoft.com/en-us/ef/core/querying/sql-queries#executing-non-querying-sql
