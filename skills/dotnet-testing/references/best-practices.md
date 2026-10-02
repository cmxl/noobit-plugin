# .NET Testing Best Practices — xUnit v3 + Testcontainers

Verified against official documentation and a compiled + executed sample (xUnit 4.0.1, SDK 10.0.400, Docker), October 2026. Primary sources: xunit.net (v3 getting started, 4.0.0 release notes, MTP integration, code coverage with MTP, parallelism, runner config), dotnet.testcontainers.org (incl. xUnit.net integration, CI/CD), learn.microsoft.com (`dotnet test` MTP mode, integration tests, unit testing best practices, EF Core testing strategy), github.com/nsubstitute/NSubstitute/releases, github.com/jbogard/Respawn, nuget.org version pages. Extends `SKILL.md`; conventions there (real infra via Testcontainers, no mocked DbContext, no InMemory/SQLite stand-in) apply to every sample here.

## Current versions (October 2026)

| Package | Stable | Notes |
|---|---|---|
| `xunit.v3` | **4.0.1** (2026-09-12; 4.0.0 on 2026-08-15) | 4.x is **MTP v2 only** — MTP v1 support and the `xunit.v3.mtp-v1` variants are gone (they only exist for 3.x); remaining variants: `xunit.v3` (= MTP v2), `xunit.v3.mtp-v2`, `xunit.v3.mtp-off` (no MTP at all — only for exotic runners). Mono is no longer supported. Breaking for config: see *Parallelism model*. |
| Microsoft.Testing.Platform (MTP) | **2.4.x** (pulled in by `xunit.v3` 4.0.1) | Microsoft's VSTest replacement; `Microsoft.Testing.Platform.MSBuild` (transitive) auto-registers extension packages. |
| `Microsoft.Testing.Extensions.CodeCoverage` | **18.11.2** | 18.x targets MTP v2 (18.11.2 depends on MTP ≥ 2.4.0, matching xUnit 4.0.1). Don't pair it with MTP v1. |
| `xunit.runner.visualstudio` | 4.0.0 | Only for the legacy VSTest path (with `Microsoft.NET.Test.Sdk`). Not needed for MTP + SDK 10. |
| `Testcontainers` (+ modules) | **4.15.0** (2026-09-06) | Modules: `Testcontainers.PostgreSql`, `.MsSql`, `.Redis`, `.RabbitMq`, … `Testcontainers.XunitV3` 4.15.0 — verified working on xUnit 4.0.1 (it declares a 3.2.2 minimum). |
| `NSubstitute` | **6.2.0** (6.0.0 GA 2026-07-12) | 6.0: targets .NET 8 + netstandard2.0, legacy obsolete APIs removed, `CompatArg` obsolete. 6.0 turned on nullable annotations; **6.1 reverted them** — don't chase 6.0-era nullability warnings, upgrade. |
| `NSubstitute.Analyzers.CSharp` | 1.0.17 | Always add (`PrivateAssets="all"`). |
| `Respawn` | **7.0.0** (2025-11-30) | Adapters: SqlServer, Postgres, MySql, Oracle, Informix. |
| `Microsoft.AspNetCore.Mvc.Testing` | 10.0.x (10.0.12) | Match the app's ASP.NET Core major; 11.0 is still RC. |
| `Microsoft.Extensions.TimeProvider.Testing` | 10.10.0 | `FakeTimeProvider`. |

## Established patterns

### Project setup (xUnit v3 4.x, .NET 10)

v3 test projects are stand-alone executables — `OutputType` must be `Exe`, and `xunit.v3` replaces the v2 `xunit` package (`xunit.abstractions` is gone; `ITestOutputHelper` now lives in `Xunit`). Versions go in `Directory.Packages.props` (central package management, per `aspnet-backend`); the package does not add a global `using Xunit;` — the `<Using>` item does (the `xunit3` template adds the same).

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <UseMicrosoftTestingPlatformRunner>true</UseMicrosoftTestingPlatformRunner>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit.v3" />                                  <!-- 4.0.1 -->
    <PackageReference Include="NSubstitute" />                               <!-- 6.2.0 -->
    <PackageReference Include="NSubstitute.Analyzers.CSharp" PrivateAssets="all" />
    <PackageReference Include="Microsoft.Extensions.TimeProvider.Testing" />
    <PackageReference Include="Microsoft.Testing.Extensions.CodeCoverage" /> <!-- 18.11.2 -->
  </ItemGroup>
  <ItemGroup>
    <Using Include="Xunit" />
    <Content Include="xunit.runner.json" CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
