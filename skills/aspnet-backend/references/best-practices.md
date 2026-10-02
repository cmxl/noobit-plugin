# ASP.NET Core / .NET 10 Backend Best Practices

Verified against official documentation, October 2026. Primary sources:
https://learn.microsoft.com/en-us/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0 ·
https://learn.microsoft.com/en-us/aspnet/core/release-notes/aspnetcore-10.0 ·
https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/?view=aspnetcore-10.0 ·
https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience ·
https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel

## Current versions (verified October 2026)

Patch numbers rotate monthly — check nuget.org / the .NET release notes for the current ones; the values below are the state at verification.

- **.NET 10** — LTS, supported 2025-11-11 → 2028-11-14. Runtime patch **10.0.12** (2026-09-08); SDKs **10.0.401** (4xx band) and 10.0.112 (1xx band). A `global.json` pin of `10.0.100` + `"rollForward": "latestFeature"` resolves to the newest installed feature band — still valid.
- **C# 14** ships with .NET 10: `field`-backed properties, `extension` blocks, null-conditional assignment (`?.=`), first-class `Span<T>` conversions, unbound-generic `nameof`.
- **Microsoft.Extensions.Http.Resilience 10.x** (10.10.0 at verification) — versions track .NET 10.x minor releases; check nuget.org.
- **OpenTelemetry 1.19.x** (Extensions.Hosting / Exporter.OpenTelemetryProtocol 1.19.1, Instrumentation.AspNetCore / .Http 1.19.0 at verification) — keep all `OpenTelemetry.*` packages on the same minor; check nuget.org.
- ASP.NET Core 10 depends on **Microsoft.OpenApi 2.x** (OpenAPI **3.1** is the default document version) and moves minimal-API validation into the **Microsoft.Extensions.Validation** package.

## Established patterns

### Request pipeline — documented middleware order

The order in `Program.cs` is the invocation order (reverse for responses) and is *critical for security, performance, and functionality*:

```csharp
var app = builder.Build();

app.UseForwardedHeaders();       // 0. behind nginx: first, so scheme/IP are right for everything below
                                 //    (KnownIPNetworks/KnownProxies config: see nginx-deploy)
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler();   // 1. catches everything downstream
    app.UseHsts();               //    non-dev + HTTPS only
}
app.UseStatusCodePages();        //    bodiless 4xx/5xx (404, 405, …) → ProblemDetails (with AddProblemDetails)
app.UseHttpsRedirection();       // 2.
app.MapStaticAssets();           // 3. short-circuits static requests
app.UseRouting();                // 4. (implicit at pipeline start if omitted)
app.UseCors();                   // 5. CORS → AuthN → AuthZ order is mandatory
app.UseAuthentication();         // 6.
app.UseRateLimiter();            //    after AuthN so identity partitions see the user (bff-security);
                                 //    a purely IP-based global limiter could sit earlier
app.UseAuthorization();          // 7.
app.UseRequestTimeouts();        //    after UseRouting
app.UseOutputCache();            //    after CORS + AuthN/AuthZ, or cached content can leak to unauthorized users
app.MapOpenApi();                // 8. endpoints last (gate behind IsDevelopment() if the API isn't public)
app.MapOrderEndpoints();
```

Documented constraints: `UseCors` must precede `UseResponseCaching`; `UseOutputCache` must follow `UseCors`, `UseAuthentication` and `UseAuthorization`; `UseRequestLocalization` must precede anything reading culture (e.g. static files); global-only rate limiters may sit before `UseRouting`. Caching/compression mutual order is scenario-specific.

### Minimal APIs at scale — route groups + TypedResults

Official organization pattern: endpoints out of `Program.cs`, one static mapping extension per feature, group-level metadata applied once via `MapGroup` (nested groups compose; group filters run outer → inner):

