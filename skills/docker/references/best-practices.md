# Best Practices: Docker builds, images, and compose for .NET + Angular

Verified against official documentation, July 2026. Sources: docs.docker.com (build best practices,
cache mounts, Dockerfile reference, Compose reference) and github.com/dotnet/dotnet-docker plus
learn.microsoft.com deployment docs. Full URL list at the bottom. This file extends SKILL.md — read
that first; nothing here overrides it. Reverse proxy, TLS, and Let's Encrypt: see the
`nginx-deploy` skill.

## Current versions (July 2026)

- **.NET 10 is GA and LTS.** `mcr.microsoft.com/dotnet/aspnet:10.0` / `sdk:10.0` resolve to
  **Ubuntu 24.04 "Noble"** (e.g. `10.0.9-noble`), *not* Debian — use `apt-get` as usual, it is
  Ubuntu underneath. `.NET 11` exists only as `11.0-preview`; never use it in production.
- **Chiseled (distroless) variants are stable**: `10.0-noble-chiseled`, `10.0-noble-chiseled-extra`
  (adds `icu` + `tzdata`), plus `10.0-resolute-chiseled` (Ubuntu 26.04) and
  `10.0-azurelinux3.0-distroless[-extra]`. Alpine: `10.0-alpine3.23` / `10.0-alpine3.24`
  (also `-extra`, `-composite`). SDK has an `-aot` variant for native AOT builds.
- **Non-root**: all .NET 8+ images define user `app` (UID exposed as env var `APP_UID`);
  chiseled/distroless images run as that non-root user *by default*. Default listen port is 8080.
- **Compose**: the top-level `version:` key is **obsolete** — Compose validates against the latest
  Compose Specification schema and warns if `version:` is present. Use top-level `name:` for the
  project name (`COMPOSE_PROJECT_NAME`).

## Established patterns

### Multi-stage builds and layer caching (Docker build best practices)

- Order Dockerfile instructions **least- to most-frequently changing**. Copy dependency manifests
  first, restore, then copy sources: `COPY *.csproj` → `dotnet restore` → `COPY src/` →
  `dotnet publish`; `COPY package*.json` → `npm ci` → `COPY web/` → `npm run build`. A change to a
  source file then invalidates only the publish/build layers, not restore/`npm ci`.
- Run the .NET publish and Angular build as **independent stages** — BuildKit builds them in
  parallel and rebuilds only the stage whose inputs changed. Node is only ever a *build* stage
  (node 22+); the runtime image never contains node.
- Always combine `apt-get update` with `apt-get install` in the **same `RUN`** and clean up in the
  same layer (`rm -rf /var/lib/apt/lists/*`); a lone `apt-get update` layer gets cached stale.
  Add `--no-install-recommends`; do not install packages "because they might be nice to have".
- Keep a `.dockerignore` (`**/bin`, `**/obj`, `node_modules`, `.git`, `dist`) — smaller context,
  fewer spurious cache busts.
- Prefer `COPY` over `ADD`. For reproducible/supply-chain-safe builds, pin base images by digest
  (`aspnet:10.0@sha256:...`); at minimum pin the major.minor tag, never `latest`.
- Cache mounts (`RUN --mount=type=cache,...` for NuGet/npm) are the default pattern here, not a
  CI-only extra — see the dedicated section below.

### Image size and security: chiseled vs full images (dotnet-docker docs)

- Chiseled/distroless images contain "only the minimal set of packages .NET needs": **no shell, no
  package manager**, non-root by default → drastically smaller CVE surface. Trade-offs:
  - No shell ⇒ no shell-form Dockerfile instructions, no `docker exec` debugging, no
    wget/curl-based `HEALTHCHECK` (see below).
  - `icu`/`tzdata` are omitted ⇒ either run globalization-invariant
    (`InvariantGlobalization=true`) or use the `-extra` variant.
- Full images (`10.0`, i.e. Noble) include ICU/tzdata and a shell; they also define the `app` user
  but you must opt in: `USER $APP_UID` (or `USER app`). Writable paths must be mounted/chowned
  explicitly — the app dir is root-owned and read-only to `app`, which is what you want.
- Rule of thumb: start with `aspnet:10.0` + `USER $APP_UID`; move to `10.0-noble-chiseled[-extra]`
  once you don't need in-container debugging.

### Health checks without a shell

`HEALTHCHECK` (or compose `healthcheck.test`) executes *inside* the container — the probe binary
must exist there. Options, in order of preference for this stack:

1. **Full aspnet image**: install wget once (SKILL.md pattern) and use
   `HEALTHCHECK CMD wget -qO- http://localhost:8080/health/live || exit 1`. Tune
   `--start-period` (grace window during app start) and `--retries`; newer Docker engines also
   support `--start-interval` for faster probing during startup.
2. **Chiseled**: there is no shell and no wget, and exec-form `CMD ["..."]` still needs a binary in
   the image. Either drop the Docker-level healthcheck and probe `/health` externally (nginx
   `proxy_next_upstream`, uptime monitor) — the SKILL.md default — or compile a tiny AOT
   healthcheck executable and copy it in, invoking it exec-form.