</Project>
```

`global.json` (repo root, see `aspnet-backend`) switches SDK 10's `dotnet test` into MTP mode:

```json
{
  "sdk": { "version": "10.0.100", "rollForward": "latestFeature" },
  "test": { "runner": "Microsoft.Testing.Platform" }
}
```

SDK 8/9 only: instead set `<TestingPlatformDotnetTestSupport>true</TestingPlatformDotnetTestSupport>` (VSTest-bridge mode). When migrating to SDK 10 MTP mode, remove it along with `TestingPlatformCaptureOutput` / `TestingPlatformShowTestsFailure`.

### Running tests (`dotnet test` on SDK 10)

In MTP mode, test-app options go directly on `dotnet test`; `--` is optional (keep it only to separate app args unambiguously in scripts):

```
dotnet test --solution Shop.slnx                              # was: dotnet test Shop.slnx
dotnet test --project tests/Orders.Tests                      # was: dotnet test tests/Orders.Tests
dotnet test --filter-not-trait "Category=Integration"
dotnet test --filter-class Orders.Tests.PriceCalculatorTests
dotnet test --coverage --coverage-output-format cobertura
dotnet test --report-xunit-trx --report-xunit-junit --results-directory TestResults
```

- Filters: `--filter-class`, `--filter-method`, `--filter-namespace`, `--filter-trait` and their `--filter-not-*` twins (several values per switch: `--filter-class Foo Bar`), `--filter-query` (query language). xUnit 4 also accepts a single VSTest-syntax `--filter "FullyQualifiedName~X"`, but it can't be combined with the other filter kinds — prefer the native flags.
- Reports (xUnit 4 names, verified via `dotnet test -?`): `--report-xunit-trx`, `--report-xunit-junit`, `--report-xunit-xml`, `--report-xunit-html`, `--report-xunit-ctrf`, `--report-xunit-nunit`, `--report-xunit-markdown`, each with a `-filename` variant (filename only, no path). The xunit.net MTP page still shows the 3.x names `--report-junit` / `--report-xunit` — on 4.x those fail with exit code 5.
- Exit code **5** = an option some test app didn't recognize. In a solution, every targeted project must understand every flag: `--coverage` fails for projects without the CodeCoverage package. Either reference the extension in all test projects (e.g. via `Directory.Build.props`) or route args per project with the `TestingPlatformCommandLineArguments` MSBuild property.
- Other entry points: `dotnet run --project X` (args after `--`), or the built executable directly. `--xunit-info` adds xUnit-style verbose output.

`xunit.runner.json` (copied to output) holds runner config — 4.x keys:

```json
{
  "$schema": "https://xunit.net/schema/current/xunit.runner.schema.json",
  "parallelMode": "collections",
  "parallelAlgorithm": "conservative",
  "maxParallelThreads": "default",
  "stopOnFail": false
}
```

### Parallelism model

- Unit of parallelism is the **test collection**. Default: one collection per class → tests in a class run sequentially, classes run in parallel. All classes sharing a `[Collection("name")]` run sequentially with respect to each other.
- **xUnit 4.0 moved assembly-level settings to `[assembly: Parallelization]`** (namespace `Xunit.v3`; enums `ParallelMode`/`ParallelAlgorithm` in `Xunit.Sdk`). The old `CollectionBehavior` properties `DisableTestParallelization`, `MaxParallelThreads`, `ParallelAlgorithm` are `[Obsolete(error: true)]` — **compile error CS0619** on 4.x. `CollectionBehavior(CollectionBehavior.CollectionPerAssembly)` itself still works.

```csharp
using Xunit.Sdk;
using Xunit.v3;

