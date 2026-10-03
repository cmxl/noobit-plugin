---
name: aspnet-backend
description: Use when creating or modifying ASP.NET Core / .NET 10+ backend code — minimal API endpoints, DI, configuration/secrets, middleware, validation, ProblemDetails, OpenAPI, HttpClient/Polly resilience, BackgroundService/hosted service workers, health checks, output caching, rate limiting, OpenTelemetry/observability/tracing, Serilog logging, System.Text.Json, Spectre.Console CLIs, mediator/CQRS/MediatR — or backend performance, project layout and API design in C#.
---

# ASP.NET Core Backend (.NET 10+)

## Overview

High-performance ASP.NET Core defaults: minimal APIs, source-generated everything, structured configuration, and allocation-conscious code. Target the latest LTS (`net10.0`), latest C# language version, `Nullable` and `ImplicitUsings` enabled, warnings as errors.

These are defaults for **new code in this stack's standard shape** (web apps/services). In an existing codebase, consistency wins: controllers stay controllers, the established layout stays — apply the performance and async rules (those are universal), and propose structural migrations separately. For CLI tools, the console framework is **Spectre.Console** (+ `Spectre.Console.Cli` for command-based apps) — the cross-cutting rules here (async, options, System.Text.Json, Polly, tests) still apply.

## Project layout

Feature folders (vertical slices) over layer folders. One solution, few projects:

```
src/
  App.Api/            # ASP.NET Core host (BFF) — endpoints, composition root
    Features/
      Orders/
        OrderEndpoints.cs     # MapGroup + handlers
        CreateOrder.cs        # request/response/validator/handler in one slice
        OrderQueries.cs       # read-side (Dapper or EF projection)
    Infrastructure/           # cross-cutting: caching, messaging, persistence wiring
  App.Domain/         # entities, domain logic — no framework references
tests/
  App.Api.Tests/            # unit
  App.Api.IntegrationTests/ # WebApplicationFactory + Testcontainers
```

Small services can collapse Domain into the Api project. Never introduce `IRepository<T>`-over-EF ceremony without a reason — DbContext already is a unit of work.

## Repo-root build files (every solution)

These files at the repo root, always — never put versions or shared properties in individual csproj files:

- **`global.json`** — pin the exact SDK version in use so builds are reproducible across machines/CI, and enable the Microsoft.Testing.Platform runner that xUnit v3 needs:
  ```json
  {
    "sdk": { "version": "10.0.401", "rollForward": "latestPatch" },
    "test": { "runner": "Microsoft.Testing.Platform" }
  }
  ```
  `latestPatch` accepts only newer patches of the **same feature band** (10.0.4xx ≥ 10.0.401) — never a different feature band, which can change analyzers and build behavior. One SDK version everywhere: the Dockerfile build stage uses the matching tag (`mcr.microsoft.com/dotnet/sdk:10.0.401`, not floating `10.0` — `docker`), CI installs it with `UseDotNet@2` + `useGlobalJson: true`, and Renovate/Dependabot bumps `global.json` and the Dockerfile tag together in one PR.
- **`Directory.Build.props`** — shared MSBuild properties (no package versions here):
  ```xml
  <Project>
    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <LangVersion>latest</LangVersion>
      <Nullable>enable</Nullable>
      <ImplicitUsings>enable</ImplicitUsings>
      <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
      <AnalysisLevel>latest</AnalysisLevel>
      <!-- reproducible restores: every project writes packages.lock.json (commit them);
           CI and the Dockerfile restore RID-less with --locked-mode and fail on drift -->
      <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
      <!-- in EVERY project's lock file: every RID the Dockerfile / EF bundle publish for (both arches) -->
      <RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>
    </PropertyGroup>
  </Project>
  ```
  `RuntimeIdentifiers` lives here, for **all** projects — not only on the API host — and lists **every** RID the Dockerfile builds (`linux-x64;linux-arm64` for multi-arch images). Restore then records each RID graph in every lock file, so the sequence is always: **one RID-less restore** `dotnet restore App.slnx --locked-mode`, then `dotnet publish -r <rid> --no-restore` on a CI agent (in the Dockerfile `publish -a $TARGETARCH -p:RestoreLockedMode=true` instead — a cold BuildKit cache mount loses restored packages, so publish must be able to restore, locked; see `docker`) and `dotnet ef migrations bundle --self-contained -r <rid>` — none of them touch a lock file. Never `dotnet restore -r <rid> --locked-mode`: `-r` overrides the `RuntimeIdentifiers` list, so with more than one RID the restored graph no longer matches the lock files and restore fails with NU1004 (verified, SDK 10.0.400). Set only on the host, the bundle silently rewrites the referenced libraries' lock files (adds a `net10.0/linux-x64` section) and locked mode is defeated. Changing a package (`Directory.Packages.props`), a RID, or the SDK band means a plain `dotnet restore` locally and committing the updated lock files in the same PR — if a locked restore fails right after an SDK patch bump, the SDK's implicit packages moved: regenerate and commit.
