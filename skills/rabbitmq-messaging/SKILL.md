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
- Every queue gets a DLX: `{queue}.dlq` via `x-dead-letter-exchange`. Retry with a delayed redelivery queue (TTL + DLX back to the work queue), max ~3 attempts, then park in DLQ for inspection.
- Consumers declare their own topology idempotently on startup.

## Publisher

```csharp
// connection: long-lived singleton owned by a hosted service (disposed on shutdown) — never per publish
var factory = new ConnectionFactory { Uri = new Uri(options.ConnectionString) };
var connection = await factory.CreateConnectionAsync(ct);
var channel = await connection.CreateChannelAsync(          // one per producer loop, dispose with it
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
- Publisher confirms on; treat a nack/timeout as "not sent".

### Outbox pattern (required when publishing belongs to a DB transaction)

Never `SaveChangesAsync()` + `BasicPublishAsync()` as two independent steps — a crash between them loses or fabricates events. Write the event to an `outbox_messages` table in the same transaction, and let a `BackgroundService` poll/publish and mark rows sent (with confirms). Delete or archive sent rows.

## Consumer

```csharp
await channel.BasicQosAsync(0, prefetchCount: 16, global: false, ct);
var consumer = new AsyncEventingBasicConsumer(channel);
consumer.ReceivedAsync += async (_, ea) =>
{
    try
    {
        if (await inbox.AlreadyProcessedAsync(ea.BasicProperties.MessageId, ct))
        {
            await channel.BasicAckAsync(ea.DeliveryTag, false, ct);
            return;
        }
        await handler.HandleAsync(Deserialize(ea.Body.Span), ct);   // + record MessageId in same tx
        await channel.BasicAckAsync(ea.DeliveryTag, false, ct);
    }
    catch (Exception)
    {
        // transient AND poison failures both go through the DLX topology (retry queue → DLQ
        // after max attempts) — never requeue: true, it creates hot redelivery loops
        await channel.BasicNackAsync(ea.DeliveryTag, false, requeue: false, ct);
    }
};
await channel.BasicConsumeAsync(queue, autoAck: false, consumer, ct);
```

- Manual ack only after successful handling. `autoAck: true` is a review failure.
- **Idempotency is mandatory** — at-least-once delivery means duplicates happen. Dedupe on `MessageId` (inbox table) or make the handler naturally idempotent (upserts).
- `requeue: true` on failure creates hot loops — route to the retry/DLX topology instead.
- Run consumers as `BackgroundService`; honor `CancellationToken` for clean shutdown (stop consuming, finish in-flight, ack, close).

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
| Classic mirrored queues | Quorum queues |
| New connection per publish | Singleton connection, channel per loop |
| Fat events carrying whole entities | Carry ids + the facts that changed; consumers fetch what they need |
| Rabbit for sync request/response | HTTP with resilience handler |