[assembly: Parallelization(Mode = ParallelMode.Collections, Algorithm = ParallelAlgorithm.Conservative)]
// ParallelMode.None = fully sequential; ParallelMode.All (new in 4.0) = also parallelize tests inside a class.
// MaxThreads: 0/unset = Environment.ProcessorCount, negative = unlimited.
```

- `xunit.runner.json`: `parallelMode` (`none` / `collections` / `all`) replaces `parallelizeTestCollections` (still read, mapped to `parallelMode`). Command line: `--parallel`, `--max-threads`, `--parallel-algorithm`.
- Default algorithm is **conservative** (since 2.8): starts at most max-threads tests and waits for completions — accurate `Timeout` behavior. `aggressive` restores the old scheduling (better CPU use for async-heavy suites, worse timing accuracy).
- `[CollectionDefinition(..., DisableParallelization = true)]` serializes one collection against *all others* in the assembly. The integration project doesn't need it: its tests share one collection (already sequential) and unit tests live in a separate assembly. Use it only when another collection in the same assembly touches the same container/DB.

### Fixtures and lifecycle in v3

- `IAsyncLifetime` **changed in v3**: both members return `ValueTask`, and the interface now inherits `IAsyncDisposable`. When a class implements both `IAsyncDisposable` and `IDisposable`, v3 calls **only** `DisposeAsync()` — don't put cleanup in `Dispose()` as a fallback.
- Hierarchy: constructor/`IAsyncLifetime` per test → `IClassFixture<T>` per class → `ICollectionFixture<T>` per collection (`[CollectionDefinition]` must live in the test assembly) → **assembly fixtures**: `[assembly: AssemblyFixture(typeof(PostgresFixture))]` (4.0 adds generic `AssemblyFixture<T>`), created once before any test, injected via constructor, runs alongside parallel tests. For "start containers once for the whole suite", an assembly fixture is the v3-native option; a collection fixture (as in SKILL.md) is right when the suite should also be serialized against one shared DB.
- `TestContext.Current` exposes `CancellationToken`, `SendDiagnosticMessage`, `AddAttachment`, `AddWarning`, `KeyValueStorage`; also injectable as `ITestContextAccessor`. Pass `TestContext.Current.CancellationToken` to every async call so cancelled/timed-out runs stop promptly (analyzer **xUnit1051**).
- Dynamic skip: `Assert.Skip(reason)`, `Assert.SkipUnless(cond, reason)`, `Assert.SkipWhen(cond, reason)`, plus `SkipUnless`/`SkipWhen`/`Explicit` on `[Fact]`/`[Theory]` — for genuine environment preconditions (OS-specific behavior, a licensed external sandbox). **Not** for "Docker isn't running": per SKILL.md, start Docker; a run where Docker can't be started is reported as such, never silently skipped.
- 4.0 extensibility breaks (custom `ITestCaseOrderer` now sits under new class/method orderers, runner-context constructor changes) only matter for framework extensions — re-check those against the 4.0.0 release notes when upgrading.

```csharp
// v3 assembly fixture: one container for the whole assembly, tests stay parallel.
[assembly: AssemblyFixture(typeof(PostgresFixture))]

public sealed class PostgresFixture : IAsyncLifetime
{
    public PostgreSqlContainer Db { get; } = new PostgreSqlBuilder("postgres:18").Build();

    public async ValueTask InitializeAsync() =>
        await Db.StartAsync(TestContext.Current.CancellationToken);

    public async ValueTask DisposeAsync() => await Db.DisposeAsync();
}

public sealed class OrderQueriesTests(PostgresFixture postgres) // injected, no attribute needed
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

- Prefer module packages over raw `ContainerBuilder` — they ship "pre-configured with best practices" (correct image, wait strategy, `GetConnectionString()`): `new PostgreSqlBuilder("postgres:18").Build()`, then `await container.StartAsync(TestContext.Current.CancellationToken);`.
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

### Testcontainers.XunitV3 (optional base classes)

