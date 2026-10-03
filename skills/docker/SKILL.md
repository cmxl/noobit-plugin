---
name: docker
description: Use when working with Docker — writing or optimizing Dockerfiles, slow builds, layer caching, image size, base image choice (chiseled/alpine/AOT), docker compose, healthchecks, container networking/secrets/hardening, database volume backup/restore, or redeploying services.
---

# Docker — fast builds, small images, production compose

## Overview

Everything Docker except the reverse proxy: cache-friendly multi-stage builds, small non-root images, and the production compose stack. Databases/Redis/RabbitMQ live on an `internal: true` backend network, never published. nginx, TLS, and Let's Encrypt live in `nginx-deploy`.

## .NET + Angular Dockerfile (multi-stage, cached, non-root)

```dockerfile
# syntax=docker/dockerfile:1
# build stages run natively on the build machine and cross-compile to the target arch
# exact SDK = global.json "version" (Renovate bumps both together)
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0.401 AS build
ARG TARGETARCH
WORKDIR /src
COPY global.json* nuget.config* Directory.*.props Directory.Build.targets* Directory.Build.rsp* ./
# every project's manifest + committed lock file, folder structure kept (covers App.Api's project references)
COPY --parents src/*/*.csproj src/*/packages.lock.json ./
# RID-less locked restore: <RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers> in
# Directory.Build.props already puts both RIDs in the graph; `restore -r` here fails NU1004
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet restore src/App.Api/App.Api.csproj --locked-mode
COPY src/ src/
# no --no-restore: packages live only in the cache mount (rules below); this implicit restore is
# locked too and a no-op when the mount is warm
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish src/App.Api/App.Api.csproj -c Release -a $TARGETARCH -p:RestoreLockedMode=true -o /app /p:UseAppHost=false

FROM --platform=$BUILDPLATFORM node:24-slim AS ngbuild
WORKDIR /web
COPY web/package*.json ./
RUN --mount=type=cache,id=npm,target=/root/.npm npm ci
COPY web/ ./
RUN npm run build -- --configuration production

# exact runtime patch: rebuilding the same commit yields the same runtime
FROM mcr.microsoft.com/dotnet/aspnet:10.0.12 AS final
# this RUN executes on the TARGET arch — cross-building it needs QEMU/binfmt (see below)
# aspnet images ship with NEITHER wget NOR curl — install one or the HEALTHCHECK reports unhealthy forever
RUN apt-get update && apt-get install -y --no-install-recommends wget && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
# adjust "app" to the Angular project name
# (Dockerfile comments must be on their own line — a trailing "# ..." becomes extra arguments)
COPY --from=ngbuild /web/dist/app/browser wwwroot/
# non-root
USER $APP_UID
EXPOSE 8080
# /health/ready: compose gates depends_on/--wait on it; Docker never restarts an unhealthy container
# sends Host: localhost - keep `localhost` in AllowedHosts or host filtering answers 400 (aspnet-backend)
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s CMD wget -qO- http://localhost:8080/health/ready || exit 1
ENTRYPOINT ["dotnet", "App.Api.dll"]
```

Build-performance rules baked into that file — these are the point, not decoration:

- **Manifest-first COPY order**, least→most frequently changing: build-config files (`global.json`, `nuget.config`, `Directory.*.props`, `Directory.Build.targets` — MSBuild imports all of them when it evaluates the project for restore; under central package management ALL versions live in `Directory.Packages.props`), then csproj manifests **plus their committed `packages.lock.json`**, then `dotnet restore --locked-mode`, then sources. A source edit re-runs only publish; restore stays layer-cached. Same shape for npm: `package*.json` → `npm ci` → sources. (`.config/dotnet-tools.json` stays out: the image runs no `dotnet tool restore` — the migration bundle is built in CI.)
- **Locked restore is RID-less; publish keeps its implicit restore.** `<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>` in `Directory.Build.props` (all projects, `aspnet-backend`) makes the plain restore resolve both RIDs, so `publish -a $TARGETARCH` matches the lock files on either target. `dotnet restore -r <rid> --locked-mode` replaces that list and fails NU1004. `--no-restore` on publish fails NETSDK1064 whenever the restore layer is a cache hit but the mount is empty (fresh CI runner with `--cache-from`, `docker builder prune`); `-p:RestoreLockedMode=true` keeps the implicit restore locked instead. All three verified against a two-project net10 solution (amd64 + arm64).
- **Cache mounts are the default, not a CI extra.** `--mount=type=cache` keeps the NuGet/npm download caches across builds even when the restore layer itself is invalidated (csproj/package.json change): packages are re-resolved but not re-downloaded. `id=` shares one cache across Dockerfiles. Details and apt-cache variant: [references/best-practices.md](references/best-practices.md).
- **Cross-arch builds.** Without `--platform=$BUILDPLATFORM` + `-a $TARGETARCH`, an arm64 dev box (Apple Silicon) builds an arm64 image that won't run on an amd64 server. The build stages run natively and cross-compile (the dotnet-docker samples' pattern); the Angular output is architecture-neutral. Choose the target with `docker build --platform linux/amd64 .`. The final stage's `RUN apt-get …` still executes *on the target arch*: Docker Desktop emulates it with its bundled QEMU; a plain Linux builder needs binfmt registered once (`docker run --privileged --rm tonistiigi/binfmt --install all`) — or keep `RUN` out of the final stage (chiseled + external probe) and no emulation is needed.
- **Independent stages build in parallel.** BuildKit runs the .NET and Angular stages concurrently and rebuilds only the stage whose inputs changed. Node is a build stage only; the runtime image never contains node.
- `COPY --parents src/*/*.csproj src/*/packages.lock.json ./` copies every project's manifests in one line and keeps the folder structure (`src/**/…` for nested layouts); explicit `COPY src/X/X.csproj src/X/packages.lock.json src/X/` lines work too but must list every referenced project; details in [references/best-practices.md](references/best-practices.md).

