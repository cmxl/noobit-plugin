---
name: rabbitmq-messaging
description: Use when services communicate asynchronously — RabbitMQ, message queues, publish/subscribe, events between microservices, outbox pattern, consumers/producers, dead-letter queues, or "how should service A tell service B".
---

# RabbitMQ Messaging

## Overview

RabbitMQ is the standard for async service-to-service communication. Use `RabbitMQ.Client` 7.x (fully async API — `IConnection`/`IChannel`, `await` everywhere). Reliability is not optional: durable quorum queues, publisher confirms, manual acks, idempotent consumers, and the outbox pattern for DB+publish atomicity.

Synchronous request/response between services should be HTTP (via `IHttpClientFactory` + resilience), not RPC-over-Rabbit. Rabbit is for events and commands that can be async.

## Topology conventions

- Exchanges: `{service}.events` (topic) for domain events; `{service}.commands` (direct) for commands.
- Routing keys: `{entity}.{action}` — e.g. `order.created`.
- Queues: `{consumerservice}.{entity}.{action}` — one queue per consumer service per interest.
- Everything durable; queues declared as **quorum** (`x-queue-type: quorum`).
- Retry + DLQ, one design per consuming service — `{service}` below is the **consumer** service (declaration code: [references/best-practices.md](references/best-practices.md#retry--dlq-topology)):
  - Work queue `x-dead-letter-exchange` = `{service}.retry` (direct), routing key `{queue}.retry.{tier}` → a nack (`requeue: false`) moves the message to `{queue}.retry.{tier}` (queue-level `x-message-ttl`), which dead-letters back to `{queue}` via the default exchange.
  - The consumer counts failed attempts from the `x-death` header; at `MaxAttempts` (~3) it publishes the message (confirmed) to `{service}.dlx` → `{queue}.dlq` and acks. Nothing else routes to the DLQ.
- Consumers declare their own topology idempotently on startup.

## Publisher

```csharp
// connection: long-lived singleton owned by a hosted service (disposed on shutdown) — never per publish
var factory = new ConnectionFactory { Uri = new Uri(options.ConnectionString) };
var connection = await factory.CreateConnectionAsync(ct);
await using var channel = await connection.CreateChannelAsync( // one per producer loop, disposed with it
    new CreateChannelOptions(publisherConfirmationsEnabled: true,
                             publisherConfirmationTrackingEnabled: true), ct);

var props = new BasicProperties
{
    MessageId = message.Id.ToString(),      // consumers dedupe on this
    Type = "order.created",
    ContentType = "application/json",
    DeliveryMode = DeliveryModes.Persistent,
    CorrelationId = correlationId,
};
await channel.BasicPublishAsync("orders.events", "order.created",
    mandatory: true, props, JsonSerializer.SerializeToUtf8Bytes(evt, JsonCtx.Default.OrderCreated), ct);
```

- Connection is a long-lived singleton (hosted service owns it); channels are cheap but not thread-safe — one per producer/consumer loop.
- Publisher confirms on. A nack/return means "not stored" — republish. A timeout/cancelled confirm wait means "unknown" (the broker may have stored it) — republish too; the duplicate is harmless because consumers dedupe on `MessageId`.

### Outbox pattern (required when publishing belongs to a DB transaction)

Never `SaveChangesAsync()` + `BasicPublishAsync()` as two independent steps — a crash between them loses or fabricates events. Write the event to an `outbox_messages` table in the same transaction, and let a `BackgroundService` poll/publish and mark rows sent (with confirms). Delete or archive sent rows. Multiple publisher instances must claim rows (`FOR UPDATE SKIP LOCKED` / `UPDLOCK, READPAST`) and mark them sent only after the confirm, inside the claiming transaction — see `postgres` ("Queue/outbox polling") / `mssql`. Ordering then holds per claimed batch; strict global order needs a single dispatcher (or one per partition key).

## Consumer

```csharp
// channel: this consumer loop's channel; confirmChannel: a separate channel with publisher confirms (for the DLQ)
await channel.BasicQosAsync(0, prefetchCount: 16, global: false, ct);
var consumer = new AsyncEventingBasicConsumer(channel);
consumer.ReceivedAsync += async (_, ea) =>
{
    try
    {
        if (!await inbox.AlreadyProcessedAsync(ea.BasicProperties.MessageId, ct))
            await handler.HandleAsync(Deserialize(ea.Body.Span), ct);   // + record MessageId in same tx
        await channel.BasicAckAsync(ea.DeliveryTag, multiple: false);   // no ct: once handled, always ack
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested)
    {
        // shutdown: leave it unacked — the broker requeues it when the channel closes
    }
    catch (Exception ex)
    {
        try
        {
            // transient AND poison failures: retry tier until MaxAttempts, then park in the DLQ.
            // Never requeue: true — nack returns don't count toward the quorum delivery limit (4.3+): infinite hot loop.
            if (RetryTopology.FailedAttempts(ea.BasicProperties, queue) + 1 >= MaxAttempts
                && await RetryTopology.TryParkAsync(confirmChannel, service, queue, ea, ex, ct))
                await channel.BasicAckAsync(ea.DeliveryTag, multiple: false);
            else
                await channel.BasicNackAsync(ea.DeliveryTag, multiple: false, requeue: false);
        }
        catch (AlreadyClosedException)
        {
            // channel is gone: the unacked delivery is redelivered after recovery
        }
    }
};
await channel.BasicConsumeAsync(queue, autoAck: false, consumer, ct);
```

`RetryTopology.FailedAttempts` / `TryParkAsync` (x-death parsing, confirmed DLQ publish): [references/best-practices.md](references/best-practices.md#retry--dlq-topology).

- Manual ack only after successful handling. `autoAck: true` is a review failure.
- **Idempotency is mandatory** — at-least-once delivery means duplicates happen. Dedupe on `MessageId` (inbox table) or make the handler naturally idempotent (upserts).
- `requeue: true` on failure creates hot loops — route to the retry/DLX topology instead.
- Run consumers as `BackgroundService`; honor `CancellationToken` for clean shutdown (stop consuming, finish or abandon in-flight — abandoned deliveries stay unacked and are requeued on channel close — then close). Shutdown cancellation must never reach the retry/DLQ path.

## Message contract rules

- Events are versioned, additive-only JSON (`order.created` v1 fields never change meaning; breaking change = new type `order.created.v2`).
- Share contracts via a small `*.Contracts` package or duplicated DTOs — never share domain entities across services.
- Include `OccurredAtUtc` and `CorrelationId` in every event envelope; propagate correlation into logs/traces.

## Common mistakes

| Mistake | Fix |
|---|---|
| Publish after commit as separate step | Outbox pattern |
| No dedup in consumers | Inbox table keyed by MessageId |
| `requeue: true` on exceptions | TTL retry queue + DLQ |
| Classic queues for durable work (mirroring was removed in 4.0) | Quorum queues |
| New connection per publish | Singleton connection, channel per loop |
| Fat events carrying whole entities | Carry ids + the facts that changed; consumers fetch what they need |
| Rabbit for sync request/response | HTTP with resilience handler |
| Hand-rolled retry loop for the initial connect | Polly v8 `ResiliencePipeline` (`noobit:aspnet-backend`) — auto-recovery doesn't cover the first connect |

## Operations & choices (pointers)

- **Tracing:** the 7.x client emits `ActivitySource`s (`RabbitMQ.Client.Publisher`/`.Subscriber`) and propagates W3C `traceparent` via message headers; register them with OpenTelemetry (`RabbitMQ.Client.OpenTelemetry` → `AddRabbitMQInstrumentation()`, still pre-release).
- **Health/tests:** `AspNetCore.HealthChecks.Rabbitmq` for readiness (never liveness); `Testcontainers.RabbitMq` for integration tests — see `noobit:dotnet-testing`.
- **Ordering:** only per queue with one consumer at dispatch concurrency 1 — use `x-single-active-consumer` when order matters; streams for replay/large fan-out.
- **Library:** raw `RabbitMQ.Client` is the default (topology above is small). MassTransit v9+ is commercially licensed (v8 stays open source); Wolverine (MIT) is the open-source alternative. Adopt either only when sagas/scheduling justify the dependency.

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- RabbitMQ: https://www.rabbitmq.com/docs
- .NET client guide (v7): https://www.rabbitmq.com/client-libraries/dotnet-api-guide
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