The official xUnit v3 integration package removes the start/dispose boilerplate for **non-WebApplicationFactory** tests (repository/query tests, raw ADO.NET): `ContainerTest<TBuilder, TContainer>` (container per test), `ContainerFixture<TBuilder, TContainer>` (shared via `IClassFixture`, needs `IMessageSink`), and `DbContainerTest` / `DbContainerFixture` for ADO.NET (`DbProviderFactory` + `OpenConnectionAsync()`). For API tests keep the `ApiFixture` from SKILL.md — it has to own the factory, migrations and Respawn anyway.

```csharp
public sealed class PgFixture(IMessageSink sink)
    : DbContainerFixture<PostgreSqlBuilder, PostgreSqlContainer>(sink)
{
    protected override PostgreSqlBuilder Configure() => new("postgres:18"); // pin the image
    public override DbProviderFactory DbProviderFactory => NpgsqlFactory.Instance;
}

public sealed class SqlSmokeTests(PgFixture db) : IClassFixture<PgFixture>
{
    [Fact]
    public async Task Database_answers()
    {
        await using var conn = await db.OpenConnectionAsync();
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1";
        Assert.Equal(1, await cmd.ExecuteScalarAsync(TestContext.Current.CancellationToken));
    }
}
```

### WebApplicationFactory + xUnit v3

- `Microsoft.AspNetCore.Mvc.Testing`; expose the entry point with `public partial class Program;` at the bottom of `Program.cs`.
- `WebApplicationFactory<Program>` implements `IAsyncDisposable` with a `ValueTask DisposeAsync()` — this composes cleanly with v3's `ValueTask`-based `IAsyncLifetime` (override `DisposeAsync`, call `base.DisposeAsync()`, then dispose containers), exactly as the `ApiFixture` in SKILL.md does.
- Order inside `InitializeAsync`: start containers → first `Services`/`Server` access (boots the app with the container connection strings from `ConfigureWebHost`/`UseSetting`) → `Database.MigrateAsync(ct)` in a scope → `Respawner.CreateAsync`. Per-test service overrides: `factory.WithWebHostBuilder(b => b.ConfigureTestServices(s => ...))`.
- Auth: register a test scheme — `services.AddAuthentication(o => { o.DefaultAuthenticateScheme = "Test"; o.DefaultChallengeScheme = "Test"; }).AddScheme<AuthenticationSchemeOptions, TestAuthHandler>("Test", _ => { })` where `TestAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>` returns a ticket with the desired claims. Use `CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false })` when asserting redirects/401s.
- Writes through a cookie-BFF API need the antiforgery header (`bff-security`). Put one helper on the
  fixture: fetch `/api/me` (it mints the `XSRF-TOKEN` cookie, even on 401) and send the value as
  `X-XSRF-TOKEN` on every request:

  ```csharp
  public async Task<HttpClient> CreateAuthenticatedClientAsync(CancellationToken ct)
  {
      var client = CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
      using var me = await client.GetAsync("/api/me", ct);       // TestAuthHandler → the test user
      var xsrf = me.Headers.GetValues("Set-Cookie")
          .Select(c => c.Split(';')[0])
          .Single(c => c.StartsWith("XSRF-TOKEN=", StringComparison.Ordinal))["XSRF-TOKEN=".Length..];
      client.DefaultRequestHeaders.Add("X-XSRF-TOKEN", Uri.UnescapeDataString(xsrf));
      return client;
  }
  ```

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

Respawn builds its delete plan from the **existing** schema at `CreateAsync` time — run migrations first, create the respawner once per fixture, reset per test. Ignore the migrations-history table (otherwise the next `MigrateAsync` re-applies everything into tables Respawn emptied). Options: `TablesToIgnore`, `SchemasToInclude` / `SchemasToExclude`, `DbAdapter`, `WithReseed` (SQL Server identity reseed). Deletion respects FK order — orders of magnitude faster than dropping/recreating the database or container. Pass an open `DbConnection` (Postgres sample in SKILL.md).

MSSQL (`Testcontainers.MsSql` + `Microsoft.Data.SqlClient`):