- **`Directory.Packages.props`** — central package management (CPM): `<ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>` plus one `<PackageVersion Include="..." Version="..."/>` per package. csproj files then contain only version-less `<PackageReference Include="..."/>` entries.
- **`Directory.Build.rsp`** — default MSBuild args picked up by every `dotnet build`/`publish`/`pack`, at minimum:
  ```
  -maxcpucount
  -nologo
  -graph
  ```
- **`.config/dotnet-tools.json`** — local tool manifest so `dotnet tool restore` (CI / local bundle builds) gets the same `dotnet-ef` everywhere — never a global tool:
  ```
  dotnet new tool-manifest
  dotnet tool install dotnet-ef --version 10.0.12   # same version as the EF Core packages in Directory.Packages.props
  ```
  Bump it together with the EF Core packages (one Renovate/Dependabot group).

When adding a NuGet package: add the `PackageVersion` to `Directory.Packages.props` and the version-less `PackageReference` to the csproj. A version attribute on a `PackageReference` in a CPM solution is a review finding.

## Endpoints — minimal APIs

```csharp
public static class OrderEndpoints
{
    // api = the antiforgery-filtered app.MapGroup("/api") from bff-security (CSRF section). Never
    // app.MapGroup("/api/orders"): a sibling group skips the /api endpoint filter → POSTs not CSRF-validated.
    public static RouteGroupBuilder MapOrderEndpoints(this RouteGroupBuilder api)
    {
        var group = api.MapGroup("/orders")
            .RequireAuthorization()
            .WithTags("Orders");

        group.MapGet("/{id:guid}", GetById);
        group.MapPost("/", Create);   // validated by AddValidation() — see Rules
        return api;
    }

    private static async Task<Results<Ok<OrderResponse>, NotFound>> GetById(
        Guid id, IOrderService service, CancellationToken ct) =>
        await service.GetAsync(id, ct) is { } order
            ? TypedResults.Ok(order.ToResponse())
            : TypedResults.NotFound();

    private static async Task<Created<OrderResponse>> Create(
        CreateOrderRequest request, IOrderService service, CancellationToken ct)
    {
        var order = await service.CreateAsync(request, ct);
        return TypedResults.Created($"/api/orders/{order.Id}", order.ToResponse());
    }
}

public sealed record CreateOrderRequest(
    [Required, StringLength(64)] string CustomerRef,
    [Range(1, 1000)] int Quantity);
```

Rules:
- `TypedResults` + `Results<...>` unions — never bare `IResult`.
- Every handler takes and forwards a `CancellationToken`.
- Validation: built-in `builder.Services.AddValidation()` (.NET 10, source-generated) + DataAnnotations / `IValidatableObject` on request types → automatic 400 `ValidationProblem` before the handler runs. Call it in the assembly that declares the endpoints — types it can't discover are silently **not** validated. FluentValidation only for rules DataAnnotations can't express (async/DB lookups), via an endpoint filter (see references).
- Errors: `AddProblemDetails()` + an `IExceptionHandler` + `app.UseExceptionHandler()` + `app.UseStatusCodePages()`, in **every** environment (Development included — same responses everywhere); no try/catch-per-endpoint (handler code and pipeline order in references).
- OpenAPI via built-in `AddOpenApi()` + `app.MapOpenApi()` (Microsoft.AspNetCore.OpenApi) — without `MapOpenApi` no document is served.

## Configuration & DI

