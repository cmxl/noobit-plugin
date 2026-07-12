# Design: split `docker-nginx-deploy` into `docker` + `nginx-deploy`

**Date:** 2026-07-12
**Status:** approved design, pending implementation plan
**Ships as:** v1.5.0

## Motivation

`docker-nginx-deploy` mixes two concerns: general Docker work (Dockerfiles, images, compose
orchestration) and the nginx reverse-proxy/TLS story. Build performance is underserved — BuildKit
cache mounts are waved off as "don't bother", there is no guidance on image-size/startup trade-offs
(trimming, AOT, variant choice), no build profiling, and `stack-reviewer` has no Docker dimension
at all. Goal: Docker builds are maximally performant (local rebuild speed, on-host deploys, image
size/startup — CI-cache backends explicitly out of focus), with the knowledge where Claude needs it
and enforcement in review.

## Decision

Split into two skills with disjoint triggers. A **skill**, not a new agent: build knowledge is
reference material used while writing Dockerfiles; enforcement goes into `stack-reviewer` as a new
review dimension.

### Skill 1: `docker` (new)

Everything Docker-specific except nginx. Owns "an optimal image exists and the compose stack runs".

**SKILL.md:**
- Canonical .NET + Angular multi-stage Dockerfile (moved from the old skill), upgraded:
  BuildKit cache mounts (`--mount=type=cache` for NuGet and npm) become the **default pattern**,
  not an optional CI extra.
- Layer-ordering discipline (least→most frequently changing); manifest-first COPY respecting the
  repo conventions: `global.json`, `Directory.Build.props`, `Directory.Packages.props` (CPM),
  `nuget.config`, then csproj files, then sources — so a source edit never busts the restore layer.
- `.dockerignore` baseline (`**/bin`, `**/obj`, `node_modules`, `.git`, `dist`).
- Image variant decision table: `aspnet:10.0` (Noble) vs `-noble-chiseled[-extra]` vs alpine;
  non-root (`USER $APP_UID`); when to reach for trimming / ReadyToRun / NativeAOT (size + cold
  start vs build time + compat), including the SDK `-aot` variant.
- `HEALTHCHECK` patterns (Dockerfile instruction → lives here), incl. the chiseled no-shell
  problem and its options.
- Compose skeleton **minus nginx/certbot services**: app/db/redis/rabbitmq, internal-only
  networks, `.env`/compose `secrets:`, restart policies, healthchecks +
  `depends_on.condition: service_healthy`, resource limits, profiles, dev/prod override split,
  fast single-service redeploy (`docker compose build app && docker compose up --no-deps -d app`).
- Build-time profiling: `docker build --progress=plain`, `docker buildx du`, spotting the layer
  that busts the cache.
- Cross-reference: "reverse proxy, TLS, certs → `nginx-deploy`".

**references/best-practices.md** (July-2026-verified, sourced, same style as the other skills):
- Cache-mount details (NuGet/npm/apt), `COPY --link`, bind-mount builds where they help.
- Many-csproj restore patterns under CPM.
- Trimming/ReadyToRun/NativeAOT decision matrix with dotnet-docker sources.
- Digest pinning, image hygiene, current image/version facts.
- One pointer paragraph on CI cache backends (`--cache-to/--cache-from`, gha) — explicitly not a
  deep section.
- Compose-in-production content inherited from the old reference file (secrets, networks, limits,
  profiles, override split).

**description:** "Use when working with Docker — writing or optimizing Dockerfiles, slow builds,
layer caching, image size, base image choice (chiseled/alpine/AOT), docker compose, healthchecks,
container networking/secrets, or redeploying services." (No nginx/TLS words.)

### Skill 2: `nginx-deploy` (renamed from `docker-nginx-deploy`)

Only the reverse-proxy story:
- nginx server blocks (80→443 redirect, ACME webroot location), TLS config (Mozilla intermediate,
  no `ssl_stapling` for LE), HTTP/2, gzip, `client_max_body_size`, buffering guidance,
  WebSocket/SignalR proxying.
- The nginx + certbot **compose services** (reload loop, renewal loop) — nginx-specific even
  though they are compose — and first-time cert issuance.
- ASP.NET Core `UseForwardedHeaders` counterpart.
- references/best-practices.md keeps the nginx/TLS/Let's Encrypt/certbot half of the current file;
  the Docker/compose half moves to `docker`.
- Cross-reference: "Dockerfiles, images, and the surrounding compose stack → `docker`".

**description:** "Use when configuring nginx — reverse proxy in front of ASP.NET Core,
TLS/HTTPS/Let's Encrypt/certbot, HTTP/2, gzip, WebSocket/SignalR proxying, forwarded headers, or
exposing a hosted app stack to the internet." (No Dockerfile/build/image/compose words.)

### Trigger disjointness rule

"Dockerfile", "build", "image", "compose" appear only in `docker`'s description; "nginx", "TLS",
"Let's Encrypt", "proxy" only in `nginx-deploy`'s. Each SKILL.md names the other for boundary
cases.

## Ripple updates (same change)

| Asset | Change |
|---|---|
| `agents/stack-reviewer.md` | New review dimension: Docker build hygiene — cache-busting COPY ordering, secrets baked into images/build args, `latest` tags, root user, missing `.dockerignore`, `apt-get update` in its own layer. Loads `noobit:docker` for the conventions. |
| `commands/deploy-setup.md` | Load `noobit:docker` + `noobit:nginx-deploy` instead of the old skill. |
| `commands/surgical.md` | Skill list: replace `docker-nginx-deploy` with `docker`, `nginx-deploy`. |
| `commands/new-fullstack.md` | Point Dockerfile/compose generation at `docker`, nginx assets at `nginx-deploy`. |
| `skills/bff-security/SKILL.md` | Cross-ref `docker-nginx-deploy` → `nginx-deploy` (forwarded headers). |
| `skills/docs-maintenance/SKILL.md` | deployment.md comment → "(see docker / nginx-deploy)". |
| `CLAUDE.md.example` | Hosting row → both skills; keep table shape. |
| `README.md` | "12 skills" → 13; skill list updated. |
| `~/.claude/CLAUDE.md` (user's global, outside repo) | Hosting row → `noobit:docker` / `noobit:nginx-deploy`. |
| `.claude-plugin/plugin.json` | Version → 1.5.0. Manifests do not enumerate skills — no other change. |

## Out of scope

- No new agent (enforcement rides in `stack-reviewer`).
- No deep CI-cache/buildx-bake/multi-platform sections — pointer paragraph only.
- No changes to hooks.

## Verification

1. `grep -r "docker-nginx-deploy"` over the repo → zero hits outside git history/this spec.
2. Description disjointness check: no shared trigger keyword between the two skills.
3. Every claim in the new/edited best-practices files carries a source URL (repo convention).
4. Plugin loads: both skills discovered, names resolve as `noobit:docker` / `noobit:nginx-deploy`
   from the referencing commands/agents.