```csharp
public sealed class MsSqlFixture : IAsyncLifetime
{
    private readonly MsSqlContainer _db = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2025-latest").Build();
    private Respawner _respawner = default!;

    public string ConnectionString => _db.GetConnectionString();

    public async ValueTask InitializeAsync()
    {
        var ct = TestContext.Current.CancellationToken;
        await _db.StartAsync(ct);
        // apply schema here (Database.MigrateAsync(ct) via the app's DbContext) before CreateAsync
        await using var conn = new SqlConnection(ConnectionString);
        await conn.OpenAsync(ct);
        _respawner = await Respawner.CreateAsync(conn, new RespawnerOptions
        {
            DbAdapter = DbAdapter.SqlServer,
            TablesToIgnore = [new Table("__EFMigrationsHistory")],
            WithReseed = true,
        });
    }

    public async Task ResetAsync()
    {
        await using var conn = new SqlConnection(ConnectionString);
        await conn.OpenAsync(TestContext.Current.CancellationToken);
        await _respawner.ResetAsync(conn);
    }

    public async ValueTask DisposeAsync() => await _db.DisposeAsync();
}
```

Pin the SQL Server image to the production major (`2022-latest` vs `2025-latest`); the image is large, so pre-pull or cache it on CI agents.

### Asserting published RabbitMQ messages

Real broker, throwaway probe queue bound before the act, poll with a deadline (RabbitMQ.Client 7 async API). Exchange/queue topology, outbox and consumer design: `rabbitmq-messaging`.

```csharp
var ct = TestContext.Current.CancellationToken;
var factory = new ConnectionFactory { Uri = new Uri(rabbit.Broker.GetConnectionString()) }; // RabbitMqBuilder("rabbitmq:4.3-management")
await using var conn = await factory.CreateConnectionAsync(ct);
await using var channel = await conn.CreateChannelAsync(cancellationToken: ct);

// Arrange: server-named, exclusive, auto-delete queue — bound BEFORE the act, or the message is lost.
var probe = await channel.QueueDeclareAsync(cancellationToken: ct);
await channel.QueueBindAsync(probe.QueueName, "orders.events", "order.created", cancellationToken: ct); // {service}.events

// act — writes through the BFF need the antiforgery header (bff-security): GET /api/me first,
// then send the XSRF-TOKEN cookie value as X-XSRF-TOKEN (wrap this in a test-client helper)
await client.PostAsJsonAsync("/api/orders", new { productId = 1, qty = 2 }, ct);

using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
deadline.CancelAfter(TimeSpan.FromSeconds(10));
BasicGetResult? msg;
while ((msg = await channel.BasicGetAsync(probe.QueueName, autoAck: true, deadline.Token)) is null)
    await Task.Delay(50, deadline.Token);

var evt = JsonSerializer.Deserialize(msg.Body.Span, JsonCtx.Default.OrderCreated); // same contract as the publisher
Assert.Equal(2, evt!.Quantity);
```

With an outbox, the message appears only after the dispatcher runs — the deadline loop covers that; never replace it with a fixed delay.

### Microsoft's unit-test guidance (learn.microsoft.com)

