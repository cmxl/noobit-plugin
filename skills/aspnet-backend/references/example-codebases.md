# Enterprise-grade .NET example codebases

Verified July 2026 (repo activity, target framework, licensing). These are **study material**, not templates to copy wholesale. For our standard shape (full-stack web apps/services on this stack), our conventions win where an example conflicts (vertical slices, minimal APIs, DbContext-direct, no MediatR). For other application shapes — or codebases already following one of these examples' styles — weigh the example's own context instead of forcing house style (see the Scope section in CLAUDE.md). Each entry says what it's good for and what to ignore.

## Study these (active, current)

**dotnet/eShop** — https://github.com/dotnet/eShop — .NET 10, active; Microsoft's flagship cloud-native reference (successor to eShopOnContainers).
Study: microservices decomposition, integration events + outbox in the Ordering service, resilience wiring, real DDD aggregates.
Ignore: Aspire orchestration (we deploy Docker Compose + nginx), and its microservices scale for anything that fits one service.

**jasontaylordev/CleanArchitecture** — https://github.com/jasontaylordev/CleanArchitecture — .NET 10 with an Angular frontend option, active; the closest thing to an established fullstack .NET+Angular reference (there is no Microsoft-official one).
Study: solution organization, the Angular↔API integration shape, functional test setup.
Ignore: the MediatR pipeline — MediatR 13+ is commercially licensed (12.x stays Apache-2.0), and our stack doesn't use it; endpoints call services directly.

**ardalis/CleanArchitecture** — https://github.com/ardalis/CleanArchitecture — ASP.NET Core 10, active (v11).
Study: DDD building blocks — guard clauses, domain events, the Specification pattern *as a concept* for sharable query logic.
Ignore: the repository-over-EF ceremony as a default — our convention is DbContext directly in slices; reach for specifications only where query shapes are genuinely shared.

**davidfowl/AspNetCoreDiagnosticScenarios** — https://github.com/davidfowl/AspNetCoreDiagnosticScenarios — dormant since 2024 but still the canonical async/threading anti-pattern catalog (by ASP.NET Core's architect).
Study: every entry in AsyncGuidance.md — it's the long form of our "no sync-over-async" rules.
Caveat: predates .NET 9/10 idioms; no license file (read, don't vendor).

**microsoft/aspire + microsoft/aspire-samples** — https://github.com/dotnet/aspire-samples — very active; the official distributed-app reference surface in 2026 (now polyglot, versioned independently as 13.x).
Study: service defaults (resilience + OpenTelemetry wiring), health check conventions — the current official take even though we orchestrate with Compose instead.

**NimblePros/eShopOnWeb** — https://github.com/NimblePros/eShopOnWeb — ASP.NET Core 10, active; the maintained community continuation of the classic monolith reference.
Study: well-factored monolith shape for single-service apps. Razor-based, not SPA.

**nadirbad/VerticalSliceArchitecture** — https://github.com/nadirbad/VerticalSliceArchitecture — .NET 10 vertical slices + minimal APIs + EF Core, deliberately MediatR-free.
Study: the closest public template to this stack's conventions. Caveat: small community — treat as a worked example, not an authority.

## Do NOT cite as current (archived/frozen)

- **dotnet/eShopOnWeb** — archived Jan 2025 (stuck on .NET 8) → use the NimblePros fork.
- **dotnet-architecture/eShopOnContainers** — archived Nov 2023 (.NET 7) → superseded by dotnet/eShop.
- **learn.microsoft.com/dotnet/architecture eBooks** (microservices, modern web apps) — frozen ~2024 and tied to the archived repos. Concepts still teach well; version-specific practice does not.
- **dotnet/spa-templates** — archived Nov 2024; the Angular+ASP.NET Core story now lives in the learn.microsoft.com SPA docs and standalone Angular CLI projects (which is what we do: `web/` + BFF).

## How to use these

When designing something non-trivial (a new service boundary, an aggregate, an event flow), skim how dotnet/eShop or the matching example solved it, then translate into our conventions. When reviewing generated architecture, a divergence from *both* our skills *and* these references is a smell; a divergence from the references alone may just be our (deliberate) house style.