- Options pattern always: `builder.Services.AddOptions<MailOptions>().BindConfiguration("Mail").ValidateOnStart();` with DataAnnotations on the options class, validated by the source-generated `[OptionsValidator] public partial class MailOptionsValidator : IValidateOptions<MailOptions>;` registered as `AddSingleton<IValidateOptions<MailOptions>, MailOptionsValidator>()` (reflection-free, AOT-safe). `.ValidateDataAnnotations()` is the reflection-based fallback.
- Never `IConfiguration["key"]` sprinkled through code.
- Production `appsettings`: `AllowedHosts` = the real hostname(s) plus `localhost` (`app.example.com;localhost`), never `*` — the container HEALTHCHECK calls `http://localhost:8080/health/ready` with `Host: localhost`, and host filtering answers anything not listed with 400 — the app would never turn healthy, so `up --wait`, `depends_on: service_healthy` and the deploy hang. nginx's catch-all server already drops unknown hosts from outside, so `localhost` costs nothing. Kestrel's `MaxRequestBodySize` (default 30,000,000 bytes ≈ 28.6 MB) stays equal to nginx's `client_max_body_size` (`30000000` in `nginx-deploy`) — change both together.
- `IHttpClientFactory` for all outbound HTTP + `AddStandardResilienceHandler()` (Microsoft.Extensions.Http.Resilience — Polly v8 under the hood).
- Non-HTTP resilience (external SDKs, RabbitMQ ops, anything flaky): **Polly v8** `ResiliencePipeline` via `AddResiliencePipeline` (Polly.Extensions) — never hand-rolled retry/`Task.Delay` loops, and use the v8 pipeline API, not the legacy v7 `Policy` API. EF's `EnableRetryOnFailure` already covers DB transients for **EF only** — don't double-wrap it in Polly; standalone Dapper calls need a Polly v8 `ResiliencePipeline` (see `data-access`). For SQL Server, filter retries on `SqlException.Number` (or use `SqlConfigurableRetryFactory`) — `SqlException` doesn't override `DbException.IsTransient`, which is always `false`. Exception: SDKs that already retry rate limits themselves (e.g. Discord.Net's built-in 429 handling — see `discord`) aren't wrapped in a second retry layer.
- Keyed services for multiple implementations: `AddKeyedSingleton<IStore>("redis", ...)`.
- **Lifetimes**: scoped for anything touching the `DbContext` or per-request state; singleton for stateless services (`IFusionCache`, `NpgsqlDataSource`, options-backed services); transient only for cheap stateless helpers. Never capture a scoped service in a singleton — background services resolve scopes via `IServiceScopeFactory`.
- **Errors are never swallowed**: an empty `catch` (or catch-and-continue without logging) is a review failure. Log with context and rethrow, handle meaningfully, or let the global `IExceptionHandler` translate it.
- **Logging discipline**: message templates with named placeholders — `_logger.LogInformation("User {UserId} created order {OrderId}", userId, orderId)` — never string interpolation into the logger (it destroys structured logging and allocates even when the level is off; `LoggerMessage` source-gen avoids both).
- Background work: `BackgroundService` + `System.Threading.Channels` for in-process queues; RabbitMQ for cross-service (see `rabbitmq-messaging`). Scheduled jobs, run-once-across-replicas, shutdown: [references/background-jobs.md](references/background-jobs.md).
- Secrets: user-secrets in dev, environment/compose secrets or Key Vault in prod, never in `appsettings*.json` or logs: [references/configuration-secrets.md](references/configuration-secrets.md).
- Mediator/CQRS: the default is **no mediator** — endpoints call services directly. If a project genuinely evolves a CQRS dispatch need, use **martinothamar/Mediator** (`Mediator.SourceGenerator` + `Mediator.Abstractions`; source-generated, `ValueTask`-based, MIT, v3.x) — **never MediatR** (reflection-based, commercially licensed since v13).

## Performance checklist