- Naming has three parts: *method under test*, *scenario*, *expected behavior* — `Add_SingleNumber_ReturnsSameNumber`. SKILL.md's `Method_condition_expectedResult` is the same convention.
- Arrange-Act-Assert with the three phases visually separated; **one Act per test** — use `[Theory]` + `[InlineData]` for input matrices instead of loops or multiple acts.
- Good tests are Fast, Isolated, Repeatable, Self-checking, Timely. No infrastructure dependencies in *unit* tests (that's what the integration project is for).
- Write *minimally passing* tests (simplest input that proves the behavior); no magic strings (name constants); **no logic** (`if`/`for`/string concatenation) inside tests; prefer helper/factory methods over setup/teardown state.
- Don't test private methods — test through the public method that uses them. Stub static seams (`DateTime.Now`) behind an abstraction: in modern .NET that's `TimeProvider` + `FakeTimeProvider` (`new FakeTimeProvider(start)`, `.Advance(TimeSpan)`, `.SetUtcNow(...)`).
- Terminology: a *stub* supplies data, a *mock* is what you assert against. Calling a stub a mock misleads readers — in NSubstitute terms, `Returns(...)` configures a stub; only where you `Received()` is it a mock.

### NSubstitute 6

```csharp
var pricing = Substitute.For<IPricingPort>();
pricing.GetPriceAsync(Arg.Any<int>(), Arg.Any<CancellationToken>())
       .Returns(new Price(Amount: 42m, Currency: "EUR"));   // Task<T> configured directly

var handler = new CreateOrderHandler(pricing);
var result = await handler.HandleAsync(new CreateOrder(ProductId: 1, Qty: 2),
    TestContext.Current.CancellationToken);

Assert.Equal(84m, result.Total);                             // assert outcome, not interaction
```

`Returns(value)` / `Returns(x => ...)` / `Returns(v1, v2, v3)` for sequences; async methods take the result value directly. Match with `Arg.Any<T>()` and `Arg.Is<T>(predicate)`; raise events with `Raise.Event()`. Verify with `Received()` / `DidNotReceive()` — sparingly, per SKILL.md, only for ports with no observable outcome. Substitute **interfaces**; the docs warn substituting classes with non-virtual or `internal virtual` members silently runs real code — the analyzers package turns that into a compile-time diagnostic. Upgrading from 5.x: code using APIs marked obsolete in 5.x no longer compiles; `CompatArg` (pre-C# 7 matchers) is obsolete.

### Snapshot testing and code coverage

- Snapshot/approval testing is **not covered by official xUnit or Microsoft docs**; the community standard is the Verify library. Treat it as optional and verify its API against its own repo before use.
- Coverage under MTP: `Microsoft.Testing.Extensions.CodeCoverage` 18.x (MTP v2; auto-registered by the MSBuild integration) → `dotnet test --coverage --coverage-output-format cobertura` (formats: `coverage`, `xml`, `cobertura`; `--coverage-settings` for a settings file; `IncludeTestAssembly` defaults to `false`, unlike VSTest). Don't pass `--coverage-output` when testing several projects — each overwrites the previous; let MTP name the files and glob them. Coverlet's `coverlet.collector` is VSTest-only.

### CI

- Docker: Microsoft-hosted Azure Pipelines agents and GitHub-hosted runners have Docker ready — but their **Windows** images run the Windows engine and can't run Linux containers. Run integration tests on Linux agents (`ubuntu-latest`). Docker-in-Docker setups (GitLab) need `DOCKER_HOST`; never disable Ryuk except where the platform forbids it (Bitbucket).
- Results: `dotnet test --report-xunit-trx` (Azure DevOps `PublishTestResults@2` with `testResultsFormat: VSTest`) or `--report-xunit-junit` (GitHub/GitLab JUnit consumers); files land in `TestResults/` under each project's output, or `--results-directory`. Coverage: `--coverage --coverage-output-format cobertura`, then `PublishCodeCoverageResults@2` / ReportGenerator.
- Fail the build on zero tests: MTP exits with code 8 when no tests ran — don't add `--ignore-exit-code 8` globally.

## Anti-patterns

| Anti-pattern | Why / Fix |
|---|---|
| `dotnet test X.sln -- --filter-not-trait ...` on SDK 10 MTP mode | Positional paths are rejected (`--solution`/`--project`); `--` is unnecessary. The "after `--`" rule is the SDK 8/9 VSTest-bridge mode. |
| `xunit.v3.mtp-v1` / MTP v1 extensions with xUnit 4 | 4.x is MTP v2 only; the `mtp-v1` variants exist only for 3.x. Use `xunit.v3` and MTP v2 extension versions (CodeCoverage 18.x). |
| `[assembly: CollectionBehavior(DisableTestParallelization = true)]` / `MaxParallelThreads` / `ParallelAlgorithm` | CS0619 compile error on xUnit 4. Use `[assembly: Parallelization(Mode/MaxThreads/Algorithm)]`; JSON key `parallelMode`. |
| `--report-junit` / `--report-xunit` on xUnit 4 | Renamed to `--report-xunit-junit` / `--report-xunit-xml`; old names → exit code 5. |
| Mixing v2 packages (`xunit`, `xunit.abstractions`, `xunit.console`) into a v3 project | v3 renames: `xunit` → `xunit.v3`, `xunit.core` → `xunit.v3.core`; `xunit.abstractions`/`xunit.console` are removed. |
| Cleanup in `Dispose()` when the class also implements `IAsyncLifetime`/`IAsyncDisposable` | v3 calls only `DisposeAsync()` when both exist — the `Dispose()` never runs. Put all cleanup in `DisposeAsync`. |
| `Respawner.CreateAsync` before the schema exists, or without ignoring `__EFMigrationsHistory` | Empty plan (nothing gets reset) or wiped migration history. Migrate first; ignore the history table. |
| `WithReuse(true)` as a performance fix inside one test run, or in CI | Reuse is experimental, disables the reaper, and docs say it's not a replacement for shared fixtures. Share via collection/assembly fixture instead. |
| Sleeping until a container is "probably" ready | Use module defaults or an explicit wait strategy (`UntilContainerIsHealthy`, `UntilCommandIsCompleted("pg_isready")`, HTTP readiness) — that's what they're for. |
| Forgetting `TestContext.Current.CancellationToken` in async calls | Timed-out/cancelled runs keep executing and hold containers open. Thread the token through HTTP, `ReadFromJsonAsync`, DB, and `StartAsync` calls (xUnit1051). |
| `Assert.SkipUnless(dockerRunning, ...)` | Hides missing coverage. Start Docker (SKILL.md); report explicitly if it can't start. |
| Mocking `DbContext`/`IQueryable`, the EF InMemory provider, or SQLite in-memory as the test DB | EF Core's testing guidance: test against the production database system; InMemory is "highly discouraged"; SQLite differs (case sensitivity, provider functions, raw SQL). Testcontainers + the real provider; Respawn keeps it fast. (Microsoft's integration-test page suggests SQLite in-memory as a lighter option — this stack deliberately rejects that for MSSQL/Postgres apps.) |
| Substituting concrete classes with NSubstitute | Non-virtual members execute real code silently. Substitute interfaces; install `NSubstitute.Analyzers.CSharp`. |
| `Received()` as the primary assertion | Couples tests to implementation. Assert responses/DB state/published messages; reserve `Received()` for fire-and-forget ports. |
| Logic (`if`/`for`/concatenation) or multiple Act blocks in a test | Split into `[Theory]` cases — Microsoft's docs call this out explicitly. |
| New containers per test class | One fixture per collection (or assembly fixture), `Respawner.ResetAsync` between tests. |
| Chasing a coverage % target | Microsoft: high coverage ≠ quality and overly ambitious goals are counterproductive. Cover behavior per SKILL.md's definition of done. |

## Sources

- https://xunit.net/releases/v3/4.0.0
- https://xunit.net/docs/getting-started/v3/getting-started
- https://xunit.net/docs/getting-started/v3/whats-new
- https://xunit.net/docs/getting-started/v3/migration
- https://xunit.net/docs/getting-started/v3/microsoft-testing-platform
- https://xunit.net/docs/getting-started/v3/code-coverage-with-mtp
- https://xunit.net/docs/running-tests-in-parallel
- https://xunit.net/docs/config-xunit-runner-json
- https://xunit.net/docs/shared-context
- https://dotnet.testcontainers.org/
- https://dotnet.testcontainers.org/modules/
- https://dotnet.testcontainers.org/api/wait_strategies/
- https://dotnet.testcontainers.org/api/resource_reuse/
- https://dotnet.testcontainers.org/test_frameworks/xunit_net/
- https://dotnet.testcontainers.org/cicd/
- https://github.com/nsubstitute/NSubstitute/releases
- https://nsubstitute.github.io/help/getting-started/
- https://github.com/jbogard/Respawn
- https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-with-dotnet-test
- https://learn.microsoft.com/en-us/aspnet/core/test/integration-tests?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/dotnet/core/testing/unit-testing-best-practices
- https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-intro
- https://learn.microsoft.com/en-us/dotnet/core/testing/microsoft-testing-platform-code-coverage
- https://learn.microsoft.com/en-us/ef/core/testing/choosing-a-testing-strategy
- https://www.nuget.org/packages/xunit.v3 | /Testcontainers | /NSubstitute | /Respawn | /Microsoft.Testing.Extensions.CodeCoverage