```csharp
namespace App.Api.Features.Orders;

public static class OrderEndpoints
{
    public static IEndpointRouteBuilder MapOrderEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/orders")
            .RequireAuthorization()
            .WithTags("Orders");

        group.MapGet("/{id:guid}", GetById);
        group.MapPost("/", Create);
        return app;
    }

    private static async Task<Results<Ok<OrderResponse>, NotFound>> GetById(
        Guid id, IOrderService service, CancellationToken ct) =>
        await service.GetAsync(id, ct) is { } order
            ? TypedResults.Ok(order.ToResponse())   // DTO projection — never the entity
            : TypedResults.NotFound();

    private static async Task<Created<OrderResponse>> Create(
        CreateOrderRequest request, IOrderService service, CancellationToken ct)
    {
        var order = await service.CreateAsync(request, ct);
        return TypedResults.Created($"/api/orders/{order.Id}", order.ToResponse());
    }
}
```

New in ASP.NET Core 10 (release notes):

- **Built-in validation** (the default): `builder.Services.AddValidation();` — DataAnnotations / `IValidatableObject` on query, header and body parameters (classes and records), automatic 400 `ValidationProblem` (formatted by `IProblemDetailsService`); opt out per endpoint with `.DisableValidation()`. Package: `Microsoft.Extensions.Validation`. A source generator discovers types **only in the assembly that calls `AddValidation`** — undiscovered types are silently not validated (no exception, no log).
- **Server-Sent Events**: `TypedResults.ServerSentEvents(source)` over an `IAsyncEnumerable<T>` / `SseItem<T>` stream.
- **OpenAPI**: `AddOpenApi()` emits 3.1 by default; `app.MapOpenApi("/openapi/{documentName}.yaml")` serves YAML; XML doc comments flow into the document when `<GenerateDocumentationFile>` is enabled.
- **Cookie auth for APIs**: unauthenticated API requests (minimal APIs with JSON/TypedResults) now get 401/403 instead of login redirects — no manual `OnRedirectToLogin` override needed.

### FluentValidation — only where DataAnnotations can't express the rule

For async/DB-backed or cross-field rules beyond `IValidatableObject`, add a generic endpoint filter (it runs after the built-in validation filter):

```csharp
public sealed class FluentValidationFilter<T>(IValidator<T> validator) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(
        EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        if (context.Arguments.OfType<T>().FirstOrDefault() is { } argument)
        {
            var result = await validator.ValidateAsync(argument, context.HttpContext.RequestAborted);
            if (!result.IsValid)
                return TypedResults.ValidationProblem(result.ToDictionary());
        }
        return await next(context);
    }
}

builder.Services.AddScoped<IValidator<CreateOrderRequest>, CreateOrderValidator>();
group.MapPost("/", Create).AddEndpointFilter<FluentValidationFilter<CreateOrderRequest>>();
```

### Global error handling — IExceptionHandler + ProblemDetails

```csharp
internal sealed class GlobalExceptionHandler(
    IProblemDetailsService problemDetails,
    ILogger<GlobalExceptionHandler> logger) : IExceptionHandler   // registered as singleton
{
    public async ValueTask<bool> TryHandleAsync(
        HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        logger.LogError(exception, "Unhandled exception for {Method} {Path}",
            httpContext.Request.Method, httpContext.Request.Path);

        httpContext.Response.StatusCode = StatusCodes.Status500InternalServerError;
        return await problemDetails.TryWriteAsync(new()
        {
            HttpContext = httpContext,
            ProblemDetails = { Title = "An unexpected error occurred." }   // never exception details
        });
    }
}

builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<GlobalExceptionHandler>();
// pipeline: app.UseExceptionHandler(); app.UseStatusCodePages();
```

- Registering a handler is not enough — without `app.UseExceptionHandler()` it never runs.
- A handler returning `true` must write the full response (status + body), otherwise the client gets an empty-bodied 500 (or the `StatusCodeSelector` code).
- Since .NET 10 the middleware **suppresses its own logs/metrics for handled exceptions** (`TryHandleAsync` → `true`) — log inside the handler as above, or set `ExceptionHandlerOptions.SuppressDiagnosticsCallback`.

### System.Text.Json source generation

```csharp
[JsonSerializable(typeof(OrderResponse))]
[JsonSerializable(typeof(CreateOrderRequest))]
internal sealed partial class AppJsonContext : JsonSerializerContext;

builder.Services.ConfigureHttpJsonOptions(static o =>
    o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));
```

