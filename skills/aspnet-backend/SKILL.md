---
name: aspnet-backend
description: Use when creating or modifying ASP.NET Core / .NET 10+ backend code — projects, endpoints, services, DI, configuration, middleware, hosted services — or when asked about backend performance, project layout, error handling, or API design in C#.
---

# ASP.NET Core Backend (.NET 10+)

## Overview

High-performance ASP.NET Core defaults: minimal APIs, source-generated everything, structured configuration, and allocation-conscious code. Target the latest LTS (`net10.0`), latest C# language version, `Nullable` and `ImplicitUsings` enabled, warnings as errors.

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

Four files at the repo root, always — never put versions or shared properties in individual csproj files:

- **`global.json`** — pin the SDK so builds are reproducible across machines/CI:
  ```json
  { "sdk": { "version": "10.0.100", "rollForward": "latestFeature" } }
  ```
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
    </PropertyGroup>
  </Project>
  ```
- **`Directory.Packages.props`** — central package management (CPM): `<ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>` plus one `<PackageVersion Include="..." Version="..."/>` per package. csproj files then contain only version-less `<PackageReference Include="..."/>` entries.
- **`Directory.Build.rsp`** — default MSBuild args picked up by every `dotnet build`/`publish`/`pack`, at minimum:
  ```
  -maxcpucount
  -nologo
  -graph
  ```

When adding a NuGet package: add the `PackageVersion` to `Directory.Packages.props` and the version-less `PackageReference` to the csproj. A version attribute on a `PackageReference` in a CPM solution is a review finding.

## Endpoints — minimal APIs

```csharp
public static class OrderEndpoints
{
    public static IEndpointRouteBuilder MapOrders(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/orders")
            .RequireAuthorization()
            .WithTags("Orders");

        group.MapGet("/{id:guid}", GetById);
        group.MapPost("/", Create).AddEndpointFilter<ValidationFilter<CreateOrderRequest>>();
        return app;
    }

    private static async Task<Results<Ok<OrderResponse>, NotFound>> GetById(
        Guid id, IOrderService service, CancellationToken ct) =>
        await service.GetAsync(id, ct) is { } order
            ? TypedResults.Ok(order.ToResponse())
            : TypedResults.NotFound();
}
```

Rules:
- `TypedResults` + `Results<...>` unions — never bare `IResult`.
- Every handler takes and forwards a `CancellationToken`.
- Validation as endpoint filters (FluentValidation or DataAnnotations) — return `TypedResults.ValidationProblem`.
- Errors: `AddProblemDetails()` + an `IExceptionHandler` implementation; no try/catch-per-endpoint.
- OpenAPI via built-in `AddOpenApi()` (Microsoft.AspNetCore.OpenApi).

## Configuration & DI

- Options pattern always: `builder.Services.AddOptions<MailOptions>().BindConfiguration("Mail").ValidateDataAnnotations().ValidateOnStart();`
- Never `IConfiguration["key"]` sprinkled through code.
- `IHttpClientFactory` for all outbound HTTP + `AddStandardResilienceHandler()` (Microsoft.Extensions.Http.Resilience).
- Keyed services for multiple implementations: `AddKeyedSingleton<IStore>("redis", ...)`.
- Background work: `BackgroundService` + `System.Threading.Channels` for in-process queues; RabbitMQ for cross-service (see `rabbitmq-messaging`).

## Performance checklist

- **JSON**: source-generated `JsonSerializerContext` registered via `ConfigureHttpJsonOptions`. No Newtonsoft.
- **Caching**: FusionCache (see `fusioncache-redis`); `AddOutputCache()` for anonymous GET endpoints.
- **Async**: `async`/`await` all the way; no `.Result`/`.Wait()`/`GetAwaiter().GetResult()`; `ValueTask` on hot interfaces; `IAsyncEnumerable<T>` for streams.
- **Allocations**: `Span<T>`/`Memory<T>` for parsing, `ArrayPool<T>`/`ObjectPool<T>` in hot loops, `StringBuilder` pooling, avoid LINQ in per-request hot paths.
- **Server**: Kestrel behind nginx — nginx terminates TLS/HTTP2 and proxies upstream over HTTP/1.1; response compression only at nginx (don't double-compress).
- **Startup**: `builder.Services.AddRequestTimeouts()`, health checks at `/health/live` and `/health/ready` (`AddHealthChecks` + Redis/DB/Rabbit checks).
- **Observability**: OpenTelemetry (traces + metrics) with OTLP exporter; `ILogger<T>` with `LoggerMessage` source-gen for hot-path logs.

## Common mistakes

| Mistake | Fix |
|---|---|
| Controllers for new code | Minimal APIs with route groups |
| `IConfiguration` injected everywhere | Bound, validated options classes |
| Sync-over-async (`.Result`) | Async all the way; it deadlocks and starves the pool |
| Reflection JSON on hot paths | `JsonSerializerContext` source generation |
| Catch-all try/catch in handlers | Global `IExceptionHandler` + ProblemDetails |
| `Task.Run` in request handlers | It wastes a pool thread; just await |
| Missing `CancellationToken` | Thread it through every async call |