3. Never mark `db`/`redis` dependencies healthy by sleep hacks — use compose
   `depends_on: { condition: service_healthy }` against real healthchecks (`pg_isready`,
   `redis-cli ping`), as in SKILL.md.

### Compose in production (Compose docs)

- **No secrets in the compose file or image.** Interpolate from a gitignored `.env`
  (`${DB_PASSWORD}`) or better, use top-level `secrets:` (`file:` or `environment:` source) mounted
  at `/run/secrets/<name>` — per-service opt-in, doesn't leak into every child process or
  `docker inspect` output like env vars do. ASP.NET Core reads them via key-per-file config or
  `ConnectionStrings__Default__FILE`-style indirection you implement.
- **Databases/Redis/RabbitMQ on an internal network only** — no `ports:` on them, ever; only nginx
  publishes 80/443. For belt-and-braces, mark the network `internal: true` if the services don't
  need outbound internet (note: blocks image-pull-time only, not `docker pull`; DB migrations and
  package feeds still work at build time on the host).
- `restart: unless-stopped` (or `always`) on every long-running service — Compose's documented
  mechanism for surviving crashes and reboots; there is no supervisor otherwise.
- **Resource limits** work with plain `docker compose up` via
  `deploy.resources.limits: { cpus: "1.0", memory: 512M }` (+ `reservations`, `pids`). Cap the app
  and DB so one runaway container can't OOM the host.
- **Profiles** (`profiles: ["ops"]`) gate optional services (pgadmin, one-shot certbot issuance,
  migrations) out of the default `up`; activate with `--profile ops` or `COMPOSE_PROFILES`.
- **Environment split**: keep `compose.yaml` as the production-shaped base and layer overrides —
  `docker compose -f compose.yaml -f compose.override.dev.yaml up` for dev (bind mounts, exposed
  ports), plain base in prod. Docker's guidance: remove code bind-mounts in production, adjust
  restart policy and log verbosity. Redeploy one service without bouncing its deps:
  `docker compose build app && docker compose up --no-deps -d app`.

### Cache mounts in depth (Docker build cache docs)

- `RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore ...` — the cache
  lives in the builder's own internal storage (not in any image layer), is cumulative across
  builds (only new/changed packages download on a cache-busted rebuild), and is shared across
  builds/Dockerfiles that use the same `id` (which defaults to `target` if omitted). Use the same
  mount on the `dotnet publish` step: restore writes into the mount, so publish must see it too.
- npm: mount the *download* cache (`target=/root/.npm`), never `node_modules` itself — `npm ci`
  deletes and recreates `node_modules`, which must land in the layer, not the mount.
