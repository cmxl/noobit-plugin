---
name: dotnet-testing
description: Use when writing or fixing .NET tests — unit/integration/API tests, xUnit v3, NSubstitute mocks, Testcontainers, Respawn, WebApplicationFactory, TimeProvider/FakeTimeProvider, dotnet test filters (Microsoft.Testing.Platform), code coverage, flaky tests, or deciding what/how to test C# code.
---

# .NET Testing — xUnit v3 + Testcontainers

## Overview

Standard: **xUnit v3** (`xunit.v3` package, runs on Microsoft.Testing.Platform), **NSubstitute** for mocks (**never Moq** — NSubstitute is the only sanctioned mocking library), **Testcontainers** for real infrastructure in integration tests (databases, Redis, RabbitMQ run as Docker containers), **WebApplicationFactory** for in-process API tests, **Respawn** for DB cleanup between tests. Real dependencies over mocks wherever practical — never mock `DbContext` or `IFusionCache` (for caching tests see `fusioncache-redis` → Testing: a real memory-only FusionCache in unit tests, two FusionCache instances on a Testcontainers Redis for L2/backplane tests), and never stand in for the real database with the EF Core InMemory provider or SQLite in-memory — EF Core's testing guidance recommends testing against the production database system, "highly discourages" InMemory, and lists SQLite's behavioral differences (case sensitivity, provider-specific functions, raw SQL). Use Testcontainers with the production engine.

Two test projects per service:
- `*.Tests` — unit: domain logic, handlers with substituted ports, no I/O, milliseconds.
- `*.IntegrationTests` — WebApplicationFactory + Testcontainers: real HTTP, real DB, real Redis/Rabbit.

Scope: this skill covers the **.NET** side only. Angular tests (Vitest for components/stores, Playwright e2e against the docker-compose stack) follow the `angular-developer` skill.

## What "covered" means

A feature is covered when:
1. Happy path asserted end-to-end (integration test through the HTTP endpoint).
2. Each business rule / branch has a unit test.
3. Failure modes asserted: validation → 400 ProblemDetails, missing → 404, unauthenticated → 401, concurrency/duplicate handling where relevant.
4. Regression bug fixes start with a failing test reproducing the bug.

Assert observable behavior (responses, DB state, published messages) — not implementation details (which internal method was called). Tests that break on refactors without behavior changes are wrong.

## Integration test infrastructure

```csharp
// Shared containers per test collection — start once, migrate once, Respawn between tests.
public sealed class ApiFixture : WebApplicationFactory<Program>, IAsyncLifetime
{
    private readonly PostgreSqlContainer _db = new PostgreSqlBuilder("postgres:18").Build();
    private readonly RedisContainer _redis = new RedisBuilder("redis:8").Build();
    private Respawner _respawner = default!;

    public async ValueTask InitializeAsync()
    {
        var ct = TestContext.Current.CancellationToken;
        await Task.WhenAll(_db.StartAsync(ct), _redis.StartAsync(ct));

        // Schema first — Respawner.CreateAsync reads the table graph, so the tables must exist.
        await using (var scope = Services.CreateAsyncScope()) // first Services access boots the app
            await scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.MigrateAsync(ct);

        await using var conn = new NpgsqlConnection(_db.GetConnectionString());
        await conn.OpenAsync(ct);
        _respawner = await Respawner.CreateAsync(conn, new RespawnerOptions
        {
            DbAdapter = DbAdapter.Postgres,
            SchemasToInclude = ["public"],
            TablesToIgnore = [new Table("__EFMigrationsHistory")],
        });
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder) =>
        builder.UseSetting("ConnectionStrings:Default", _db.GetConnectionString())
               .UseSetting("ConnectionStrings:Redis", _redis.GetConnectionString());

    public async Task ResetAsync()
    {
        await using var conn = new NpgsqlConnection(_db.GetConnectionString());
        await conn.OpenAsync(TestContext.Current.CancellationToken);
        await _respawner.ResetAsync(conn);
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        await Task.WhenAll(_db.DisposeAsync().AsTask(), _redis.DisposeAsync().AsTask());
    }
}

// Classes in one collection run sequentially — the shared DB is safe without DisableParallelization.
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
        var ct = TestContext.Current.CancellationToken;
        var client = await api.CreateAuthenticatedClientAsync(ct); // signed-in test user + X-XSRF-TOKEN (bff-security checklist)
        var response = await client.PostAsJsonAsync("/api/orders", new { productId = 1, qty = 2 }, ct);

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var created = await response.Content.ReadFromJsonAsync<OrderResponse>(ct);
        Assert.NotNull(created);
        Assert.Equal(2, created.Quantity);
    }
}
```

