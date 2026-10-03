# Observability — OpenTelemetry + Serilog, health checks, alerting

Verified against official documentation, October 2026 (learn.microsoft.com: observability-with-otel, built-in metrics, health checks; serilog-sinks-opentelemetry README; npgsql.org diagnostics). Extends `SKILL.md` → Performance checklist → Observability; versions live in [best-practices.md](best-practices.md#current-versions-verified-october-2026).

## The three signals, one pipeline

| Signal | API your code uses | Exported by |
|---|---|---|
| Traces | `ActivitySource` (own spans) + library instrumentation | OpenTelemetry SDK → OTLP |
| Metrics | `System.Diagnostics.Metrics.Meter` (via `IMeterFactory`) + built-in meters | OpenTelemetry SDK → OTLP |
| Logs | `ILogger<T>` + `[LoggerMessage]` source-gen | Serilog → `Serilog.Sinks.OpenTelemetry` → OTLP (and JSON console) |

Application code never references OpenTelemetry or Serilog types — only the .NET abstractions above.

```csharp
const string ServiceName = "orders-api";

builder.Services.AddSerilog((services, lc) => lc
    .ReadFrom.Configuration(builder.Configuration)
    .ReadFrom.Services(services)
    .Enrich.FromLogContext()
    .WriteTo.Console(new RenderedCompactJsonFormatter())
    .WriteTo.OpenTelemetry(o =>
    {
        // the sink honors only some OTEL_EXPORTER_OTLP_* env vars (they override code) —
        // set service.name here so logs join the traces/metrics of the same service
        o.ResourceAttributes = new Dictionary<string, object> { ["service.name"] = ServiceName };
    }));

builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(ServiceName))
    .WithTracing(t => t
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddNpgsql()                       // Npgsql.OpenTelemetry (Postgres)
        .AddFusionCacheInstrumentation()   // ZiggyCreatures.FusionCache.OpenTelemetry
        .AddSource(Telemetry.SourceName)   // your own ActivitySource
        .AddOtlpExporter())
    .WithMetrics(m => m
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddMeter("System.Runtime")        // .NET 9+ runtime metrics, no extra package
        .AddFusionCacheInstrumentation()
        .AddMeter(Telemetry.MeterName)
        .AddOtlpExporter());
```

Two-stage Serilog init (bootstrap logger, `Log.CloseAndFlushAsync()` in `finally`) and the "no `builder.Logging.AddOpenTelemetry()` next to Serilog" rule: [best-practices.md → OpenTelemetry](best-practices.md#opentelemetry-officially-recommended-setup). RabbitMQ spans: `rabbitmq-messaging` → Operations.

## Correlation

- **Trace context is the correlation id.** ASP.NET Core starts an `Activity` per request (W3C `traceparent` in, out on `HttpClient` calls); Serilog (3.1+) captures `Activity.Current`'s trace and span ids on every event, and the OTLP sink exports them — logs and spans join in the backend without a hand-rolled `X-Correlation-Id` middleware.
- **Across RabbitMQ** the 7.x client propagates `traceparent` in message headers; also copy the business `CorrelationId` into the event envelope (`rabbitmq-messaging` → contract rules).
- **Background work**: a `BackgroundService` iteration has no ambient request activity — start one per unit of work (`using var activity = Telemetry.Source.StartActivity("outbox.dispatch");`) so its logs correlate.
- **Business context** goes in as structured properties (`{OrderId}`) or a scoped `ILogger.BeginScope` — never as string-interpolated text, never PII ([configuration-secrets.md](configuration-secrets.md#never-log-secrets-or-pii)).

```csharp
public static class Telemetry
{
    public const string SourceName = "Orders.Api";
    public const string MeterName = "Orders.Api";
    public static readonly ActivitySource Source = new(SourceName);
}

// custom metric: create via IMeterFactory (DI-scoped meters, testable), not a static `new Meter`
public sealed class OrderMetrics
{
    private readonly Counter<long> _placed;
    public OrderMetrics(IMeterFactory meters) =>
        _placed = meters.Create(Telemetry.MeterName).CreateCounter<long>("orders.placed", "{order}");
    public void Placed(string channel) => _placed.Add(1, new KeyValuePair<string, object?>("channel", channel));
}
```

Keep tag values low-cardinality (a channel, a status) — never ids or user input.

## Health checks — liveness vs readiness

- `/health/live`: process up, **no dependency checks** (drives restarts in orchestrators that restart on a failed probe, e.g. a Kubernetes liveness probe — a DB outage must not restart every replica; plain Docker/compose never restarts on health). `/health/ready`: dependency checks tagged `"ready"` (DB via the app's `NpgsqlDataSource`, Redis, RabbitMQ) — gates traffic. Wiring in SKILL.md.
- Both endpoints `.AllowAnonymous()` (the BFF's fallback policy otherwise demands a login), excluded from the rate limiter (`bff-security`) and from request logging noise (`UseSerilogRequestLogging` options can lower their level).
- Give dependency checks a `timeout:` so one hung dependency can't stall the probe; compose/orchestrator healthchecks hit `/health/ready` (see `docker`).
- Never return exception details or connection strings in the health response body — the default writer emits only the aggregate status.

## What to alert on

Alert on symptoms users feel, dashboard the causes:

| Alert | Signal |
|---|---|
| Error rate | `http.server.request.duration` count with `http.response.status_code` 5xx ÷ total, per route, over 5 min |
| Latency | p95/p99 of `http.server.request.duration` per route against the SLO |
| Readiness | `/health/ready` failing on any replica for > N probes |
| Saturation | `dotnet.thread_pool.queue.length` sustained > 0 (sync-over-async / starvation), DB pool exhaustion errors, container memory near limit |
| Async backlogs | RabbitMQ queue depth / consumer count, **any** message in a DLQ, outbox rows older than X minutes (`rabbitmq-messaging`) |
| Background jobs | "last successful run" age per scheduled job (emit a gauge or log event each success) |
| Security | spikes of 401/403/429 on `/api/auth/*`, antiforgery 400s after a deploy |

Dashboards (not alerts): GC pause time (`dotnet.gc.pause.time`), cache hit ratio (FusionCache metrics), outbound HTTP latency/error per client, EF/Npgsql span durations.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Serilog sink without `service.name` | Logs land under `unknown_service` and don't join traces — set `ResourceAttributes` |
| Custom correlation-id middleware + header | W3C trace context already does it end to end |
| High-cardinality metric tags (user id, order id, raw path) | Bounded tag values; ids belong in traces/logs |
| Dependency checks in `/health/live` | Restart storms during a DB outage — dependencies go in `/health/ready` only |
| Alerting on every exception log line | Alert on rates/SLOs; logs are for diagnosis |

## Sources

- https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel
- https://learn.microsoft.com/en-us/dotnet/core/diagnostics/built-in-metrics-runtime
- https://learn.microsoft.com/en-us/aspnet/core/metrics/overview?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/dotnet/core/diagnostics/metrics-instrumentation (IMeterFactory)
- https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/health-checks?view=aspnetcore-10.0
- https://github.com/serilog/serilog-sinks-opentelemetry (ResourceAttributes, environment variables)
- https://www.npgsql.org/doc/diagnostics/tracing.html
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/OpenTelemetry.md
