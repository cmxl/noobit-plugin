# Docker/nginx Skill Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `skills/docker-nginx-deploy` into a general `docker` skill (Dockerfiles, build performance, images, compose) and an nginx-only `nginx-deploy` skill (reverse proxy, TLS, Let's Encrypt), fixing every reference in one go.

**Architecture:** Two skills with keyword-disjoint descriptions. `docker` owns "an optimal image exists and the compose stack runs"; `nginx-deploy` owns "the stack is exposed to the internet through nginx with TLS". The old skill's reference file is split along the same line. Enforcement rides in a new `stack-reviewer` dimension, not a new agent.

**Tech Stack:** Markdown only (Claude Code plugin: skills, agents, commands). No code, no runtime tests — verification is grep-based consistency checks plus WebFetch fact-verification for new best-practices content.

**Spec:** `work/specs/2026-07-12-docker-nginx-skill-split-design.md`

## Global Constraints

- Skill names: `docker` and `nginx-deploy` (fully qualified `noobit:docker`, `noobit:nginx-deploy`).
- Trigger disjointness: "Dockerfile", "build", "image", "compose" appear only in `docker`'s frontmatter description; "nginx", "TLS", "Let's Encrypt", "proxy" only in `nginx-deploy`'s.
- Every factual claim added to a `references/best-practices.md` must be verified via WebFetch against an official source listed in that file, repo convention "Verified against official documentation, July 2026".
- CI cache backends get ONE pointer paragraph, never a full section (spec: out of scope).
- Ships as v1.5.0. English throughout. Commit after every task.
- After the last task, `grep -r "docker-nginx-deploy"` over the repo must hit only `.git/`, `work/specs/`, and `work/plans/`.

---

### Task 1: Create `skills/docker/SKILL.md`

**Files:**
- Create: `skills/docker/SKILL.md`

**Interfaces:**
- Produces: skill name `docker` referenced by Tasks 3–7 as `nginx-deploy`'s counterpart and by `noobit:docker` in commands/agents.

- [ ] **Step 1: Write the file with exactly this content**

````markdown
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
| `apt-get update` in its own `RUN` | Combine with install + `rm -rf /var/lib/apt/lists/*` in one layer |
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
````

- [ ] **Step 2: Verify trigger disjointness of the new description**

Run (from repo root, Git Bash):
```bash
sed -n '3p' skills/docker/SKILL.md | grep -iE 'nginx|tls|encrypt|proxy' && echo "FAIL: nginx words in docker description" || echo "OK"
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add skills/docker/SKILL.md
git commit -m "Add docker skill: builds, images, compose (split from docker-nginx-deploy)"
```

---

### Task 2: Create `skills/docker/references/best-practices.md`

**Files:**
- Create: `skills/docker/references/best-practices.md`
- Read (source material): `skills/docker-nginx-deploy/references/best-practices.md` (still at its old path until Task 3)

**Interfaces:**
- Consumes: the Docker-half sections of the old reference file (listed below).
- Produces: the file `skills/docker/SKILL.md` already links to.

- [ ] **Step 1: Carry over the Docker-half of the old reference file**

Copy these sections **verbatim** from `skills/docker-nginx-deploy/references/best-practices.md` into the new file (they were doc-verified this month; do not re-research them):

- From "Current versions (July 2026)": the three .NET bullets (".NET 10 is GA and LTS…", "Chiseled (distroless) variants are stable…", "Non-root…") and the Compose bullet ("the top-level `version:` key is obsolete…"). Drop the nginx, HTTP/3, and Let's Encrypt bullets (they stay in `nginx-deploy`).
- Section "Multi-stage builds and layer caching" — **with one edit**: replace the final bullet ("Optional speed-up for CI … Don't bother for simple single-host deploys.") with:
  > Cache mounts (`RUN --mount=type=cache,...` for NuGet/npm) are the default pattern here, not a CI-only extra — see the dedicated section below.
- Section "Image size and security: chiseled vs full images".
- Section "Health checks without a shell".
- Section "Compose in production".
- From "Anti-patterns": the rows for `version:` key, secrets as build args/ENV, `apt-get update` in its own RUN, copying the whole repo before restore, HEALTHCHECK wget on chiseled, assuming .NET 10 images are Debian, no `--start-period`, and `docker compose up` rebuilding everything. Drop the nginx/TLS/cert rows.
- From "Sources": the docs.docker.com and github.com/dotnet/dotnet-docker URLs. Drop nginx/letsencrypt/certbot/Mozilla URLs.