`ConfigureHttpJsonOptions` covers minimal-API request/response bodies only. Outbound `HttpClient` and direct `JsonSerializer` calls take the type info explicitly: `await http.GetFromJsonAsync("/orders/1", AppJsonContext.Default.OrderResponse, ct)`.

### Performance (official best-practices page)

- **Async all the way**: no `Task.Wait`/`.Result`, no locks on hot paths, and no `Task.Run` in handlers — request code already runs on pool threads; sync-over-async causes thread-pool starvation. (Exception: work that must outlive the response, e.g. finishing a deferred Discord interaction — see `discord`.)
- **Kestrel does not support synchronous body reads.** Read/write bodies asynchronously; prefer `JsonSerializer.DeserializeAsync(Request.Body)` over buffering; use `Request.ReadFormAsync()` — `Request.Form` without it is sync-over-async.
- **Large object heap**: allocations ≥ 85,000 bytes go to the LOH and need Gen 2 collections. Don't buffer large request/response bodies into a single `byte[]`/`string`; pool big buffers with `ArrayPool<T>.Shared`; cache frequently used large objects. (.NET 10's `IMemoryPoolFactory<T>` lives in `Microsoft.AspNetCore.Connections` — the server/transport pool abstraction behind Kestrel's auto-evicting pools, metrics under the `Microsoft.AspNetCore.MemoryPool` meter; it isn't the tool for application buffers.)
- **Streaming over buffering**: return `IAsyncEnumerable<T>` (async enumeration by the serializer) instead of `IEnumerable<T>` (sync, blocking); paginate large collections rather than returning them whole.
- **Pooling**: never new-up/dispose `HttpClient` per call (socket exhaustion) — always `IHttpClientFactory`; consider `DbContext` pooling and compiled queries only after measuring.
- **Data access**: async APIs only; project to just the needed columns (DTOs); no-tracking queries for reads; filter/aggregate in the database; watch for client evaluation and N+1 from collection projections.
- **Exceptions are for the exceptional** — never normal control flow; on hot paths detect conditions instead of catching.
- **HttpContext discipline**: it is not thread-safe — copy what you need before `Task.WhenAll` fan-out; never store `IHttpContextAccessor.HttpContext` in a field; never touch it after the response completes (`async void` handlers crash the process); check `Response.HasStarted` (or use `OnStarting`) before touching headers/status; `Request.ContentLength` may be `null` — `null > limit` comparisons silently pass.
- **Long-running work**: move it out of the request via hosted services or a message broker; resolve scoped services inside the background scope:

```csharp
using var scope = scopeFactory.CreateAsyncScope();   // IServiceScopeFactory (singleton)
var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
```

### Outbound HTTP resilience (Microsoft.Extensions.Http.Resilience)

Add exactly **one** resilience handler per client — do not stack them:

```csharp
builder.Services.AddHttpClient<CatalogClient>(static c =>
        c.BaseAddress = new Uri("https://catalog.internal"))
    .AddStandardResilienceHandler(static o => o.Retry.DisableForUnsafeHttpMethods());
```

Standard pipeline, outermost → innermost (defaults): rate limiter (1000 concurrent) → total timeout 30 s → retry (3×, exponential + jitter, 2 s base) → circuit breaker (10 % failure ratio, 100 min throughput, 30 s sampling, 5 s break) → attempt timeout 10 s. Retries/breaker trigger on HTTP 500+, 408, 429, `HttpRequestException`, `TimeoutRejectedException`. Retries apply to **all** HTTP methods by default — disable for non-idempotent verbs as above. Set a default for every client, override per client:

```csharp
builder.Services.ConfigureHttpClientDefaults(static b => b.AddStandardResilienceHandler());
builder.Services.AddHttpClient("hedged")
    .RemoveAllResilienceHandlers()
    .AddStandardHedgingHandler();   // parallel hedging for latency-critical GETs
```

Use `AddResilienceHandler("name", ...)` with Polly strategy options only when the standard handler genuinely doesn't fit.

### Hosted services & graceful shutdown

```csharp
public sealed class QueueWorker(
    IServiceScopeFactory scopeFactory,
    ILogger<QueueWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
        do
        {
            try
            {
                await using var scope = scopeFactory.CreateAsyncScope();
                var handler = scope.ServiceProvider.GetRequiredService<IJobHandler>();
                await handler.RunAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Job run failed; retrying on the next tick");
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
```