**pnpm instead of npm** (Node 24 still bundles corepack — from Node 25 on it must be installed: `npm i -g corepack`):

```dockerfile
FROM --platform=$BUILDPLATFORM node:24-slim AS ngbuild
# activates the pnpm version pinned in package.json "packageManager"
RUN corepack enable
WORKDIR /web
COPY web/package.json web/pnpm-lock.yaml web/pnpm-workspace.yaml* ./
# fetch needs only the lockfile → this layer survives every source edit
RUN --mount=type=cache,id=pnpm,target=/var/cache/pnpm pnpm fetch --store-dir /var/cache/pnpm
COPY web/ ./
RUN --mount=type=cache,id=pnpm,target=/var/cache/pnpm \
    pnpm install --offline --frozen-lockfile --store-dir /var/cache/pnpm && pnpm run build --configuration production
```

## .dockerignore (always)

```
**/bin
**/obj
**/node_modules
**/dist
**/.angular
**/TestResults
**/*.pfx
**/.env*
.git
```

Patterns are matched from the **context root** (Go `filepath.Match` semantics): a bare `node_modules` excludes only `./node_modules`, not `web/node_modules` — so every directory pattern gets `**/`. `.env*` keeps local secrets out of the context (a committed `.env.example` isn't needed in the image either). Smaller build context and fewer spurious cache busts: a missing or root-only `.dockerignore` is the most common answer to "why did restore rebuild — I only ran the app locally" (local `bin/`/`obj/`/`node_modules` churn invalidates `COPY src/` / `COPY web/`).

## Image choice (size & startup)

| Situation | Image |
|---|---|
| Default; in-container debugging wanted | `aspnet:10.0.12` + `USER $APP_UID` |
| Hardened prod, no shell needed | `aspnet:10.0.12-noble-chiseled` |
| Chiseled but needs ICU/tzdata | `aspnet:10.0.12-noble-chiseled-extra` |
| Native AOT binary | `runtime-deps:10.0.12` final stage, `sdk:10.0.401-noble-aot` build stage |

**.NET tags are exact versions** (`sdk:10.0.401`, `aspnet:10.0.12`): the SDK tag must equal `global.json` (`"rollForward": "latestPatch"`, `ci-pipelines`), the runtime tag makes a rebuild reproducible. Renovate/Dependabot bump `global.json` and every .NET `FROM` in one PR — a floating `10.0` would silently change the SDK under `--locked-mode` (the Dockerfile's and CI's locked restore — it presupposes committed `packages.lock.json` files via `RestorePackagesWithLockFile` plus `<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>`, set up by `aspnet-backend`; see `ci-pipelines` rule 2). The SDK also implies package versions: `PublishAot` adds `Microsoft.DotNet.ILCompiler` at the SDK's runtime patch, so an SDK bump changes the lock file (verified). Third-party images stay on their compatibility line (references → pinning).

Chiseled/distroless: no shell, no package manager, non-root by default — drop the Dockerfile `HEALTHCHECK` (no wget and no shell to run it) and probe `/health/ready` externally, or copy in a tiny AOT probe binary and invoke it exec-form. Trimming / ReadyToRun / NativeAOT trade-offs (image size and cold start vs build time and compatibility): decision matrix in [references/best-practices.md](references/best-practices.md).

## Compose skeleton (reverse proxy not shown — see `nginx-deploy`)

```yaml
services:
  app:
    build: .
    restart: unless-stopped
    # .NET 8+ images already set ASPNETCORE_HTTP_PORTS=8080 — no ASPNETCORE_URLS needed
    environment:
      ConnectionStrings__Redis: redis:6379
      ForwardedHeaders__KnownNetwork: 172.28.0.0/16   # = the edge subnet below (nginx-deploy)
    secrets:   # mounted as /run/secrets/ConnectionStrings__Default → read via AddKeyPerFile (below)
      - { source: db_connection, target: ConnectionStrings__Default }   # DML-only role app_user
    read_only: true                          # image filesystem immutable at runtime
    tmpfs: [/tmp]                            # runtime temp: .NET diagnostics socket, Path.GetTempPath()
    cap_drop: [ALL]                          # non-root Kestrel on 8080 needs no capabilities
    security_opt: ["no-new-privileges:true"]
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    networks: [edge, backend]
    logging: { driver: local }
  # migrate: one-shot EF bundle job, profiles: [tools] — canonical definition in data-access →
  # references/migrations-ci.md (schema-owner secret db_schema_owner, backend network)
  db:
    image: postgres:18
    restart: unless-stopped
    volumes:
      - dbdata:/var/lib/postgresql             # 18+: data in /var/lib/postgresql/18/docker — mount the parent
      - ./db/initdb:/docker-entrypoint-initdb.d:ro   # creates app_owner (DDL) + app_user (DML), first start only
    environment:
      POSTGRES_DB: app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password   # superuser — admin/backup only, never the app
    secrets: [db_password, db_owner_password, db_app_password]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U postgres -d app"], interval: 10s }
    networks: [backend]
    logging: { driver: local }
  redis:
    image: redis:8
    restart: unless-stopped
    # cache only: evicts and has no persistence — never Data Protection keys or other must-keep data
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru", "--save", "", "--appendonly", "no"]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 10s }
    networks: [backend]
    logging: { driver: local }
networks:
  edge:       # nginx ↔ app; normal bridge, so the app keeps outbound internet (SMTP, external APIs)
    ipam:
      # fixed subnet → the app's trusted proxy network can name it exactly (nginx-deploy). Must be unique
      # per host (a second stack on the same host needs another one); change compose + app config together.
      config: [{ subnet: 172.28.0.0/16 }]
  backend:    # app ↔ db/redis/rabbit; no route off the host — a compromised db container can't phone home
    internal: true
secrets:      # gitignored files on the server, readable by the container users (app 1654, postgres 999)
  db_connection: { file: ./secrets/db_connection }       # Host=db;Database=app;Username=app_user;Password=…
  db_schema_owner: { file: ./secrets/db_schema_owner }   # same with app_owner — used only by `migrate`
  db_password: { file: ./secrets/db_password }
  db_owner_password: { file: ./secrets/db_owner_password }
  db_app_password: { file: ./secrets/db_app_password }
volumes: { dbdata: {} }
```

App side of the secret — one line, right after `CreateBuilder`:
`builder.Configuration.AddKeyPerFile("/run/secrets", optional: true);`
(`Microsoft.Extensions.Configuration.KeyPerFile` ships in the ASP.NET Core shared framework; `__` in a
file name becomes `:`). Added last, it overrides every source `CreateBuilder` registered —
appsettings, environment variables **and command-line args**.

**Database roles:** two identities, created once by `db/initdb/10-roles.sh` (Postgres init hook; script,
SQL Server equivalent and why: [references/best-practices.md](references/best-practices.md#database-roles-schema-owner-vs-app)) —
`app_owner` owns the schema and is used only by the `migrate` job; `app_user` gets DML through default
privileges and is what the app connects as. The superuser (`db_password`) is for admin and backups.

Rules for the rest of the stack (rationale in [references/best-practices.md](references/best-practices.md#compose-in-production-compose-docs)):

- **Hardening on the app only:** `read_only` + `tmpfs: [/tmp]` + `cap_drop: [ALL]` + `no-new-privileges`.
  Anything the app writes goes to an explicit volume or `tmpfs`; Data Protection keys live in the
  database (`PersistKeysToDbContext`, `bff-security`) — with `PersistKeysToFileSystem`, mount a volume.
- **Secrets:** compose `secrets:` files (above); `.env` holds non-secrets only (`REGISTRY`, `APP_TAG`,
  `COMPOSE_PROFILES`) — never in the compose file or image.
- **Ports:** only nginx publishes (80/443) — never db/redis/rabbit. In production the nginx + certbot
  services from `nginx-deploy` join this file (nginx on `edge` only).
- **Profiles:** `prod` = nginx + certbot (server `.env`: `COMPOSE_PROFILES=prod`; an overlay can't
  remove services, a profile keeps them off dev machines); `tools` = one-shot jobs run only via
  `docker compose run --rm <job>` (`migrate`); `ops` = optional long-running sidecars (pgadmin, backup).
- **Local dev overrides** live in `compose.dev.yaml` (published db/redis ports, bind mounts, plus
  `networks: { backend: { internal: false } }` — an internal network's ports aren't reachable from the
  host), loaded via `COMPOSE_FILE=compose.yaml:compose.dev.yaml` (`;` on Windows) in the developer's
  gitignored `.env` (`.env.example` ships it commented). Never `compose.override.yaml` — it is
  auto-loaded on the server too if ever copied there.
- **Postgres 18 volume path:** the 18 entrypoint refuses an old-layout volume
  (`/var/lib/postgresql/data` from `postgres:17`). A major upgrade is always dump/restore or `pg_upgrade`
  — never just a tag bump.
- **Log rotation:** every service gets `logging: { driver: local }` — the default `json-file` never rotates.
- **RabbitMQ** when needed: `rabbitmq:4-management` on `backend`, health `rabbitmq-diagnostics -q ping`;
  management UI only via a localhost port in `compose.dev.yaml`.
- **Backups:** a named volume is not a backup — scheduled dump, off-host copy, restore drill:
  [references/best-practices.md](references/best-practices.md#backup-and-restore-of-database-volumes).

## Fast redeploy (one service, the rest keep running)

```bash
docker compose build app && docker compose up --no-deps -d app
```

`app` itself is still recreated — seconds of downtime for it (nginx answers 502 meanwhile); true zero-downtime needs a second instance behind the proxy. `--no-deps` is the point: without it `up app` also recreates any dependency whose config or image changed (a bumped `postgres` tag restarts the database). Compose only recreates containers whose config or image changed, so `up --build` is no blanket restart — but it rebuilds every service with a `build:` section.

## Finding slow or cache-busting layers

- `docker build --progress=plain .` — shows each step as `CACHED` or executing; the first non-cached step is your cache-buster.
- `docker buildx du` — build-cache disk usage; `docker builder prune` when it bloats.
- `docker history <image>` — layer sizes, find what to slim.

## Common mistakes

| Mistake | Fix |
|---|---|
| Copying the whole repo before `dotnet restore`/`npm ci` | Manifest-first COPY ordering (Dockerfile above) |
| `dotnet restore -a $TARGETARCH` / no `--locked-mode` / lock files not copied | RID-less `restore --locked-mode` after copying `packages.lock.json`; RID only on publish |
| `apt-get update` in its own `RUN` | Combine with install + `rm -rf /var/lib/apt/lists/*` in one layer (unless using the apt cache-mount variant — see references) |
| No `.dockerignore`, or root-only patterns (`node_modules`) | `**/`-prefixed patterns (list above) — bare names match only at the context root |
| Secrets as `ENV`/`ARG` in the Dockerfile | Persist in image history — runtime env or compose `secrets:` |
| `latest` / floating .NET tags | .NET: exact tags matching `global.json` (`sdk:10.0.401`, `aspnet:10.0.12`); others their compatibility line (`postgres:18`, `node:24-slim`); digest-pin for supply-chain safety |
| Running as root | `USER $APP_UID`; writable paths mounted explicitly |
| Publishing db/redis/rabbit ports to host | `backend` (`internal: true`) network only; `ports:` solely on the reverse proxy |
| One flat network with `internal: true` | Cuts nginx/app egress too — two networks: `edge` (nginx + app) and internal `backend` |
| Connection string with password in `environment:` | Compose `secrets:` + `AddKeyPerFile("/run/secrets")`; `docker inspect` shows env vars |
| No healthchecks | Every long-running service defines one (certbot's renew loop is exempt — nothing depends on it); `depends_on.condition: service_healthy`; no sleep hacks |
| No `--start-period` on the app healthcheck | Cold start counts failed probes against `--retries` → container marked unhealthy, so `up --wait` and `depends_on: service_healthy` dependents fail; set it beyond worst-case cold start |
| `docker compose up` rebuilding everything per change | `docker compose build app && docker compose up --no-deps -d app` |
| App never turns healthy although `/health/ready` works from outside | `AllowedHosts` lists only the public hostname: the in-container probe sends `Host: localhost` and gets 400 — add `localhost` (`app.example.com;localhost`) |
| Default `json-file` log driver | Never rotates → full disk; `logging: { driver: local }` per service |
| Image built on an arm64 Mac, deployed to amd64 | `FROM --platform=$BUILDPLATFORM` build stages + `-a $TARGETARCH` |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- Docker build (BuildKit, cache): https://docs.docker.com/build/ (best practices: https://docs.docker.com/build/building/best-practices/)
- Compose: https://docs.docker.com/compose/
- Official .NET images: https://github.com/dotnet/dotnet-docker
- .NET trimming/AOT/containers: https://learn.microsoft.com/en-us/dotnet/core/deploying/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