MSSQL works the same way — `MsSqlBuilder("mcr.microsoft.com/mssql/server:2025-latest")`, `SqlConnection`, `DbAdapter.SqlServer` (sample in the reference).

Auth in integration tests: a test authentication handler (`AddAuthentication("Test").AddScheme<...>`) injecting a claims principal — don't bypass authorization by removing it. Auth/CSRF test cases (tokenless POST → 400, `/api` → 401 not 302, token re-issue after login, …): checklist in `bff-security` → references/best-practices.md.

Published messages: run a real broker (`Testcontainers.RabbitMq`), bind a server-named probe queue to the exchange **before** the act, then poll `BasicGetAsync` against a deadline — pattern in the reference; topology/outbox design lives in `rabbitmq-messaging`.

## Conventions

- Naming: `Method_condition_expectedResult` or behavior sentences (`Post_valid_order_returns_201_and_persists`).
- One logical assertion block per test; `[Theory]`+`[InlineData]` for input matrices.
- No `Thread.Sleep`/arbitrary delays — poll with timeout or await the actual signal (flaky tests are bugs; see superpowers:systematic-debugging).
- Pass `TestContext.Current.CancellationToken` (xUnit v3) to every async call — HTTP, `ReadFromJsonAsync`, DB, `StartAsync` (analyzer xUnit1051 flags misses).
- Time: inject `TimeProvider`, use `FakeTimeProvider` (`Microsoft.Extensions.TimeProvider.Testing`).
- Unit tests shouldn't need a DB at all; integration tests use the production engine via Testcontainers (see Overview).

## Running

```
dotnet test                                                # everything under the current dir
dotnet test --filter-not-trait "Category=Integration"      # quick loop
dotnet test --project tests/Orders.Tests                   # one project (--solution X.slnx for a solution)
dotnet test --coverage --coverage-output-format cobertura  # needs Microsoft.Testing.Extensions.CodeCoverage
```

xUnit v3 runs on Microsoft.Testing.Platform (MTP). On .NET SDK 10, `dotnet test` runs in **MTP mode** only when `global.json` contains `{ "test": { "runner": "Microsoft.Testing.Platform" } }` (part of the standard repo-root files — see `aspnet-backend`). In MTP mode, test-app flags (`--filter-class`, `--filter-method`, `--filter-trait`/`--filter-not-trait`, `--report-xunit-trx`, `--coverage`) go **directly** on `dotnet test`; `--` is optional, and positional paths are gone (`dotnet test X.sln` → `--solution X.sln`, a project → `--project`). "MTP flags go after `--`" is the old SDK 8/9 VSTest-bridge rule. Details: [references/best-practices.md](references/best-practices.md).

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
- **Pin image versions** (`postgres:18` — same major as production, never `latest` or the module default).
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
| EF Core InMemory provider or SQLite in-memory as the "test database" | Same — they lie about SQL semantics (translation, transactions, constraints) |
| New container per test class | Collection fixture, Respawn between tests |
| Respawner created before migrations ran | Migrate in the fixture's `InitializeAsync`, then `Respawner.CreateAsync`; ignore `__EFMigrationsHistory` |
| Asserting internal calls (`Received()`) as the main assertion | Assert outputs and state; `Received()` only for ports with no observable outcome (e.g. published message) |
| Test order dependence | `ResetAsync()` in InitializeAsync; no static state |
| `[assembly: CollectionBehavior(DisableTestParallelization/MaxParallelThreads …)]` | Compile error since xUnit 4.0 — `[assembly: Parallelization(Mode = …, MaxThreads = …)]` |
| Skipping tests to "go fast" | Coverage is the definition of done here |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- xUnit v3: https://xunit.net/docs/getting-started/v3/getting-started (release notes: https://xunit.net/releases/)
- NSubstitute: https://nsubstitute.github.io/
- Testcontainers for .NET: https://dotnet.testcontainers.org/ (best practices: https://dotnet.testcontainers.org/api/best_practices/, xUnit v3 integration: https://dotnet.testcontainers.org/test_frameworks/xunit_net/)
- Respawn: https://github.com/jbogard/Respawn
- Integration tests / WebApplicationFactory: https://learn.microsoft.com/en-us/aspnet/core/test/integration-tests
- `dotnet test` (MTP mode): https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-with-dotnet-test
- EF Core testing strategy: https://learn.microsoft.com/en-us/ef/core/testing/choosing-a-testing-strategy
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
