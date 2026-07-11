# RabbitMQ Messaging — Best Practices Reference (.NET)

Verified against official documentation, July 2026. Extends `SKILL.md` (topology conventions, outbox, idempotency rules live there). Sources: rabbitmq.com docs (reliability, confirms, quorum-queues, dlx, ttl, production-checklist, heartbeats, release-information), the .NET client API guide and API reference, and nuget.org. Full URL list at the bottom.

## Current versions (July 2026)

- **RabbitMQ server: 4.3.x** — latest patch **4.3.2** (2026-06-15). 4.2.x community support ends 2026-07-31; 4.1.x already ended (2026-01-31); 3.13.x is out of community support. Target 4.3.x (or 4.2.x with a commercial license) for new deployments.
- **RabbitMQ.Client NuGet: 7.2.1** (2026-02-25). Ships `net8.0` + `netstandard2.0` targets; runs fine on `net10.0`. Fully async API (`IConnection`/`IChannel`), `CancellationToken` on every operation.

## Established patterns

### Publisher confirms — what a `basic.ack` actually means

Per the confirms guide, the broker acks a message only when **all** queues it was routed to have accepted it:

- Durable queue + persistent message: acked **after persisting to disk** — "latency for `basic.ack` can reach a few hundred milliseconds" because the broker batches fsyncs. Confirms are for correctness, not latency; pipeline or batch publishes for throughput.
- Quorum queue: acked once **a quorum of replicas** has accepted the message.
- Unroutable + `mandatory: true`: the broker sends `basic.return` **before** the confirm — a confirm alone does not prove the message reached a queue. Always publish with `mandatory: true` for messages that must land somewhere.
- `basic.nack` means the broker could not take responsibility (e.g. queue leader lost) — treat as "not sent" and republish.

In RabbitMQ.Client 7.x confirms are configured per channel via `CreateChannelOptions`:

```csharp
var channelOptions = new CreateChannelOptions(
    publisherConfirmationsEnabled: true,        // default: false
    publisherConfirmationTrackingEnabled: true, // default: false — library tracks seq numbers for you
    outstandingPublisherConfirmationsRateLimiter:
        new ThrottlingRateLimiter(128));        // default limiter: limit 128, throttling at 50%
await using IChannel channel = await connection.CreateChannelAsync(channelOptions, ct);
```

With both flags on, **awaiting `BasicPublishAsync` waits for the broker's confirm**; a `basic.nack` or `basic.return` surfaces as `PublishException`. The await has no built-in timeout — thread a `CancellationToken` through as the timeout:

```csharp
using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
timeoutCts.CancelAfter(TimeSpan.FromSeconds(10));
try
{
    await channel.BasicPublishAsync(exchange, routingKey, mandatory: true, props,
        JsonSerializer.SerializeToUtf8Bytes(evt, JsonCtx.Default.OrderCreated), timeoutCts.Token);
}
catch (PublishException ex) // nacked or returned (ex.IsReturn) — message is NOT safely stored
{
    // leave the outbox row unsent / retry with backoff; do not mark as published
}
```

The reliability guide's contract: "An acknowledgement signals both the receipt of a message, and a transfer of ownership where the receiver assumes full responsibility for it." Until the confirm arrives, the publisher still owns the message — which is exactly what the outbox row represents.

### Quorum queues — configuration and limits

- Declare with `x-queue-type: quorum` at declaration time (cannot be changed by policy afterwards). Always durable; non-durable and exclusive quorum queues do not exist.
- **Delivery limit: since RabbitMQ 4.0 the default is 20.** A message redelivered more than 20 times is **dead-lettered if the queue has a DLX, otherwise dropped**. Override with the `delivery-limit` policy key or `x-delivery-limit` argument; `-1` disables it (not recommended). Since 4.3 the limit counts `delivery-count` (actual deliveries) rather than `acquired-count`.
- Consequence: your TTL-retry topology (SKILL.md: ~3 attempts then DLQ) triggers long before the built-in limit — but the built-in limit is the safety net that stops hot loops if someone reintroduces `requeue: true`. Keep a DLX on every quorum queue so limit-exceeded messages are parked, not silently dropped.
- Global QoS (`global: true` in `BasicQosAsync`) is **not supported** on quorum queues — use per-consumer prefetch (`global: false`), as the SKILL.md consumer does.
- Replication: default group size 3; 3 nodes tolerate 1 failure, 5 tolerate 2. "We do not recommend running quorum queues on more than 7 RabbitMQ nodes."
- Sizing: ~32 bytes metadata per message in memory (≈1 MB per 30k messages); WAL defaults to 512 MiB — allocate at least 3x the WAL limit in node memory.
- Do **not** use quorum queues for: transient/temporary queues, lowest-latency paths, very long backlogs (5M+ messages), or large fan-outs — use streams for the latter two.

```csharp
var args = new Dictionary<string, object?>
{
    ["x-queue-type"] = "quorum",
    ["x-dead-letter-exchange"] = "orders.dlx",
    ["x-dead-letter-routing-key"] = "billing.order.created.dlq",
    ["x-delivery-limit"] = 20, // explicit — do not rely on defaults changing across versions
};
await channel.QueueDeclareAsync("billing.order.created", durable: true,
    exclusive: false, autoDelete: false, arguments: args, cancellationToken: ct);
```

