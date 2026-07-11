# .NET Testing Best Practices — xUnit v3 + Testcontainers

Verified against official documentation, July 2026. Primary sources: xunit.net (v3 getting started, what's new, migration, MTP integration, parallelism, shared context), dotnet.testcontainers.org, learn.microsoft.com (integration tests, unit testing best practices, MTP overview, MTP code coverage), nsubstitute.github.io, github.com/jbogard/Respawn, nuget.org version pages. Extends `SKILL.md`; conventions there (real infra via Testcontainers, no mocked DbContext, no in-memory EF provider) apply to every sample here.

## Current versions (July 2026)

| Package | Stable | Notes |
|---|---|---|
| `xunit.v3` | **3.2.2** (2026-01-14) | 4.0.0 still prerelease (`4.0.0-pre.128`, 2026-05-31). 3.x defaults to MTP v1; 4.0.0+ ships MTP v2 only. Explicit variants exist: `xunit.v3.mtp-v1`, `xunit.v3.mtp-v2`, `xunit.v3.mtp-off` (same for `xunit.v3.core.*`). |
| `xunit.runner.visualstudio` | 3.1.5 | Only needed for the legacy VSTest path (together with `Microsoft.NET.Test.Sdk`). |
| Microsoft.Testing.Platform (MTP) | v2 GA (`Microsoft.Testing.Extensions.CodeCoverage` 18.1.x pairs with MTP 2.0.x) | Microsoft's lightweight VSTest replacement; supported by MSTest, NUnit, xUnit v3, TUnit. `Microsoft.Testing.Platform.MSBuild` (pulled in transitively) auto-registers extension packages. |
| `Testcontainers` | **4.13.0** (2026-07-02) | Modules: `Testcontainers.PostgreSql`, `Testcontainers.Redis`, `Testcontainers.MsSql`, `Testcontainers.RabbitMq`, … |
| `NSubstitute` | **5.3.0** (2024-10-28) | 6.0.0-rc.1 in prerelease. Always add `NSubstitute.Analyzers.CSharp`. |
| `Respawn` | **7.0.0** (2025-11-30) | Adapters: SqlServer, Postgres, MySql, Oracle, Informix. |

## Established patterns

### Project setup (xUnit v3, .NET 10)

v3 test projects are stand-alone executables — `OutputType` must be `Exe`, and `xunit.v3` replaces the v2 `xunit` package (`xunit.abstractions` is gone; `ITestOutputHelper` now lives in `Xunit`).

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <LangVersion>latest</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <OutputType>Exe</OutputType>
    <UseMicrosoftTestingPlatformRunner>true</UseMicrosoftTestingPlatformRunner>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit.v3" Version="3.2.2" />
  </ItemGroup>
  <ItemGroup>
    <Content Include="xunit.runner.json" CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
</Project>
```

Enabling `dotnet test` depends on the SDK:

- SDK 8/9: `<TestingPlatformDotnetTestSupport>true</TestingPlatformDotnetTestSupport>` in the csproj.
- **SDK 10+ (our default)**: configure it once in `global.json`:

```json
{ "test": { "runner": "Microsoft.Testing.Platform" } }
```

Run tests via `dotnet test`, `dotnet run`, or the built executable directly. MTP filtering flags: `--filter-class`, `--filter-method`, `--filter-namespace`, `--filter-trait` / `--filter-not-trait` (e.g. `dotnet test -- --filter-not-trait "Category=Integration"`), reports via `--report-xunit` / `--report-junit`, `--xunit-info` for verbose xUnit-style output.

`xunit.runner.json` (copied to output) holds runner config:

```json
{
  "$schema": "https://xunit.net/schema/current/xunit.runner.schema.json",
  "parallelAlgorithm": "conservative",
  "maxParallelThreads": -1,
  "parallelizeTestCollections": true,
  "stopOnFail": false
}
```

### Parallelism model

- Unit of parallelism is the **test collection**. Default: one collection per class → tests in a class run sequentially, classes run in parallel.
- Default algorithm is **conservative** (since 2.8): starts at most `maxParallelThreads` tests and waits for completions — accurate `Timeout` behavior. `aggressive` restores the old scheduling (better CPU use for async-heavy suites, worse timing accuracy).
- Control knobs: `[Collection("name")]` to serialize classes together; `[CollectionDefinition(..., DisableParallelization = true)]` to serialize one collection against everything else (use this for the integration-test collection); `[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]` or `DisableTestParallelization = true` assembly-wide; `MaxParallelThreads` via attribute, `xunit.runner.json`, or MTP `--max-threads` / `--parallel`.

### Fixtures and lifecycle in v3

- `IAsyncLifetime` **changed in v3**: both members return `ValueTask`, and the interface now inherits `IAsyncDisposable`. When a class implements both `IAsyncDisposable` and `IDisposable`, v3 calls **only** `DisposeAsync()` — don't put cleanup in `Dispose()` as a fallback.
- Hierarchy: constructor/`IAsyncLifetime` per test → `IClassFixture<T>` per class → `ICollectionFixture<T>` per collection (`[CollectionDefinition]` must live in the test assembly) → **assembly fixtures, new in v3**: `[assembly: AssemblyFixture(typeof(DockerFixture))]`, created once before any test, injected via constructor, runs alongside parallel tests. For "start containers once for the whole suite", an assembly fixture is the v3-native option; a collection fixture (as in SKILL.md) is right when the suite should also be serialized.
- `TestContext.Current` (new in v3) exposes `CancellationToken`, `SendDiagnosticMessage`, `AddAttachment`, `AddWarning`, `KeyValueStorage`; also injectable as `ITestContextAccessor`. Pass `TestContext.Current.CancellationToken` to every async call so cancelled/timed-out runs stop promptly.
- Dynamic skip: `Assert.Skip(reason)`, `Assert.SkipUnless(cond, reason)`, `Assert.SkipWhen(cond, reason)`, plus `SkipUnless`/`SkipWhen` and `Explicit` properties on `[Fact]`/`[Theory]` — use these for "Docker not available" style guards instead of silently passing.

```csharp
// v3 assembly fixture: one container for the whole assembly, tests stay parallel.
[assembly: AssemblyFixture(typeof(PostgresFixture))]

public sealed class PostgresFixture : IAsyncLifetime
{
    public PostgreSqlContainer Db { get; } = new PostgreSqlBuilder("postgres:17").Build();

    public async ValueTask InitializeAsync() =>
        await Db.StartAsync(TestContext.Current.CancellationToken);

    public async ValueTask DisposeAsync() => await Db.DisposeAsync();
}

public sealed class OrderRepositoryTests(PostgresFixture postgres) // injected, no attribute needed
{
    [Fact]
    public async Task Insert_then_read_roundtrips()
    {
        await using var conn = new NpgsqlConnection(postgres.Db.GetConnectionString());
        await conn.OpenAsync(TestContext.Current.CancellationToken);
        // ...
    }
}
```

### Testcontainers: modules, wait strategies, reuse

- Prefer module packages over raw `ContainerBuilder` — they ship "pre-configured with best practices" (correct image, wait strategy, `GetConnectionString()`): `new PostgreSqlBuilder("postgres:17").Build()`, then `await container.StartAsync(TestContext.Current.CancellationToken);`.
- Wait strategies (only needed for custom containers or overrides): `Wait.ForUnixContainer()` chained with `UntilInternalTcpPortIsAvailable(port)` / `UntilExternalTcpPortIsAvailable(port)`, `UntilHttpRequestIsSucceeded(...)`, `UntilContainerIsHealthy()`, `UntilMessageIsLogged(...)`, `UntilCommandIsCompleted("pg_isready")`, or a custom `IWaitUntil` via `AddCustomWaitStrategy(...)`. Each accepts options for `Timeout`, `Interval`, `Retries`; `WaitStrategyMode.OneShot` handles run-to-completion containers (migrations).

```csharp
var app = new ContainerBuilder("ghcr.io/acme/worker:1.4")
    .WithPortBinding(8080, assignRandomHostPort: true)
    .WithWaitStrategy(Wait.ForUnixContainer()
        .UntilHttpRequestIsSucceeded(r => r
            .ForPath("/health").ForPort(8080).ForStatusCode(HttpStatusCode.OK)))
    .Build();
await app.StartAsync(TestContext.Current.CancellationToken);
```
- **Reuse** (`.WithReuse(true)`) keeps containers alive *between test runs* for local dev speed. It is explicitly **experimental**, disables the resource reaper (no auto-cleanup), and the docs warn it is *not* a substitute for proper shared fixtures inside a run. Reuse matches containers by a hash of the builder config; add `.WithLabel("reuse-id", "my-suite")` to avoid collisions, and give reused networks/volumes fixed names (`.WithName(...)`). Never enable it in CI.

### WebApplicationFactory + xUnit v3

- `Microsoft.AspNetCore.Mvc.Testing`; expose the entry point with `public partial class Program { }` at the bottom of `Program.cs`.
- `WebApplicationFactory<Program>` implements `IAsyncDisposable` with a `ValueTask DisposeAsync()` — this composes cleanly with v3's `ValueTask`-based `IAsyncLifetime` (override `DisposeAsync`, call `base.DisposeAsync()`, then dispose containers), exactly as the `ApiFixture` in SKILL.md does.
- Inject container connection strings in `ConfigureWebHost` via `UseSetting` (containers must be started first — start them in `InitializeAsync` before first `CreateClient()`/`Server` access). Per-test service overrides: `factory.WithWebHostBuilder(b => b.ConfigureTestServices(s => ...))`.
- Auth: register a test scheme — `services.AddAuthentication(o => { o.DefaultAuthenticateScheme = "Test"; o.DefaultChallengeScheme = "Test"; }).AddScheme<AuthenticationSchemeOptions, TestAuthHandler>("Test", _ => { })` where `TestAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>` returns a ticket with the desired claims. Use `CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false })` when asserting redirects/401s.

```csharp
[Fact]
public async Task Get_orders_returns_200()
{
    var client = api.CreateClient();
    var response = await client.GetAsync("/api/orders", TestContext.Current.CancellationToken);
    Assert.Equal(HttpStatusCode.OK, response.StatusCode);
}
```

### Respawn 7.x

```csharp
await using var conn = new NpgsqlConnection(connectionString);
await conn.OpenAsync(TestContext.Current.CancellationToken);
var respawner = await Respawner.CreateAsync(conn, new RespawnerOptions
{
    DbAdapter = DbAdapter.Postgres,
    TablesToIgnore = [new Table("__EFMigrationsHistory")],
});
await respawner.ResetAsync(conn); // between tests, not between runs
```

Respawn deletes data respecting FK order — orders of magnitude faster than dropping/recreating the database or container. Options: `TablesToIgnore`, `SchemasToInclude` / `SchemasToExclude`, `DbAdapter` (SqlServer, Postgres, MySql, Oracle, Informix). Ignore the migrations-history table so you don't re-migrate every test.

### Microsoft's unit-test guidance (learn.microsoft.com)

- Naming has three parts: *method under test*, *scenario*, *expected behavior* — `Add_SingleNumber_ReturnsSameNumber`. SKILL.md's `Method_condition_expectedResult` is the same convention.
- Arrange-Act-Assert with the three phases visually separated; **one Act per test** — use `[Theory]` + `[InlineData]` for input matrices instead of loops or multiple acts.
- Good tests are Fast, Isolated, Repeatable, Self-checking, Timely. No infrastructure dependencies in *unit* tests (that's what the integration project is for).
- Write *minimally passing* tests (simplest input that proves the behavior); no magic strings (name constants); **no logic** (`if`/`for`/string concatenation) inside tests; prefer helper/factory methods over setup/teardown state.
- Don't test private methods — test through the public method that uses them. Stub static seams (`DateTime.Now`) behind an abstraction: in modern .NET that's `TimeProvider` + `FakeTimeProvider`.
- Terminology: a *stub* supplies data, a *mock* is what you assert against. Calling a stub a mock misleads readers — in NSubstitute terms, `Returns(...)` configures a stub; only where you `Received()` is it a mock.

### NSubstitute

```csharp
var pricing = Substitute.For<IPricingPort>();
pricing.GetPriceAsync(Arg.Any<int>(), Arg.Any<CancellationToken>())
       .Returns(new Price(Amount: 42m, Currency: "EUR"));   // Task<T> configured directly