The `PeriodicTimer` paces the loop — a bare `while (!stoppingToken.IsCancellationRequested)` spins at 100 % CPU when `RunAsync` returns immediately. The per-iteration `try/catch` keeps one failed run from killing the worker. A channel-fed worker loops with `await foreach (var item in reader.ReadAllAsync(stoppingToken))` instead, with the same per-item `try/catch`.

- The host blocks in `StopAsync` waiting for `ExecuteAsync` to finish; honor `stoppingToken` promptly or shutdown turns ungraceful at the timeout.
- Default shutdown timeout is **30 seconds**; extend via `builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(60));`.
- `StartAsync` must be short — hosted services start sequentially (opt into parallel start with `HostOptions.ServicesStartConcurrently = true`).
- An unhandled `ExecuteAsync` exception stops the host by default (`BackgroundServiceExceptionBehavior.StopHost`) — log and decide deliberately; don't let workers die silently.
- Feed workers from `System.Threading.Channels` in-process; a crash-safe broker across services.

### OpenTelemetry (officially recommended setup)

.NET's native APIs are the instrumentation surface — `ILogger<T>`, `System.Diagnostics.Metrics.Meter`, `ActivitySource` — and OTel exports them. Packages: `OpenTelemetry.Extensions.Hosting`, `OpenTelemetry.Instrumentation.AspNetCore`, `OpenTelemetry.Instrumentation.Http`, `OpenTelemetry.Exporter.OpenTelemetryProtocol`; for logs (Serilog backend) `Serilog.AspNetCore` + `Serilog.Sinks.OpenTelemetry`.

```csharp
builder.Services.AddOpenTelemetry()
    .ConfigureResource(static r => r.AddService("app-api"))
    .WithTracing(static t => t
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddOtlpExporter())
    .WithMetrics(static m => m
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddMeter("System.Runtime")      // built-in runtime metrics (.NET 9+) — no extra package
        .AddOtlpExporter());
```

Logs go through Serilog (two-stage init), which ships them over OTLP itself:

```csharp
Log.Logger = new LoggerConfiguration().WriteTo.Console().CreateBootstrapLogger();
try
{
    var builder = WebApplication.CreateBuilder(args);
    builder.Services.AddSerilog((services, lc) => lc
        .ReadFrom.Configuration(builder.Configuration)
        .ReadFrom.Services(services)
        .Enrich.FromLogContext()
        .WriteTo.Console(new RenderedCompactJsonFormatter())   // JSON console for containers
        .WriteTo.OpenTelemetry());                             // Serilog.Sinks.OpenTelemetry
    // … AddOpenTelemetry() as above, Build(), app.UseSerilogRequestLogging(), app.Run()
}
catch (Exception ex) { Log.Fatal(ex, "Host terminated unexpectedly"); }
finally { await Log.CloseAndFlushAsync(); }
```

Do **not** add `builder.Logging.AddOpenTelemetry(...)` alongside Serilog: `AddSerilog` doesn't forward events to other `ILoggerProvider`s by default (`writeToProviders: false`), so those OTLP logs silently go nowhere. Use the Serilog sink (above), or — only if the OTel logging provider is genuinely needed — `AddSerilog(..., writeToProviders: true)`.

