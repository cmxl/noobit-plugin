---
name: docker
description: Use when working with Docker — writing or optimizing Dockerfiles, slow builds, layer caching, image size, base image choice (chiseled/alpine/AOT), docker compose, healthchecks, container networking/secrets, or redeploying services.
---

# Docker — fast builds, small images, production compose

## Overview

Everything Docker except the reverse proxy: cache-friendly multi-stage builds, small non-root images, and the production compose stack. Databases/Redis/RabbitMQ live on an internal compose network, never published. nginx, TLS, and Let's Encrypt live in `nginx-deploy`.

## .NET + Angular Dockerfile (multi-stage, cached, non-root)

```dockerfile
# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY global.json* nuget.config* Directory.*.props Directory.Build.rsp* ./
COPY src/App.Api/App.Api.csproj src/App.Api/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet restore src/App.Api/App.Api.csproj
COPY src/ src/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish src/App.Api/App.Api.csproj -c Release -o /app /p:UseAppHost=false

FROM node:22 AS ngbuild
WORKDIR /web
COPY web/package*.json ./
RUN --mount=type=cache,id=npm,target=/root/.npm npm ci
COPY web/ ./
RUN npm run build -- --configuration production

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
# aspnet images ship with NEITHER wget NOR curl — install one or the HEALTHCHECK reports unhealthy forever
RUN apt-get update && apt-get install -y --no-install-recommends wget && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
COPY --from=ngbuild /web/dist/app/browser wwwroot/   # adjust "app" to the Angular project name
USER $APP_UID                                        # non-root
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s CMD wget -qO- http://localhost:8080/health/live || exit 1
ENTRYPOINT ["dotnet", "App.Api.dll"]
```

Build-performance rules baked into that file — these are the point, not decoration:

- **Manifest-first COPY order**, least→most frequently changing: build-config files (`global.json`, `nuget.config`, `Directory.*.props` — under central package management ALL versions live in `Directory.Packages.props`), then csproj manifests, then `dotnet restore`, then sources. A source edit re-runs only publish; restore stays layer-cached. Same shape for npm: `package*.json` → `npm ci` → sources.
- **Cache mounts are the default, not a CI extra.** `--mount=type=cache` keeps the NuGet/npm download caches across builds even when the restore layer itself is invalidated (csproj/package.json change): packages are re-resolved but not re-downloaded. `id=` shares one cache across Dockerfiles. Details and apt-cache variant: [references/best-practices.md](references/best-practices.md).
- **Independent stages build in parallel.** BuildKit runs the .NET and Angular stages concurrently and rebuilds only the stage whose inputs changed. Node is a build stage only; the runtime image never contains node.
- Solutions with many projects: restore-layer patterns in [references/best-practices.md](references/best-practices.md).

## .dockerignore (always)

```
**/bin
**/obj
node_modules
dist
.git
```

Smaller build context and fewer spurious cache busts. A missing `.dockerignore` is the most common answer to "why did restore rebuild — I only ran the app locally" (local `bin/`/`obj/`/`node_modules` churn invalidates `COPY src/`).

## Image choice (size & startup)

| Situation | Image |
|---|---|
| Default; in-container debugging wanted | `aspnet:10.0` + `USER $APP_UID` |
| Hardened prod, no shell needed | `aspnet:10.0-noble-chiseled` |
| Chiseled but needs ICU/tzdata | `aspnet:10.0-noble-chiseled-extra` |
| Native AOT binary | `runtime-deps` final stage, SDK `-aot` build stage |

Chiseled/distroless: no shell, no package manager, non-root by default — drop the Dockerfile `HEALTHCHECK` (no wget and no shell to run it) and probe `/health` externally, or copy in a tiny AOT probe binary and invoke it exec-form. Trimming / ReadyToRun / NativeAOT trade-offs (image size and cold start vs build time and compatibility): decision matrix in [references/best-practices.md](references/best-practices.md).

## Compose skeleton (reverse proxy not shown — see `nginx-deploy`)

```yaml
services:
  app:
    build: .
    restart: unless-stopped
    environment:
      ASPNETCORE_URLS: http://+:8080
      ConnectionStrings__Default: ${DB_CONNECTION}
      ConnectionStrings__Redis: redis:6379
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    networks: [internal]
  db:
    image: postgres:17
    volumes: [dbdata:/var/lib/postgresql/data]
    environment: { POSTGRES_PASSWORD: ${DB_PASSWORD} }
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 10s }
    networks: [internal]
  redis:
    image: redis:8
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 10s }
    networks: [internal]
networks: { internal: {} }
volumes: { dbdata: {} }
```

In production the nginx + certbot services from `nginx-deploy` join this file; **only nginx publishes ports** (80/443) — never db/redis/rabbit. Secrets via a gitignored `.env` or compose `secrets:` — never in the compose file or image. RabbitMQ when needed: `rabbitmq:4-management`, health `rabbitmq-diagnostics -q ping`, management UI bound to localhost only.

## Fast redeploy (one service, no downtime for the rest)

```bash
docker compose build app && docker compose up --no-deps -d app
```

Never `docker compose up --build` for a one-service change — it evaluates and may bounce every service.

## Finding slow or cache-busting layers

- `docker build --progress=plain .` — shows each step as `CACHED` or executing; the first non-cached step is your cache-buster.
- `docker buildx du` — build-cache disk usage; `docker builder prune` when it bloats.
- `docker history <image>` — layer sizes, find what to slim.

## Common mistakes

| Mistake | Fix |
|---|---|
| Copying the whole repo before `dotnet restore`/`npm ci` | Manifest-first COPY ordering (Dockerfile above) |
| `apt-get update` in its own `RUN` | Combine with install + `rm -rf /var/lib/apt/lists/*` in one layer (unless using the apt cache-mount variant — see references) |
| No `.dockerignore` | `**/bin`, `**/obj`, `node_modules`, `dist`, `.git` |
| Secrets as `ENV`/`ARG` in the Dockerfile | Persist in image history — runtime env or compose `secrets:` |
| `latest` image tags in prod | Pin major.minor; digest-pin for supply-chain safety |
| Running as root | `USER $APP_UID`; writable paths mounted explicitly |
| Publishing db/redis/rabbit ports to host | Internal network only; `ports:` solely on the reverse proxy |
| No healthchecks | Every service defines one; `depends_on.condition: service_healthy`; no sleep hacks |
| No `--start-period` on the app healthcheck | Migrations/cold start marked unhealthy → restart loops |
| `docker compose up` rebuilding everything per change | `docker compose build app && docker compose up --no-deps -d app` |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- Docker build (BuildKit, cache): https://docs.docker.com/build/ (best practices: https://docs.docker.com/build/building/best-practices/)
- Compose: https://docs.docker.com/compose/
- Official .NET images: https://github.com/dotnet/dotnet-docker
- .NET trimming/AOT/containers: https://learn.microsoft.com/en-us/dotnet/core/deploying/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