### Prefetch tuning

From the confirms guide: prefetch 1 is "the most conservative" and "will significantly reduce throughput"; "values in the 100 through 300 range usually offer optimal throughput" for fast, uniform handlers. Rules of thumb:

- Fast idempotent handlers (ms-range): 100–300.
- Slow handlers (DB writes, external HTTP calls, seconds-range): keep it low (SKILL.md's 16 is a sane default) — prefetched-but-unprocessed messages are redelivered to other consumers only after your channel closes, and they consume broker RAM.
- Acks must go out **on the same channel** the delivery arrived on; unacked deliveries are requeued automatically when the channel/connection closes.

### Dead-lettering semantics

A message is dead-lettered when: (1) rejected/nacked with `requeue: false`, (2) its per-message TTL expires, (3) the queue length limit drops it, (4) a quorum queue's delivery limit is exceeded. Queue *expiry* does **not** dead-letter the messages in it.

- **At-most-once (default):** dead-lettering republishes internally **without** confirms — "messages are removed from the original queue immediately after publishing to the DLX target queue." If the DLX target is unavailable, the message is lost. Acceptable for diagnostics DLQs; not for money.
- **At-least-once (quorum queues only):** set policy/argument `dead-letter-strategy: at-least-once` **and** `overflow: reject-publish`; messages are re-published with confirms internally and never dropped between queues. Costs memory (the source queue retains messages until the DLX target confirms).
- Inspect `x-death` (array of `{queue, reason, count, time, exchange, routing-keys}`) plus `x-first-death-reason`/`x-first-death-queue` headers to build retry counters — count attempts from `x-death` instead of maintaining your own header.
- Cycle safety: RabbitMQ drops a message that cycles through the same queues "if there was no rejection in the entire cycle" — TTL-based retry loops (expire → back to work queue) are covered; reject-based loops are not, which is another reason for the delivery limit + attempt cap.

### Delayed messaging options

1. **TTL + DLX retry queues (recommended, pure AMQP):** publish the failed message to a retry queue with queue-level `x-message-ttl` and a DLX pointing back at the work queue. **Critical TTL caveat:** "Only when expired messages reach the head of a queue will they actually be discarded" (and quorum queues dead-letter expired messages only at the head too). Per-message `expiration` in a shared retry queue therefore breaks — a 30s-delay message stuck behind a 5m-delay message waits 5 minutes. **Use one retry queue per delay tier** (`orders.retry.30s`, `orders.retry.5m`), each with queue-level `x-message-ttl`, never per-message expiration in a shared queue.
2. **`rabbitmq_delayed_message_exchange` plugin (`x-delayed-message`):** the maintainers document "serious limitations": designed for delays of seconds-to-a-day-or-two, unsuitable for large backlogs (hundreds of thousands+ pending → long delays, possible message loss), delayed messages are invisible to metrics/management, and the implementation is Mnesia-based while Mnesia was removed from the core in the 4.3.0 cycle. Avoid for new designs; prefer option 1.

Retry-tier declaration (idempotent, on consumer startup — extends the SKILL.md topology):

```csharp
private static async Task DeclareRetryTierAsync(
    IChannel channel, string workQueue, string tier, TimeSpan delay, CancellationToken ct)
{
    // Messages nacked from the work queue land here (via the retry exchange),
    // sit for the queue-level TTL, then dead-letter back to the work queue.
    var args = new Dictionary<string, object?>
    {
        ["x-queue-type"] = "quorum",
        ["x-message-ttl"] = (int)delay.TotalMilliseconds, // queue-level, never per-message here
        ["x-dead-letter-exchange"] = "",                  // default exchange routes by queue name
        ["x-dead-letter-routing-key"] = workQueue,
    };
    await channel.QueueDeclareAsync($"{workQueue}.retry.{tier}", durable: true,
        exclusive: false, autoDelete: false, arguments: args, cancellationToken: ct);
}
```

### Connections, channels, consumers (.NET client 7.x)

- **Connections are long-lived** — "opening a new connection per operation is strongly discouraged." One singleton `IConnection` per process (per SKILL.md, owned by a hosted service), typically one for publishing and one for consuming so consumer flow-control never blocks publishes.
- **Channels are not thread-safe for publishing** — "sharing a channel (an IChannel instance) for concurrent publishing will lead to incorrect frame interleaving at the protocol level." One channel per producer/consumer loop; if you must share, serialize with a `SemaphoreSlim(1,1)`.
- **Consumer dispatch concurrency:** callbacks run sequentially by default (`ConsumerDispatchConcurrency` defaults to 1). Raise it on `ConnectionFactory` or per channel via `CreateChannelOptions.ConsumerDispatchConcurrency` (null = inherit factory) to process deliveries in parallel — but then per-channel ordering is gone and your handler + inbox dedup must tolerate concurrent duplicates. Ack single deliveries only (`multiple: false`) when concurrency > 1.
- **Copy the body before returning:** "Consumer interface implementations must deserialize or copy delivery payload before delivery handler method returns" — `ea.Body` memory is reused. Deserializing inside the handler (as SKILL.md does) satisfies this.
- **Automatic recovery is on by default:** `AutomaticRecoveryEnabled = true`, `TopologyRecoveryEnabled = true`, `NetworkRecoveryInterval` = 5s. It does **not** cover the initial connect (retry that yourself in the hosted service) and "closed channels won't be recovered" — only channels that died with the connection. Messages published while the connection is down are lost unless confirms told you otherwise.
- **Heartbeats:** client default `RequestedHeartbeat` = 60s; negotiated with the server (smaller non-zero value wins). Values under 5s "are fairly likely to cause false positives"; don't disable them.

### Production checklist highlights

- **Memory high watermark:** default `vm_memory_high_watermark.relative = 0.6`; keep within 0.4–0.7 and leave ≥30% of RAM to the OS/page cache. When the alarm fires, **publishers are blocked** — a confirm-awaiting publisher hangs until the alarm clears (that `CancellationToken` timeout matters).
- **Disk free limit:** default 50 MB is "designed for development only" — set `disk_free_limit.absolute` to roughly the memory watermark (e.g. a few GB), so paging under memory pressure cannot fill the disk.
- **File descriptors:** allow at least 50k for the RabbitMQ user (95th-percentile connections x 2 + total queues).
- **TLS everywhere possible**, at minimum for traffic encryption; enable peer verification where you control certs. Delete the default `guest` user; one broker user per application; disable anonymous logins.
- **Clusters:** odd node counts (3, 5, 7); 3 nodes is the production minimum for quorum queues to mean anything.
- Monitor queue depth, unacked counts, confirm latency, alarms, and file-descriptor usage from day one.

## Anti-patterns

| Anti-pattern | Why it fails (per official docs) | Fix |
|---|---|---|
| Confirms enabled, tracking off, no manual sequence handling | Nacks/returns arrive on callbacks nobody wired up; publishes "succeed" silently | `publisherConfirmationTrackingEnabled: true` + catch `PublishException` |
| Awaiting a confirmed publish without a token timeout | Confirm waits indefinitely (e.g. during a memory alarm that blocks publishers) | Linked `CancellationTokenSource` with `CancelAfter` |
| Treating a confirm as "routed" without `mandatory: true` | Unroutable messages are confirmed after the broker discards them | `mandatory: true`; handle `basic.return` (`PublishException.IsReturn`) |
| Per-message `expiration` in one shared retry queue | Expiry only applies at the queue head — short delays wait behind long ones | One retry queue per delay tier with queue-level `x-message-ttl` |
| Relying on the delayed-message plugin for large/long schedules | Documented limits: small backlogs only, no visibility, Mnesia-based legacy design | TTL + DLX tiers; streams or a DB-backed scheduler for long horizons |
| `x-delivery-limit: -1` (disabling the 4.x default of 20) | Removes the poison-message safety net; hot redelivery loops return | Keep the limit + DLX so exhausted messages park in the DLQ |
| Money-path DLQ with default dead-lettering | At-most-once DLX republishes without confirms — messages can vanish | Quorum queue with `dead-letter-strategy: at-least-once` + `overflow: reject-publish` |
| `BasicQosAsync(..., global: true)` on quorum queues | Global QoS is unsupported on quorum queues | Per-consumer prefetch (`global: false`) |
| `ConsumerDispatchConcurrency > 1` assuming ordered handling | Ordering is only guaranteed at concurrency 1 per channel | Keep 1 where order matters; otherwise design handlers for reorder + duplicates |
| Holding `ea.Body` past the handler (e.g. queueing it for later) | Payload memory is reused after the callback returns | Deserialize or copy (`ea.Body.ToArray()`) inside the handler |
| Trusting auto-recovery for startup and closed channels | Recovery skips initial connects and individually-closed channels | Retry initial connect in the hosted service; recreate channels on channel shutdown |
| Default 50 MB disk limit / `guest` user in production | Checklist calls both out explicitly | `disk_free_limit` ≈ memory watermark; per-app users, delete `guest` |

## Sources

- https://www.rabbitmq.com/release-information
- https://www.nuget.org/packages/RabbitMQ.Client
- https://www.rabbitmq.com/docs/reliability
- https://www.rabbitmq.com/docs/confirms
- https://www.rabbitmq.com/docs/quorum-queues
- https://www.rabbitmq.com/docs/dlx
- https://www.rabbitmq.com/docs/ttl
- https://www.rabbitmq.com/docs/production-checklist
- https://www.rabbitmq.com/docs/heartbeats
- https://www.rabbitmq.com/client-libraries/dotnet-api-guide
- https://rabbitmq.github.io/rabbitmq-dotnet-client/api/RabbitMQ.Client.CreateChannelOptions.html
- https://rabbitmq.github.io/rabbitmq-dotnet-client/api/RabbitMQ.Client.ConnectionFactory.html
- https://github.com/rabbitmq/rabbitmq-delayed-message-exchange