- Concurrent builds sharing one cache: the default `sharing` mode is `shared` (concurrent writers
  allowed); add `sharing=locked` to pause a second writer until the first releases the mount (the
  docs' own apt example uses this), or use `sharing=private` / a distinct `id` per build to avoid
  sharing at all.
- apt variant for the runtime stage's wget install:
  `RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked rm -f /etc/apt/apt.conf.d/docker-clean && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && apt-get update && apt-get install -y --no-install-recommends wget`
  (with cache mounts you skip the `rm -rf /var/lib/apt/lists/*` since lists live in the mount).
  Debian/Ubuntu images ship a `docker-clean` config that purges downloaded packages immediately, so without removing it only the lists mount pays off.
  Treat cache mount contents as best-effort: "your build should work with any contents of the
  cache directory" since another build may overwrite files or GC may clean them.
- Cache mounts are builder-local: the default cache storage is internal to the BuildKit instance
  you're building with, so `docker buildx du` / `docker builder prune` operate on it and a fresh
  CI runner starts empty — which is why they are a *local/on-host* win first (see the CI pointer
  below for the ephemeral-runner case).

### Restore layers in many-project solutions (CPM) (Docker build cache + bind mount docs)

- Under central package management, version bumps touch only `Directory.Packages.props` — copied
  in the first COPY — so the per-project csproj COPY list changes only when a project is added,
  removed, or gains a reference. Maintaining explicit `COPY src/X/X.csproj src/X/` lines is
  therefore cheap and stays the default; a glob like `COPY src/**/*.csproj` does NOT preserve the
  directory structure and silently breaks restore.
- Alternative that needs no csproj COPY list at all: restore from a bind mount —
  `RUN --mount=type=bind,source=.,target=/ctx --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore /ctx/App.sln`.
  A bind mount is read-only by default and is not committed to any layer — nothing is copied into
  the image, and `source`/`from` default to the build context root if omitted. This step
  effectively re-runs whenever anything in the mounted context changes, but with the NuGet cache
  mount in place that re-run is a fast no-op restore, not a re-download. Prefer it when the csproj
  list is large and churns; prefer the explicit COPY list when the context is small and stable, so
  unrelated file edits don't re-trigger the restore step at all.

### Trimming, ReadyToRun, NativeAOT — image size vs startup vs risk (.NET deployment docs)

| Option | Image/size effect | Startup | Cost / risk | Reach for it when |
|---|---|---|---|---|
| Framework-dependent (default) | Baseline (`aspnet` base) | JIT warm-up | None | Default — stop here unless measured |
| ReadyToRun `/p:PublishReadyToRun=true` | ~2-3x larger app dir, same base | Faster cold start (less JIT work at first use) | Longer publish; no compatibility risk | Cold-start-sensitive, unwilling to take trimming risk |
| Trimmed self-contained `/p:PublishTrimmed=true` + `runtime-deps` base | Much smaller total | Slightly faster | Reflection-heavy code breaks without annotations; trim warnings must be zero, not suppressed | Size-critical images where AOT is a step too far |
| NativeAOT `/p:PublishAot=true` + SDK `-aot` build image + `runtime-deps` base | Smallest | Fastest, no JIT | No runtime codegen; minimal APIs are only *partially* supported (MVC, Blazor Server, Session, SPA are not supported at all) — check the official compatibility table | Cold-start-critical services on minimal APIs with source-generated JSON |

- ReadyToRun and Native AOT both require publishing for a **specific runtime identifier**
  (`dotnet publish -r linux-x64 ...`) — neither works with a portable, RID-less publish. Trimmed
  self-contained publishing is, by definition, also RID-specific.
- Trimming and Native AOT both demand source-generated `System.Text.Json`
  (`JsonSerializerContext`) — Native AOT disables reflection-based (de)serialization outright, and
  this is this stack's standard anyway.
- Native AOT's `CreateSlimBuilder()` (used by the `webapiaot` template) drops HTTPS/HTTP-3 support
  and a few other `CreateBuilder()` features from Kestrel — expected in this stack since TLS
  terminates at nginx, not Kestrel.
- Measure before adopting: publish time and CI cost go up; only startup/size go down. `docker
  history` before/after tells the size truth.

### Supply chain, COPY --link, and the CI pointer (Dockerfile reference)

- Pin base images by digest for reproducible builds (`aspnet:10.0@sha256:...`); at minimum pin
  major.minor. Renovate/Dependabot can bump digests.
- `COPY --link` copies into an empty destination so the result lands in its own layer,
  independent of the parent layer's filesystem — BuildKit can then reuse that layer (or rebase it
  onto an updated base image) even when earlier layers changed, instead of re-copying. Worth
  adding on the final stage's `COPY --from=...` lines; requires
  `# syntax=docker/dockerfile:1` (1.4+). Caveat: a linked `COPY`/`ADD` can't read files from
  previous build state or follow a pre-existing symlink at the destination, and any subdirectories
  it creates get the copied path's own mode (use `--chmod` if that's wrong for the target dir).
- CI cache backends (out of scope here, by design): when builds move to ephemeral CI runners,
  BuildKit exports the layer cache via `--cache-to`/`--cache-from` (`type=registry` or `type=gha`,
  `mode=max`). Local/on-host deploys don't need any of it — the builder cache is already
  persistent.

## Anti-patterns

| Anti-pattern | Why it bites | Fix |
|---|---|---|
| `version:` key in compose files | Obsolete; only produces warnings | Delete it; optionally set `name:` |
| Secrets as build args or `ENV` in the Dockerfile | Persist in image history/`docker inspect` | Runtime env from `.env`, or compose `secrets:` at `/run/secrets/` |
| `apt-get update` in its own `RUN` | Cached stale index → old/missing packages | Single `RUN apt-get update && apt-get install ... && rm -rf /var/lib/apt/lists/*` |
| Copying the whole repo before `dotnet restore`/`npm ci` | Every source change re-downloads all packages | Manifest-first COPY ordering (see SKILL.md Dockerfile) |
| `HEALTHCHECK` with wget/curl on chiseled images | No shell, no binary → unhealthy forever | Full image + install wget, or external probing, or a copied-in probe binary |
| Assuming .NET 10 images are Debian | `10.0` is Ubuntu Noble now | Fine for `apt-get`, but don't reference Debian codenames in tags |
| No `--start-period` on app healthchecks | EF migrations/startup marked unhealthy → restart loops | Set `--start-period` beyond worst-case cold start |
| `docker compose up` after every change rebuilding everything | Downtime for unrelated services | `docker compose build app && docker compose up --no-deps -d app` |

## Sources

- https://docs.docker.com/build/building/best-practices/
- https://docs.docker.com/build/cache/optimize/
- https://docs.docker.com/compose/
- https://docs.docker.com/compose/how-tos/production/
- https://docs.docker.com/compose/how-tos/use-secrets/
- https://docs.docker.com/reference/compose-file/version-and-name/
- https://docs.docker.com/reference/compose-file/deploy/
- https://docs.docker.com/reference/dockerfile/
- https://docs.docker.com/reference/dockerfile/#run---mounttypecache
- https://docs.docker.com/reference/dockerfile/#run---mounttypebind
- https://docs.docker.com/reference/dockerfile/#copy---link
- https://github.com/dotnet/dotnet-docker/blob/main/README.aspnet.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/image-variants.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/distroless.md
- https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/trim-self-contained
- https://learn.microsoft.com/en-us/dotnet/core/deploying/ready-to-run
- https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot
