---
description: Scaffold a new full-stack solution — ASP.NET Core cookie-BFF + Angular + Docker + docs skeleton
argument-hint: <ProjectName> [postgres|mssql|sqlite] [--rabbitmq]
---

Arguments given: "$ARGUMENTS". The first token is the project name — if it is blank, ask me for the project name before doing anything (that is the one allowed question). Database: postgres, unless the arguments contain `mssql` or `sqlite`. Add RabbitMQ wiring only if the arguments contain `--rabbitmq`. Scaffold the solution in the current directory.

Load these skills first and follow them exactly: `aspnet-backend`, `bff-security`, `fusioncache-redis`, `data-access` plus the matching provider skill (`mssql`/`postgres`/`sqlite`), `docker-nginx-deploy`, `dotnet-testing`, `docs-maintenance` — plus `angular-new-app` and `angular-ngrx-state` for the frontend. Use my stack defaults throughout; do not ask configuration questions. When pinning package versions in `Directory.Packages.props` and `package.json`, check the current stable versions (nuget.org / npm / the official docs listed in the skills) instead of relying on memory.

Create:

1. **Solution layout**: `src/<Name>.Api` (net10.0 BFF host, feature folders, minimal APIs, ProblemDetails, health checks, OpenTelemetry stub, Serilog with bootstrap logger + `UseSerilogRequestLogging` + appsettings-driven config per `aspnet-backend`), `src/<Name>.Domain`, `tests/<Name>.Tests`, `tests/<Name>.IntegrationTests` (ApiFixture with Testcontainers + Respawn, one passing smoke test). Repo-root build files per `aspnet-backend`: `global.json` (SDK pin), `Directory.Build.props` (Nullable, ImplicitUsings, TreatWarningsAsErrors, LangVersion latest), `Directory.Packages.props` (central package management — all versions there, csproj references version-less), and `Directory.Build.rsp` containing at least `-maxcpucount`, `-nologo`, `-graph`.
2. **Auth**: cookie BFF exactly per `bff-security` — `__Host-session` cookie, 401/403 events, antiforgery + XSRF cookie middleware, rate-limited `/api/auth/login|logout|me` endpoints with a placeholder user store, `RequireAuthorization` by default.
3. **Caching**: FusionCache wired per `fusioncache-redis` (L1+L2+backplane, default entry options, `CacheKeys` class).
4. **Data**: DbContext pool for the chosen provider, one example entity + `IEntityTypeConfiguration`, initial migration, design-time factory.
5. **Frontend**: Angular latest LTS app in `web/` (standalone, signals, SCSS, routing), one example SignalStore, HttpClient with XSRF defaults, `/api/me`-driven auth guard + login page skeleton, Vitest configured, Prettier as a devDependency (the auto-format hook depends on it), Playwright with one smoke e2e.
6. **Hosting**: Dockerfile (multi-stage .NET+Angular, non-root), `compose.yaml` (app, db, redis[, rabbitmq], nginx, certbot) and `compose.override.yaml` for local dev (published DB/redis ports, no nginx/certbot), nginx conf per `docker-nginx-deploy`, `.env.example`, `.gitignore`, `.editorconfig`.
7. **Docs**: `docs/` skeleton per `docs-maintenance` (README index, architecture.md with Mermaid container diagram of exactly what was scaffolded, getting-started.md with real commands, security.md, deployment.md, ADR-0001 recording the stack choice) — all cross-referenced.
8. **Git**: `git init`, initial commit.

Then verify: `dotnet build` succeeds, `dotnet test` passes (the integration smoke test requires Docker — if it isn't running, start it and wait for readiness per `dotnet-testing`; only skip with an explicit note if it can't be started, never fake the result), `npm run build` succeeds in `web/`. Report what was created and the exact commands to run it locally.