var handler = new CreateOrderHandler(pricing);
var result = await handler.HandleAsync(new CreateOrder(ProductId: 1, Qty: 2),
    TestContext.Current.CancellationToken);

Assert.Equal(84m, result.Total);                             // assert outcome, not interaction
```

`Returns(value)` / `Returns(x => ...)` / `Returns(v1, v2, v3)` for sequences; async methods take the result value directly. Match with `Arg.Any<T>()` and `Arg.Is<T>(predicate)`; raise events with `Raise.Event()`. Verify with `Received()` / `DidNotReceive()` — sparingly, per SKILL.md, only for ports with no observable outcome. Substitute **interfaces**; the docs warn substituting classes with non-virtual or `internal virtual` members silently runs real code — the analyzers package turns that into a compile-time diagnostic.

### Snapshot testing and code coverage

- Snapshot/approval testing is **not covered by official xUnit or Microsoft docs** as of July 2026; the community standard is the Verify library. Treat it as optional and verify its API against its own repo before use.
- Coverage under MTP: `Microsoft.Testing.Extensions.CodeCoverage` (auto-registered by the MSBuild integration) → `dotnet test -- --coverage --coverage-output-format cobertura` (formats: `coverage`, `xml`, `cobertura`; note `IncludeTestAssembly` now defaults to `false`, unlike VSTest). Coverlet's MTP-native package is `coverlet.MTP` → `--coverlet --coverlet-output-format cobertura`. The old `coverlet.collector` is VSTest-only.

## Anti-patterns

| Anti-pattern | Why / Fix |
|---|---|
| `--filter "FullyQualifiedName~X"` (VSTest syntax) against an MTP runner | MTP uses its own flags: `--filter-class`, `--filter-method`, `--filter-trait`/`--filter-not-trait`, `--filter` query expressions. |
| Mixing v2 packages (`xunit`, `xunit.abstractions`, `xunit.console`) into a v3 project | v3 renames: `xunit` → `xunit.v3`, `xunit.core` → `xunit.v3.core`; `xunit.abstractions`/`xunit.console` are removed. |
| Cleanup in `Dispose()` when the class also implements `IAsyncLifetime`/`IAsyncDisposable` | v3 calls only `DisposeAsync()` when both exist — the `Dispose()` never runs. Put all cleanup in `DisposeAsync`. |
| `WithReuse(true)` as a performance fix inside one test run, or in CI | Reuse is experimental, disables the reaper, and docs say it's not a replacement for shared fixtures. Share via collection/assembly fixture instead. |
| Sleeping until a container is "probably" ready | Use module defaults or an explicit wait strategy (`UntilContainerIsHealthy`, `UntilCommandIsCompleted("pg_isready")`, HTTP readiness) — that's what they're for. |
| Forgetting `TestContext.Current.CancellationToken` in async calls | Timed-out/cancelled runs keep executing and hold containers open. Thread the token through HTTP, DB, and `StartAsync` calls. |
| Mocking `DbContext`/`IQueryable`, or the EF in-memory provider | Both lie about SQL semantics (translation, transactions, constraints). Testcontainers + the real provider; Respawn keeps it fast. (Microsoft's integration-test page suggests in-memory SQLite as a lighter option — this stack deliberately rejects that for MSSQL/Postgres apps, per SKILL.md.) |
| Substituting concrete classes with NSubstitute | Non-virtual members execute real code silently. Substitute interfaces; install `NSubstitute.Analyzers.CSharp`. |
| `Received()` as the primary assertion | Couples tests to implementation. Assert responses/DB state/published messages; reserve `Received()` for fire-and-forget ports. |
| Logic (`if`/`for`/concatenation) or multiple Act blocks in a test | Split into `[Theory]` cases — Microsoft's docs call this out explicitly. |
| New containers per test class | One fixture per collection (or assembly fixture), `Respawner.ResetAsync` between tests. |
| Chasing a coverage % target | Microsoft: high coverage ≠ quality and overly ambitious goals are counterproductive. Cover behavior per SKILL.md's definition of done. |

## Sources

- https://xunit.net/docs/getting-started/v3/getting-started
- https://xunit.net/docs/getting-started/v3/whats-new
- https://xunit.net/docs/getting-started/v3/migration
- https://xunit.net/docs/getting-started/v3/microsoft-testing-platform
- https://xunit.net/docs/running-tests-in-parallel
- https://xunit.net/docs/shared-context
- https://dotnet.testcontainers.org/
- https://dotnet.testcontainers.org/modules/
- https://dotnet.testcontainers.org/api/wait_strategies/
- https://dotnet.testcontainers.org/api/resource_reuse/
- https://nsubstitute.github.io/help/getting-started/
- https://github.com/jbogard/Respawn
- https://learn.microsoft.com/en-us/aspnet/core/test/integration-tests?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices
- https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-intro
- https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-code-coverage
- https://www.nuget.org/packages/xunit.v3 | /Testcontainers | /NSubstitute | /Respawn