OTLP is the vendor-neutral default; configure endpoint/resource via standard `OTEL_*` environment variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` — the Serilog sink reads these too, and they override values set in code). ASP.NET Core 10 adds built-in meters for authentication/authorization (`Microsoft.AspNetCore.Authentication`/`.Authorization`), Identity, and memory pools — they light up automatically with `AddAspNetCoreInstrumentation`. Docs note the Aspire `ServiceDefaults` project (`dotnet new aspire-servicedefaults`) as the fastest correct OTel bootstrap even without Aspire orchestration.

## Anti-patterns (documented, with fix)

| Anti-pattern | Officially documented fix |
|---|---|
| `.Result` / `.Wait()` / sync body reads | Async end-to-end; Kestrel has no sync I/O — `DeserializeAsync`, `ReadFormAsync` |
| `Task.Run` in a request handler | Just `await`; handler code already runs on pool threads (unless the work must outlive the response — `discord`) |
| `async void` endpoint/handler methods | Return `Task` — `async void` completes the response early and crashes on late writes |
| Buffering large bodies into `byte[]`/`string` | Stream; `ArrayPool<T>.Shared` for buffers ≥ 85 KB |
| Returning unbounded collections / sync `IEnumerable<T>` | Paginate; return `IAsyncEnumerable<T>` |
| `new HttpClient()` per request | `IHttpClientFactory` + one standard resilience handler |
| Stacking multiple resilience handlers on one client | One handler; `RemoveAllResilienceHandlers()` then add the intended one |
| Retrying POST/PATCH/PUT/DELETE by default | `options.Retry.DisableForUnsafeHttpMethods()` |
| Storing `IHttpContextAccessor.HttpContext` in a field | Store the accessor; read `HttpContext` at call time, null-checked |
| Capturing `HttpContext`/scoped services in background work | Copy needed values; `IServiceScopeFactory.CreateAsyncScope()` inside the task |
| Mutating headers/status after response start | Check `Response.HasStarted` or register `Response.OnStarting` |
| Exceptions as control flow | Detect and handle expected conditions; exceptions stay rare |
| Custom auth-failure redirect handling for APIs | ASP.NET Core 10 cookie auth returns 401/403 for API endpoints automatically |
| `Request.ContentLength > limit` as a size guard | It's `null` without a `Content-Length` header — handle `null` explicitly |
| Blocking in `StartAsync` / ignoring `stoppingToken` | Short `StartAsync`; loop on `stoppingToken`, exit promptly on cancellation |
| Unpaced/unguarded worker loop | `PeriodicTimer` or channel `ReadAllAsync` + per-iteration `try/catch` with logging |
| `builder.Logging.AddOpenTelemetry()` next to Serilog | `Serilog.Sinks.OpenTelemetry` (Serilog doesn't write to other providers by default) |

## Sources

- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0 — the official performance/reliability page: blocking calls, LOH, pooling, streaming, HttpContext rules (updated 2025-12).
- https://learn.microsoft.com/en-us/aspnet/core/release-notes/aspnetcore-10.0 — what's new in ASP.NET Core 10: AddValidation, SSE, OpenAPI 3.1, memory-pool eviction, auth metrics, cookie-auth 401/403.
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/?view=aspnetcore-10.0 — canonical middleware ordering and its hard constraints (updated 2026-06).
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis/route-handlers?view=aspnetcore-10.0 — route groups, endpoints outside Program.cs, group filters/metadata.
- https://learn.microsoft.com/en-us/dotnet/core/resilience/http-resilience — standard resilience/hedging handler pipelines, defaults, unsafe-method retries (updated 2026-02).
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/host/hosted-services?view=aspnetcore-10.0 — BackgroundService lifecycle, 30 s shutdown timeout, scoped-service consumption.
- https://learn.microsoft.com/en-us/dotnet/core/diagnostics/observability-with-otel — recommended OTel packages and hosting setup (updated 2026-07-01).
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/validation?view=aspnetcore-10.0 — `AddValidation`, source-generated discovery, silent-miss behavior.
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/error-handling?view=aspnetcore-10.0 — `IExceptionHandler`, `UseStatusCodePages`, .NET 10 diagnostics suppression for handled exceptions.
- https://learn.microsoft.com/en-us/dotnet/core/extensions/options-validation-generator — `[OptionsValidator]` compile-time options validation.
- https://github.com/serilog/serilog-extensions-hosting (`writeToProviders`) · https://github.com/serilog/serilog-sinks-opentelemetry — Serilog → OTLP.
- https://github.com/open-telemetry/opentelemetry-dotnet-contrib/tree/main/src/OpenTelemetry.Instrumentation.Runtime — on .NET 9+ it only subscribes to the built-in `System.Runtime` meter.
- https://learn.microsoft.com/en-us/dotnet/core/whats-new/dotnet-10/overview — .NET 10 LTS status, C# 14 feature list.
- https://github.com/dotnet/core/blob/main/release-notes/10.0/README.md — patch/SDK version table (10.0.12 / SDK 10.0.401, 2026-09-08).
