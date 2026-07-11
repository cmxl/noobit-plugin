---
name: dotnet-testing
description: Use when writing or fixing .NET tests — unit tests, integration tests, API tests, xUnit, mocking, Testcontainers, WebApplicationFactory, flaky tests, or deciding what/how to test C# code. Every feature ships with tests.
---

# .NET Testing — xUnit v3 + Testcontainers

## Overview

Standard: **xUnit v3** (`xunit.v3` package, runs on Microsoft.Testing.Platform), **NSubstitute** for mocks (**never Moq** — NSubstitute is the only sanctioned mocking library), **Testcontainers** for real infrastructure in integration tests (databases, Redis, RabbitMQ run as Docker containers), **WebApplicationFactory** for in-process API tests, **Respawn** for DB cleanup between tests. Real dependencies over mocks wherever practical — never mock `DbContext` or `IFusionCache`.

Two test projects per service:
- `*.Tests` — unit: domain logic, handlers with substituted ports, no I/O, milliseconds.
- `*.IntegrationTests` — WebApplicationFactory + Testcontainers: real HTTP, real DB, real Redis/Rabbit.

## What "covered" means

A feature is covered when:
1. Happy path asserted end-to-end (integration test through the HTTP endpoint).
2. Each business rule / branch has a unit test.
3. Failure modes asserted: validation → 400 ProblemDetails, missing → 404, unauthenticated → 401, concurrency/duplicate handling where relevant.
4. Regression bug fixes start with a failing test reproducing the bug.

Assert observable behavior (responses, DB state, published messages) — not implementation details (which internal method was called). Tests that break on refactors without behavior changes are wrong.

## Integration test infrastructure

```csharp
// Shared containers per test collection — start once, Respawn between tests.
public sealed class ApiFixture : WebApplicationFactory<Program>, IAsyncLifetime
{
    private readonly PostgreSqlContainer _db = new PostgreSqlBuilder("postgres:17").Build();
    private readonly RedisContainer _redis = new RedisBuilder("redis:8").Build();
    private Respawner _respawner = default!;

    public async ValueTask InitializeAsync()
    {
        await Task.WhenAll(_db.StartAsync(), _redis.StartAsync());
        _ = Server; // boot the app
        await using var conn = new NpgsqlConnection(_db.GetConnectionString());
        await conn.OpenAsync();
        _respawner = await Respawner.CreateAsync(conn,
            new RespawnerOptions { DbAdapter = DbAdapter.Postgres });
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder) =>
        builder.UseSetting("ConnectionStrings:Default", _db.GetConnectionString())
               .UseSetting("ConnectionStrings:Redis", _redis.GetConnectionString());

    public async Task ResetAsync()
    {
        await using var conn = new NpgsqlConnection(_db.GetConnectionString());
        await conn.OpenAsync();
        await _respawner.ResetAsync(conn);
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        await Task.WhenAll(_db.DisposeAsync().AsTask(), _redis.DisposeAsync().AsTask());
    }
}

[CollectionDefinition(nameof(ApiCollection))]
public sealed class ApiCollection : ICollectionFixture<ApiFixture>;
```

```csharp
[Collection(nameof(ApiCollection))]
public sealed class CreateOrderTests(ApiFixture api) : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await api.ResetAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task Post_valid_order_returns_201_and_persists()
    {
        var client = api.CreateClient();
        var response = await client.PostAsJsonAsync("/api/orders", new { productId = 1, qty = 2 },
            TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var created = await response.Content.ReadFromJsonAsync<OrderResponse>();
        Assert.NotNull(created);
        Assert.Equal(2, created.Quantity);
    }
}
```

Auth in integration tests: a test authentication handler (`AddAuthentication("Test").AddScheme<...>`) injecting a claims principal — don't bypass authorization by removing it.

## Conventions

- Naming: `Method_condition_expectedResult` or behavior sentences (`Post_valid_order_returns_201_and_persists`).
- One logical assertion block per test; `[Theory]`+`[InlineData]` for input matrices.
- No `Thread.Sleep`/arbitrary delays — poll with timeout or await the actual signal (flaky tests are bugs; see superpowers:systematic-debugging).
- Use `TestContext.Current.CancellationToken` (xUnit v3) in async calls.
- Time: inject `TimeProvider`, use `FakeTimeProvider` (`Microsoft.Extensions.TimeProvider.Testing`).
- SQLite in-memory is **not** an integration-test substitute for MSSQL/Postgres (different SQL semantics) — Testcontainers exists for that. Unit tests shouldn't need a DB at all.
- Angular side: Vitest for components/stores (see `angular-developer` skill), Playwright for e2e flows against the docker-compose stack.

## Running

```
dotnet test                                                # whole solution
dotnet test -- --filter-not-trait "Category=Integration"   # quick loop; MTP flags go after --
```

xUnit v3 runs on Microsoft.Testing.Platform (MTP): filters use MTP flags after `--` (`--filter-not-trait`, `--filter-class`, `--filter-method`) — the old VSTest `--filter "..."` syntax does not apply. On .NET SDK 10, `dotnet test` uses the MTP runner only when `global.json` contains `{ "test": { "runner": "Microsoft.Testing.Platform" } }` (part of the standard repo-root files — see `aspnet-backend`).

Testcontainers needs Docker running — **if it isn't, start it instead of skipping the tests**. Check with `docker info`; on failure start the engine and poll until ready (up to ~90s):

```powershell
docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"   # Windows
    # Linux: sudo systemctl start docker   |   macOS: open -a "Docker Desktop"
    $deadline = (Get-Date).AddSeconds(90)
    do { Start-Sleep 3; docker info 2>$null | Out-Null } while ($LASTEXITCODE -ne 0 -and (Get-Date) -lt $deadline)
}
```

Only report Docker as unavailable (and integration tests as skipped) if it still isn't up after that. Containers are shared per collection — a full integration suite should boot infrastructure once, not per test class.

Testcontainers rules (per the official best-practices doc):
- **Pin image versions** (`postgres:17`, never `latest` or the module default).
- Never assign static container names or static host-port bindings — random names/ports are what make parallel and CI runs safe; read endpoints via `GetConnectionString()`/`GetMappedPublicPort()`.
- Connect via the container's `Hostname` property, not `localhost`.
- Container-to-container communication goes through networks + `WithNetworkAliases`, not mapped host ports.
- Copy files in with `WithResourceMapping`, don't bind-mount host paths.
- Never disable the Resource Reaper — it's what cleans up after crashed runs.

## Common mistakes

| Mistake | Fix |
|---|---|
| Moq (or any mocking lib besides NSubstitute) | NSubstitute — the only sanctioned mocking library |
| Mocking DbContext/IQueryable | Testcontainers + real provider |
| In-memory EF provider | Same — it lies about SQL semantics |
| New container per test class | Collection fixture, Respawn between tests |
| Asserting internal calls (`Received()`) as the main assertion | Assert outputs and state; `Received()` only for ports with no observable outcome (e.g. published message) |
| Test order dependence | `ResetAsync()` in InitializeAsync; no static state |
| Skipping tests to "go fast" | Coverage is the definition of done here |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- xUnit v3: https://xunit.net/docs/getting-started/v3/getting-started
- NSubstitute: https://nsubstitute.github.io/
- Testcontainers for .NET: https://dotnet.testcontainers.org/ (best practices: https://dotnet.testcontainers.org/api/best_practices/)
- Respawn: https://github.com/jbogard/Respawn
- Integration tests / WebApplicationFactory: https://learn.microsoft.com/en-us/aspnet/core/test/integration-tests
- Vitest: https://vitest.dev/ | Playwright: https://playwright.dev/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