File header (replaces the old intro):

```markdown
# Best Practices: Docker builds, images, and compose for .NET + Angular

Verified against official documentation, July 2026. Sources: docs.docker.com (build best practices,
cache mounts, Dockerfile reference, Compose reference) and github.com/dotnet/dotnet-docker plus
learn.microsoft.com deployment docs. Full URL list at the bottom. This file extends SKILL.md — read
that first; nothing here overrides it. Reverse proxy, TLS, and Let's Encrypt: see the
`nginx-deploy` skill.
```

- [ ] **Step 2: Draft the four NEW sections, then verify every fact via WebFetch before keeping it**

Add the sections below. Each carries claims that MUST be checked against the listed URL (WebFetch); where the docs disagree with the draft, the docs win — update the text and keep the source link. Add every consulted URL to Sources.

**Section: Cache mounts in depth** (verify against https://docs.docker.com/build/cache/optimize/ and https://docs.docker.com/reference/dockerfile/#run---mounttypecache)

```markdown
### Cache mounts in depth

- `RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore ...` — the cache
  lives in builder storage (not in any layer), survives cache-busted rebuilds, and is shared
  across builds/Dockerfiles via `id`. Use the same mount on the `dotnet publish` step: restore
  writes into the mount, so publish must see it too.
- npm: mount the *download* cache (`target=/root/.npm`), never `node_modules` itself — `npm ci`
  deletes and recreates `node_modules`, which must land in the layer, not the mount.
- Concurrent builds sharing one cache: add `sharing=locked` (serializes writers) or per-build
  caches via distinct `id`s.
- apt variant for the runtime stage's wget install:
  `RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked apt-get update && apt-get install -y --no-install-recommends wget`
  (with cache mounts you skip the `rm -rf /var/lib/apt/lists/*` since lists live in the mount).
- Cache mounts are builder-local: `docker buildx du` shows them, `docker builder prune` clears
  them, and a fresh CI runner starts empty — which is why they are a *local/on-host* win first.
```

**Section: Restore layers in many-project solutions (CPM)** (verify the bind-mount restore shape against https://docs.docker.com/build/cache/optimize/ and https://docs.docker.com/reference/dockerfile/#run---mounttypebind)

```markdown
### Restore layers in many-project solutions (CPM)

- Under central package management, version bumps touch only `Directory.Packages.props` — copied
  in the first COPY — so the per-project csproj COPY list changes only when a project is added,
  removed, or gains a reference. Maintaining explicit `COPY src/X/X.csproj src/X/` lines is
  therefore cheap and stays the default; a glob like `COPY src/**/*.csproj` does NOT preserve the
  directory structure and silently breaks restore.
- Alternative that needs no csproj COPY list at all: restore from a bind mount —
  `RUN --mount=type=bind,source=.,target=/ctx --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore /ctx/App.sln`.
  The bind mount is not a layer (nothing is copied), so this step's cache key is the whole
  context — it re-runs on any source change, but with the NuGet cache mount that re-run is
  seconds, not a re-download. Prefer it when the csproj list is large and churns.
```

**Section: Trimming, ReadyToRun, NativeAOT** (verify against https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/trim-self-contained, https://learn.microsoft.com/en-us/dotnet/core/deploying/ready-to-run, https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/, and https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot for the ASP.NET Core feature-support state in .NET 10)

```markdown
### Trimming, ReadyToRun, NativeAOT — image size vs startup vs risk

| Option | Image/size effect | Startup | Cost / risk | Reach for it when |
|---|---|---|---|---|
| Framework-dependent (default) | Baseline (`aspnet` base) | JIT warm-up | None | Default — stop here unless measured |
| ReadyToRun `/p:PublishReadyToRun=true` | Larger app dir, same base | Faster cold start (AOT-compiled entry code) | Longer publish; no compat risk | Cold-start-sensitive, unwilling to take trimming risk |
| Trimmed self-contained `/p:PublishTrimmed=true` + `runtime-deps` base | Much smaller total | Slightly faster | Reflection-heavy code breaks without annotations; trim warnings must be zero, not suppressed | Size-critical images where AOT is a step too far |
| NativeAOT `/p:PublishAot=true` + SDK `-aot` build image + `runtime-deps` base | Smallest | Fastest, no JIT | No runtime codegen; minimal APIs supported via RequestDelegateGenerator, some ASP.NET Core features unsupported — check the official compatibility table | Cold-start-critical services on minimal APIs with source-generated JSON |

- Trimming and AOT both demand source-generated `System.Text.Json` (`JsonSerializerContext`) —
  which is this stack's standard anyway.
- Measure before adopting: publish time and CI cost go up; only startup/size go down. `docker
  history` before/after tells the size truth.
```

**Section: Supply chain & CI pointer** (verify `COPY --link` semantics against https://docs.docker.com/reference/dockerfile/#copy---link)

```markdown
### Supply chain, COPY --link, and the CI pointer

- Pin base images by digest for reproducible builds (`aspnet:10.0@sha256:...`); at minimum pin
  major.minor. Renovate/Dependabot can bump digests.
- `COPY --link` copies independent of the parent layer's filesystem, letting BuildKit reuse the
  copied layer even when earlier layers changed (rebase instead of re-copy). Worth adding on the
  final stage's `COPY --from=...` lines; requires `# syntax=docker/dockerfile:1` (1.4+).
- CI cache backends (out of scope here, by design): when builds move to ephemeral CI runners,
  BuildKit exports the layer cache via `--cache-to`/`--cache-from` (`type=registry` or `type=gha`,
  `mode=max`). Local/on-host deploys don't need any of it — the builder cache is already
  persistent.
```

- [ ] **Step 3: Verify the whole file's link/source discipline**

Run:
```bash
grep -c "https://" skills/docker/references/best-practices.md
```
Expected: ≥ 12 (every carried and new claim keeps a source; Sources list present at bottom).

- [ ] **Step 4: Commit**

```bash
git add skills/docker/references/best-practices.md
git commit -m "docker skill: verified best-practices reference (cache mounts, CPM restore layers, trim/AOT matrix)"
```

---

### Task 3: Rename to `nginx-deploy` and cut it down to nginx-only

**Files:**
- Rename: `skills/docker-nginx-deploy/` → `skills/nginx-deploy/` (git mv, preserves history)
- Modify: `skills/nginx-deploy/SKILL.md` (full rewrite, content below)
- Modify: `skills/nginx-deploy/references/best-practices.md` (prune to nginx half)

**Interfaces:**
- Consumes: skill name `docker` (Task 1) for cross-references.
- Produces: skill name `nginx-deploy` referenced by Tasks 4–7.

- [ ] **Step 1: git mv the directory**

```bash
git mv skills/docker-nginx-deploy skills/nginx-deploy
```

- [ ] **Step 2: Replace `skills/nginx-deploy/SKILL.md` with exactly this content**

````markdown
---
name: nginx-deploy
description: Use when configuring nginx — reverse proxy in front of ASP.NET Core, TLS/HTTPS/Let's Encrypt/certbot, HTTP/2, gzip, WebSocket/SignalR proxying, forwarded headers, or exposing a hosted app stack to the internet.
---

# nginx reverse proxy + Let's Encrypt

## Overview

A single **nginx** reverse proxy terminates TLS with **Let's Encrypt** certs in front of the app container. Only nginx publishes ports (80/443). The BFF serves the Angular build output (same origin — see `bff-security`). Dockerfiles, images, and the surrounding compose stack (app/db/redis/rabbitmq, networks, secrets, healthchecks) live in the `docker` skill — this skill adds the two services below to that stack.

## nginx + certbot services (join the `docker` compose skeleton)

```yaml
  nginx:
    image: nginx:stable
    # periodic reload picks up renewed Let's Encrypt certs — the certbot container has no
    # docker CLI/socket, so a certbot --deploy-hook can NOT reload nginx from over there
    command: ["/bin/sh", "-c", "while :; do sleep 6h & wait $${!}; nginx -s reload; done & nginx -g 'daemon off;'"]
    ports: ["80:80", "443:443"]
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - certbot-webroot:/var/www/certbot:ro
      - letsencrypt:/etc/letsencrypt:ro
    depends_on: [app]
    networks: [internal]
  certbot:
    image: certbot/certbot
    entrypoint: ["/bin/sh", "-c", "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot; sleep 12h & wait $${!}; done"]
    volumes:
      - certbot-webroot:/var/www/certbot
      - letsencrypt:/etc/letsencrypt
```

Plus two named volumes on the stack: `certbot-webroot: {}`, `letsencrypt: {}`.

## nginx server block

```nginx
server {
    listen 80;
    server_name app.example.com;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    http2 on;
    server_name app.example.com;
    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    gzip on; gzip_types application/json application/javascript text/css image/svg+xml;
    client_max_body_size 10m;

    location / {
        proxy_pass http://app:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # SignalR/WebSockets:
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
        proxy_read_timeout 100s;
    }
}
```

ASP.NET Core side (required or Secure cookies + redirects break behind the proxy):

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    // KnownNetworks is [Obsolete] in .NET 10 (build fails with warnings-as-errors) — use KnownIPNetworks
    o.KnownIPNetworks.Clear(); o.KnownProxies.Clear(); // trust the compose-internal proxy
});
app.UseForwardedHeaders();   // first in the pipeline
```

## First-time cert issuance

1. Start nginx with only the port-80 server block.
2. `docker compose run --rm certbot certonly --webroot -w /var/www/certbot -d app.example.com --email you@example.com --agree-tos --no-eff-email`
3. Enable the 443 block, `docker compose exec nginx nginx -s reload`. Renewal is handled by the certbot loop; renewed certs are picked up by the nginx service's 6-hourly reload loop (see services above).

## Common mistakes

| Mistake | Fix |
|---|---|
| Compression in Kestrel *and* nginx | nginx only |
| Missing `UseForwardedHeaders` | Scheme=http inside → Secure cookies dropped, wrong redirect URLs |
| Certs baked into images | letsencrypt volume shared nginx↔certbot |
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 — remove it |
| `proxy_buffering off` globally "for performance" | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host; per-hostname HTTP-01 instead |
| Trusting all proxies while publishing the app port | Only nginx reachable (internal network), app port never published — then clearing known networks is safe |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- nginx: https://nginx.org/en/docs/
- certbot: https://certbot.eff.org/ | Let's Encrypt: https://letsencrypt.org/docs/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before writing config in this area.**
````

- [ ] **Step 3: Prune `skills/nginx-deploy/references/best-practices.md` to the nginx half**

Keep (unchanged): the nginx bullets in "Current versions" (nginx versions, `http2 on;`, `proxy_http_version` default, HTTP/3-experimental, Let's Encrypt profiles, OCSP-gone), section "nginx reverse proxy correctness", section "TLS configuration", section "ACME challenge choice and renewal", the anti-pattern rows for `ssl_stapling`, HTTP/3, `proxy_buffering off`, wildcard cert, trusting all proxies, and the nginx/letsencrypt/certbot/Mozilla source URLs.

Delete: the .NET-image and Compose bullets in "Current versions", sections "Multi-stage builds and layer caching", "Image size and security", "Health checks without a shell", "Compose in production", the Docker anti-pattern rows (`version:` key, secrets as build args, `apt-get update`, whole-repo COPY, chiseled HEALTHCHECK, Debian assumption, `--start-period`, compose-up-rebuilds-everything), and the docs.docker.com / dotnet-docker source URLs.

Replace the header intro with:

```markdown
# Best Practices: nginx + Let's Encrypt in front of ASP.NET Core

Verified against official documentation, July 2026. Sources: nginx.org/en/docs,
letsencrypt.org/docs, eff-certbot.readthedocs.io, and the Mozilla server-side TLS guidelines v6.0
(now hosted at configurator.tlsref.org). Full URL list at the bottom. This file extends SKILL.md —
read that first; nothing here overrides it. Docker builds, images, and compose: see the `docker`
skill.
```

- [ ] **Step 4: Verify disjointness and no stale self-references**

```bash
sed -n '3p' skills/nginx-deploy/SKILL.md | grep -iE 'dockerfile|build|image|compose' && echo "FAIL: docker words in nginx-deploy description" || echo "OK"
grep -rn "docker-nginx-deploy" skills/ && echo "FAIL: stale name inside skills/" || echo "OK"
```
Expected: `OK` twice.

- [ ] **Step 5: Commit**

```bash
git add -A skills/nginx-deploy skills/docker-nginx-deploy
git commit -m "Rename docker-nginx-deploy to nginx-deploy; scope it to nginx/TLS/Let's Encrypt only"
```

---

### Task 4: Fix all repo references to the old skill name

**Files:**
- Modify: `skills/bff-security/SKILL.md:85`
- Modify: `skills/docs-maintenance/SKILL.md:19`
- Modify: `commands/deploy-setup.md:6`
- Modify: `commands/surgical.md:31`
- Modify: `commands/new-fullstack.md:8` and `:19`

- [ ] **Step 1: Apply these exact replacements (Edit tool, old → new)**

`skills/bff-security/SKILL.md`:
- old: `app.UseForwardedHeaders();       // nginx in front — X-Forwarded-For/Proto (see docker-nginx-deploy)`
- new: `app.UseForwardedHeaders();       // nginx in front — X-Forwarded-For/Proto (see nginx-deploy)`

`skills/docs-maintenance/SKILL.md`:
- old: `  deployment.md          # build, compose, nginx, certs (see docker-nginx-deploy)`
- new: `  deployment.md          # build, compose, nginx, certs (see docker / nginx-deploy)`

`commands/deploy-setup.md`:
- old: `per the `docker-nginx-deploy` skill (load `noobit:docker-nginx-deploy` first)`
- new: `per the `docker` and `nginx-deploy` skills (load `noobit:docker` and `noobit:nginx-deploy` first)`

`commands/surgical.md`:
- old: `` `bff-security`, `docker-nginx-deploy`, `angular-ngrx-state` ``
- new: `` `bff-security`, `docker`, `nginx-deploy`, `angular-ngrx-state` ``

`commands/new-fullstack.md` (two edits):
- old: `` (`mssql`/`postgres`/`sqlite`), `docker-nginx-deploy`, `dotnet-testing` ``
- new: `` (`mssql`/`postgres`/`sqlite`), `docker`, `nginx-deploy`, `dotnet-testing` ``
- old: `` **Hosting**: Dockerfile (multi-stage .NET+Angular, non-root), `compose.yaml` (app, db, redis[, rabbitmq], nginx, certbot) and `compose.override.yaml` for local dev (published DB/redis ports, no nginx/certbot), nginx conf per `docker-nginx-deploy`, ``
- new: `` **Hosting**: Dockerfile and `compose.yaml` per `docker` (multi-stage .NET+Angular, non-root, cache mounts; app, db, redis[, rabbitmq]) with the nginx + certbot services and nginx conf per `nginx-deploy`, `compose.override.yaml` for local dev (published DB/redis ports, no nginx/certbot), ``

- [ ] **Step 2: Verify no references remain outside work/**

```bash
grep -rn "docker-nginx-deploy" --exclude-dir=.git --exclude-dir=work . && echo "FAIL" || echo "OK"
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add skills/bff-security/SKILL.md skills/docs-maintenance/SKILL.md commands/
git commit -m "Point all skill/command references at docker + nginx-deploy"
```

---

### Task 5: Add the Docker review dimension to stack-reviewer

**Files:**
- Modify: `agents/stack-reviewer.md`

- [ ] **Step 1: Extend the description frontmatter (line 3)**

- old: `Reviews for correctness, async/threading bugs, caching misuse, EF/Dapper performance, cookie-BFF security, SignalStore misuse, missing tests, and stale docs.`
- new: `Reviews for correctness, async/threading bugs, caching misuse, EF/Dapper performance, cookie-BFF security, SignalStore misuse, Docker build hygiene, missing tests, and stale docs.`

- [ ] **Step 2: Insert a new dimension after dimension 8 ("Solution conventions")**

Append as item 9 in "Review dimensions":

```markdown
9. **Docker build hygiene** (per `docker` / `nginx-deploy`): sources copied before manifests+restore (busts the restore layer on every edit), missing or gutted `.dockerignore` (`**/bin`, `**/obj`, `node_modules`), secrets as `ENV`/`ARG` or baked into images, `latest` base tags, container running as root (no `USER $APP_UID`), `apt-get update` in its own `RUN`, db/redis/rabbit ports published to the host, services without healthchecks or with sleep-based startup ordering, compression enabled in both Kestrel and nginx, removed/weakened cache mounts on restore steps.
```

- [ ] **Step 3: Commit**

```bash
git add agents/stack-reviewer.md
git commit -m "stack-reviewer: add Docker build hygiene review dimension"
```

---

### Task 6: README, CLAUDE.md.example, version bump

**Files:**
- Modify: `README.md:9`
- Modify: `CLAUDE.md.example:36`
- Modify: `.claude-plugin/plugin.json:3`

- [ ] **Step 1: README skill row (line 9) — exact replacements**

- old: `| **12 skills** | `
- new: `| **13 skills** | `
- old: `` `bff-security` (cookie BFF, no OIDC), `docker-nginx-deploy`, `dotnet-testing` ``
- new: `` `bff-security` (cookie BFF, no OIDC), `docker` (cached multi-stage builds, image size/AOT trade-offs, production compose), `nginx-deploy` (reverse proxy, TLS, Let's Encrypt), `dotnet-testing` ``

- [ ] **Step 2: CLAUDE.md.example — replace the Hosting row (line 36) with two rows**

- old:
```
| Hosting | Docker, nginx reverse proxy, Let's Encrypt | `noobit:docker-nginx-deploy` |
```
- new:
```
| Containers | Docker: cached multi-stage builds, small images, compose | `noobit:docker` |
| Hosting | nginx reverse proxy, Let's Encrypt | `noobit:nginx-deploy` |
```

- [ ] **Step 3: Bump plugin version**

`.claude-plugin/plugin.json`: `"version": "1.4.0"` → `"version": "1.5.0"`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md.example .claude-plugin/plugin.json
git commit -m "v1.5.0: split docker-nginx-deploy into docker + nginx-deploy skills"
```

---

### Task 7: Update the user's global `~/.claude/CLAUDE.md` (outside the repo — no commit)

**Files:**
- Modify: `C:\Users\cmxl\.claude\CLAUDE.md`

- [ ] **Step 1: Replace the Hosting row with the same two rows as CLAUDE.md.example**

- old:
```
| Hosting | Docker, nginx reverse proxy, Let's Encrypt | `noobit:docker-nginx-deploy` |
```
- new:
```
| Containers | Docker: cached multi-stage builds, small images, compose | `noobit:docker` |
| Hosting | nginx reverse proxy, Let's Encrypt | `noobit:nginx-deploy` |
```

- [ ] **Step 2: Verify no other old-name references in the global file**

```bash
grep -n "docker-nginx-deploy" /c/Users/cmxl/.claude/CLAUDE.md && echo "FAIL" || echo "OK"
```
Expected: `OK`

---

### Task 8: Final verification sweep

**Files:** none (read-only checks; fix-ups only if a check fails)

- [ ] **Step 1: Stale-name sweep**

```bash
grep -rn "docker-nginx-deploy" --exclude-dir=.git . 
```
Expected: hits ONLY under `work/specs/` and `work/plans/` (historical documents — leave them).

- [ ] **Step 2: Trigger-disjointness check on both descriptions**

```bash
sed -n '3p' skills/docker/SKILL.md | grep -icE 'nginx|tls|encrypt|proxy'
sed -n '3p' skills/nginx-deploy/SKILL.md | grep -icE 'dockerfile|build|image|compose'
```
Expected: `0` and `0` (grep -c exits 1 on zero matches — that IS the pass).

- [ ] **Step 3: Cross-reference presence check**

```bash
grep -l "nginx-deploy" skills/docker/SKILL.md
grep -l "\`docker\`" skills/nginx-deploy/SKILL.md
```
Expected: both print the file path (each skill names the other).

- [ ] **Step 4: Relative-link check in the two skills**

```bash
ls skills/docker/references/best-practices.md skills/nginx-deploy/references/best-practices.md
```
Expected: both exist (the `[references/best-practices.md]` links in both SKILL.md files resolve).

- [ ] **Step 5: Dispatch `stack-reviewer` on the full diff range (`git diff main-before-split..HEAD` equivalent: `git diff 7ab9676..HEAD`), fix any BLOCKER/MAJOR, commit fixes**

Expected: `VERDICT: ship` (docs-consistency dimension is the relevant one for a markdown-only change).