- **JSON**: source-generated `JsonSerializerContext` registered via `ConfigureHttpJsonOptions(o => o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default))` — covers minimal-API bodies only; pass `AppJsonContext.Default.X` to `HttpClient` `GetFromJsonAsync`/`PostAsJsonAsync` and `JsonSerializer` calls yourself. No Newtonsoft.
- **Caching**: FusionCache (see `fusioncache-redis`); output caching for anonymous GET endpoints = `AddOutputCache()` + `app.UseOutputCache()` (after CORS/AuthN/AuthZ) + `.CacheOutput()` per endpoint — authenticated requests and responses that set a cookie are never cached. In a cookie BFF every `/api` response mints the `XSRF-TOKEN` cookie (`Set-Cookie` + `no-store`), so cacheable endpoints live **outside** `/api`, e.g. a `/public` group with `.AllowAnonymous().CacheOutput()` (`bff-security`).
- **Async**: `async`/`await` all the way; no `.Result`/`.Wait()`/`GetAwaiter().GetResult()`; `ValueTask` on hot interfaces; `IAsyncEnumerable<T>` for streams.
- **Allocations**: `Span<T>`/`Memory<T>` for parsing, `ArrayPool<T>`/`ObjectPool<T>` in hot loops, `StringBuilder` pooling, avoid LINQ in per-request hot paths.
- **Server**: Kestrel behind nginx — nginx terminates TLS/HTTP2 and proxies upstream over HTTP/1.1; response compression only at nginx (don't double-compress).
- **Startup**: `builder.Services.AddRequestTimeouts()` + `app.UseRequestTimeouts()`. Health checks: `/health/live` answers "is the process up" and has **no dependency checks** (it drives restarts in orchestrators that restart on a failed probe, e.g. Kubernetes; plain Docker/Compose don't restart on health — either way a DB outage must not restart every app instance); `/health/ready` runs the dependency checks:

  ```csharp
  builder.Services.AddHealthChecks()   // timeout: one hung dependency must not stall the probe
      .AddNpgSql(tags: ["ready"], timeout: TimeSpan.FromSeconds(3))  // AspNetCore.HealthChecks.NpgSql: resolves the app's NpgsqlDataSource from DI (.SqlServer: connection string)
      // Redis: ping the ONE shared multiplexer (fusioncache-redis `redis` Lazy) — AddRedis(connectionString) opens a
      // second connection, and AddRedis(sp => …)'s factory is synchronous (would block on the Lazy<Task>)
      .AddAsyncCheck("redis", async ct =>   // HealthCheckResult: Microsoft.Extensions.Diagnostics.HealthChecks
      {
          var mux = await redis.Value.WaitAsync(ct);
          await mux.GetDatabase().PingAsync();  // throws while disconnected → reported Unhealthy
          return HealthCheckResult.Healthy();
      }, tags: ["ready"], timeout: TimeSpan.FromSeconds(3));
  // AllowAnonymous: the BFF fallback policy would 401 the probe; DisableRateLimiting: probes from one IP never 429
  app.MapHealthChecks("/health/live", new() { Predicate = _ => false }).AllowAnonymous().DisableRateLimiting();
  app.MapHealthChecks("/health/ready", new() { Predicate = c => c.Tags.Contains("ready") }).AllowAnonymous().DisableRateLimiting();
  ```
- **Rate limiting**: `AddRateLimiter` + `app.UseRateLimiter()` — policies and placement in `bff-security`.
- **Observability** ([references/observability.md](references/observability.md)): OpenTelemetry (traces + metrics) with OTLP exporter; logs reach OTLP through Serilog's `Serilog.Sinks.OpenTelemetry` — **not** `builder.Logging.AddOpenTelemetry()`, which Serilog bypasses (it doesn't forward to other `ILoggerProvider`s by default). **Serilog is the logging framework** (`Serilog.AspNetCore`, Serilog 4.x): two-stage init (bootstrap logger for startup failures, then full config from `appsettings`), `UseSerilogRequestLogging()` for one structured event per request instead of the noisy defaults, JSON console sink in containers. Application code depends on `ILogger<T>` + `LoggerMessage` source-gen only — Serilog is the backend, not an API to code against (no static `Log.` calls in app code).

## Common mistakes

| Mistake | Fix |
|---|---|
| Controllers for new code | Minimal APIs with route groups |
| `IConfiguration` injected everywhere | Bound, validated options classes |
| Sync-over-async (`.Result`) | Async all the way; it deadlocks and starves the pool |
| Reflection JSON on hot paths | `JsonSerializerContext` source generation |
| Catch-all try/catch in handlers | Global `IExceptionHandler` + ProblemDetails |
| `Task.Run` in request handlers | It wastes a pool thread; just await (exception: work that must outlive the response, e.g. a deferred Discord interaction — see `discord`) |
| Missing `CancellationToken` | Thread it through every async call |
| Adding MediatR | If a mediator is warranted at all: martinothamar/Mediator (source-generated); MediatR is reflection-based and commercial since v13 |
| NLog/log4net/`Console.WriteLine` logging | Serilog behind `ILogger<T>` — the only sanctioned logging framework |
| Newtonsoft.Json anywhere | System.Text.Json with source generation — no exceptions in new code (the transitive dependency of Discord.Net is accepted — see `discord`) |
| Hand-rolled retry loops (`for` + `Task.Delay`) | Polly v8 `ResiliencePipeline` (or the standard resilience handler for HTTP) |
| Empty `catch` / silently swallowed exception | Log with context + rethrow, or handle meaningfully — silence is a review failure |
| `$"interpolated {value}"` into `_logger` | Message template with named placeholders — keeps logs structured and cheap |
| Scoped service captured in a singleton | `IServiceScopeFactory` scope per unit of work |
| Hand-rolled DataAnnotations validation filter | `builder.Services.AddValidation()` (.NET 10) |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- ASP.NET Core: https://learn.microsoft.com/en-us/aspnet/core/
- .NET & C#: https://learn.microsoft.com/en-us/dotnet/
- OpenTelemetry .NET: https://opentelemetry.io/docs/languages/dotnet/
- Mediator (sanctioned CQRS package, if warranted): https://github.com/martinothamar/Mediator
- Serilog: https://github.com/serilog/serilog (ASP.NET Core integration: https://github.com/serilog/serilog-aspnetcore)
- Polly: https://github.com/App-vNext/Polly (docs: https://www.pollydocs.org/)
- Spectre.Console (CLI apps): https://spectreconsole.net/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
- **Curated enterprise example codebases (dotnet/eShop, CleanArchitecture templates, async guidance — with what to study vs ignore): [references/example-codebases.md](references/example-codebases.md) — consult when designing service boundaries, aggregates, or event flows.**
