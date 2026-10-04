# Best Practices: Docker builds, images, and compose for .NET + Angular

Verified against official documentation, October 2026. Sources: docs.docker.com (build best practices,
cache mounts, Dockerfile reference, Compose reference) and github.com/dotnet/dotnet-docker plus
learn.microsoft.com deployment docs. Full URL list at the bottom. This file extends SKILL.md — read
that first; nothing here overrides it. Reverse proxy, TLS, and Let's Encrypt: see the
`nginx-deploy` skill.

## Current versions (October 2026)

- **.NET 10 is GA and LTS.** `mcr.microsoft.com/dotnet/aspnet:10.0` / `sdk:10.0` resolve to
  **Ubuntu 24.04 "Noble"**, *not* Debian — use `apt-get` as usual, it is Ubuntu underneath. Current
  exact tags (October 2026): `sdk:10.0.401`, `aspnet:10.0.12` — see the tag tables in dotnet-docker's
  `README.sdk.md`/`README.aspnet.md`. This stack pins those exact tags (SKILL.md), not the floating `10.0`.
- **.NET 11 is a release candidate (STS)**, already published under the plain `11.0` tag, whose
  default distro is **Ubuntu 26.04 "Resolute"**, not Noble. Never use it in production before GA;
  it is STS, so LTS `10.0` stays the default afterwards too.
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
  first, restore, then copy sources: `COPY *.csproj` + `packages.lock.json` →
  `dotnet restore --locked-mode` (RID-less) → `COPY src/` → `dotnet publish -a $TARGETARCH`; `COPY package*.json` → `npm ci` → `COPY web/` → `npm run build`. A change to a
  source file then invalidates only the publish/build layers, not restore/`npm ci`.
- Run the .NET publish and Angular build as **independent stages** — BuildKit builds them in
  parallel and rebuilds only the stage whose inputs changed. Node is only ever a *build* stage
  (`node:24-slim` — 24 is Active LTS until 2026-10-20, then Maintenance LTS until 2028-04-30;
  Node 26 becomes Active LTS on 2026-10-28 — check the nodejs.org release schedule and move to
  `node:26-slim` once it is LTS); the runtime image never contains node. `-slim`
  holds only what's needed to run node, which covers `npm ci` + the Angular build; switch to the
  full `node:24` image (based on `buildpack-deps`, compiler toolchain included) only if a
  dependency compiles native addons.
- **Cross-architecture builds** (Dockerfile reference: automatic platform ARGs; dotnet-docker
  "build for a platform" doc): Docker builds for the host's native architecture by default, so an
  arm64 dev machine produces arm64 images that fail on amd64 servers. Put
  `FROM --platform=$BUILDPLATFORM` on the SDK and node stages, declare `ARG TARGETARCH` in the SDK
  stage, and pass `-a $TARGETARCH` to `dotnet publish` only. The restore stays RID-less and
  locked: `<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>` in
  `Directory.Build.props` (all projects) puts both RIDs' assets in the graph and the lock files, so
  publish for either arch matches them. `dotnet restore -r <rid> --locked-mode` overrides that list
  and fails NU1004 (verified; `-a` on a non-Linux host adds the host RID and fails the same way).
  Don't add `--no-restore` to publish: the packages live only in the cache mount, which CI layer
  caches (`--cache-from type=registry|gha`) never export — a fresh runner then reuses the cached
  restore layer with an empty package folder and publish fails (NETSDK1064, reproduced by building
  with a cold mount id). Publish's own restore — locked via `-p:RestoreLockedMode=true` — is a fast
  no-op when the packages are there and re-downloads exactly the locked versions when they aren't.
  Self-contained / NativeAOT publish needs nothing extra at restore: `RuntimeIdentifiers` already
  pulls the runtime packs (and, with `PublishAot` in the project, the ILCompiler packs) for both
  RIDs — verified with `--self-contained` on the command line and `SelfContained`/`PublishAot` in the
  csproj on a cold package cache. `PublishAot` adds an implicit `Microsoft.DotNet.ILCompiler`
  reference, so regenerate and commit the lock files when turning it on (else NU1004), and the AOT
  build stage additionally needs `clang` (not in the plain `sdk` image). Only the final `aspnet` stage follows the
  target platform; select it with `docker build --platform linux/amd64` or the compose service's
  `platform: linux/amd64`. Any `RUN` in that final stage (the wget install) executes as target-arch
  code, so a cross-build needs QEMU emulation (Docker multi-platform docs): bundled in Docker
  Desktop; on a Linux builder register it once with
  `docker run --privileged --rm tonistiigi/binfmt --install all`. A final stage without `RUN`
  (chiseled image, external probe) needs no emulation at all.
- Always combine `apt-get update` with `apt-get install` in the **same `RUN`** and clean up in the
  same layer (`rm -rf /var/lib/apt/lists/*`); a lone `apt-get update` layer gets cached stale.
  Add `--no-install-recommends`; do not install packages "because they might be nice to have".
- Keep a `.dockerignore` (SKILL.md list: `**/bin`, `**/obj`, `**/node_modules`, `**/dist`,
  `**/.angular`, `**/TestResults`, `**/*.pfx`, `**/.env*`, `.git`) — smaller context, fewer
  spurious cache busts, no local secrets in the context. Matching uses Go `filepath.Match` rules
  relative to the context root, extended by `**` for any number of directories (build context
  docs): `node_modules` alone excludes only `./node_modules`, so a nested `web/node_modules` would
  still be sent and bust `COPY web/`.
- Prefer `COPY` over `ADD`. For reproducible/supply-chain-safe builds, pin base images by digest
  (`aspnet:10.0.12@sha256:...`); never `latest`. Pinning (one rule for the stack):
  - .NET: **exact** tags — SDK = `global.json` version (`sdk:10.0.401`, `"rollForward": "latestPatch"`),
    runtime = patch tag (`aspnet:10.0.12`). A floating `sdk:10.0` changes the SDK under you (implicit
    package versions → `--locked-mode` breaks; locked mode presupposes committed `packages.lock.json`
    files via `RestorePackagesWithLockFile` plus `<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>`
    — `aspnet-backend`, `ci-pipelines` rule 2 — and the Dockerfile copies them before its RID-less
    `dotnet restore --locked-mode`) and makes the image differ from local/CI builds.
    Renovate bumps `global.json` + all .NET `FROM` lines in one grouped PR, so patches still land weekly.
  - Postgres: major (`postgres:18`) — minor releases are bugfix/security-only and need no
    dump/restore; a major bump does (SKILL.md).
  - Node: major (`node:24-slim`) — one LTS line, build stage only.
  - Redis: major (`redis:8`) is acceptable because the cache is reconstructible; pin major.minor
    (`redis:8.x`) if feature releases should land only on purpose.
  - Grafana: **exact** patch (`grafana/grafana:13.2.3`). Upgrades run one-way storage migrations,
    so each bump is a deliberate step after reading the upgrade guide (`grafana`).
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
- Rule of thumb: start with `aspnet:10.0.x` + `USER $APP_UID`; move to `10.0.x-noble-chiseled[-extra]`
  once you don't need in-container debugging.

### Health checks without a shell

`HEALTHCHECK` (or compose `healthcheck.test`) executes *inside* the container — the probe binary
must exist there. What the status drives decides which endpoint to probe:

- **Under plain Docker/Compose, health never restarts anything.** The engine only *reports*
  `unhealthy`; `restart:` reacts to the process exiting. What the health status *does* drive is
  `depends_on: { condition: service_healthy }` and `docker compose up --wait`. So the compose
  healthcheck probes **`/health/ready`** (the app can serve: DB reachable, warmed up) — a deploy with
  `up --wait` then fails when the new version can't reach its database, instead of reporting success.
- The "liveness must have no dependency checks, or a DB outage becomes a restart loop" rule
  (`aspnet-backend`) is for orchestrators that **restart** on a failed probe (Kubernetes
  `livenessProbe`) — there `/health/live` it is.

Options, in order of preference for this stack:

1. **Full aspnet image**: install wget once (SKILL.md pattern) and use
   `HEALTHCHECK CMD wget -qO- http://localhost:8080/health/ready || exit 1`. Tune
   `--start-period` (grace window during app start) and `--retries`; newer Docker engines also
   support `--start-interval` for faster probing during startup.
2. **Chiseled**: there is no shell and no wget, and exec-form `CMD ["..."]` still needs a binary in
   the image. Either drop the Docker-level healthcheck and probe externally (uptime monitor on
   `/health/ready`) — then `depends_on` can only use `service_started` and `up --wait` can't gate the
   deploy — or compile a tiny AOT healthcheck executable and copy it in, invoking it exec-form.
3. Never mark `db`/`redis` dependencies healthy by sleep hacks — use compose
   `depends_on: { condition: service_healthy }` against real healthchecks (`pg_isready`,
   `redis-cli ping`), as in SKILL.md. nginx gets a loopback-only health server
   (`nginx-deploy`); the certbot renew loop has no healthcheck — nothing depends on it.

### Compose in production (Compose docs)

The rules are in SKILL.md; this is the why.

- **Secrets as files, not env.** Compose `secrets:` are per-service opt-in and, unlike `environment:`,
  don't show up in `docker inspect` or leak into every child process. Plain-compose file secrets are
  bind mounts that keep the host file's owner/mode — make them readable by the container user (`app`
  is uid 1654, postgres 999). ASP.NET Core has no `*_FILE` convention, hence the secret named after
  the config key (`target: ConnectionStrings__Default`) + the key-per-file provider; the official
  postgres image does read `POSTGRES_PASSWORD_FILE`. The same trick feeds the `migrate` job its
  schema-owner string without putting it in argv (`data-access` → references/migrations-ci.md).
- **Two networks** (Compose networks reference): `internal: true` creates an externally isolated
  network — no egress for anything only on it, so data services can't reach the internet while the
  app keeps egress through `edge`. Marking the *only* network internal would cut nginx and the app off
  too (ACME, SMTP, external APIs). The fixed `edge` subnet exists so `ForwardedHeaders:KnownNetwork`
  can name it exactly. Image pulls and builds happen on the host and are unaffected.
- **Runtime hardening for the app:** the .NET runtime puts its diagnostics IPC socket in
  `$TMPDIR`/`/tmp` (hence `tmpfs: [/tmp]` under `read_only`); non-root on port 8080 needs no
  capabilities. Leave these off postgres/redis/nginx — their entrypoints chown and drop privileges at
  start.
- `restart: unless-stopped` (or `always`) on every long-running service — Compose's documented
  mechanism for surviving crashes and reboots; there is no supervisor otherwise. One-shot jobs get
  `restart: "no"`.
- **Log rotation** (Docker logging docs): `local` rotates by default (`max-size` 20m × `max-file` 5,
  compressed). Keep `json-file` only if a log shipper reads its files, and then cap it:
  `logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }`. Host-wide
  alternative: `log-driver`/`log-opts` in the daemon's `daemon.json`.
- **Resource limits** work with plain `docker compose up` via
  `deploy.resources.limits: { cpus: "1.0", memory: 512M }` (+ `reservations`, `pids`). Cap the app
  and DB so one runaway container can't OOM the host.
- **Profiles** gate services out of the default `up` (`--profile`/`COMPOSE_PROFILES`), and a profiled
  service targeted explicitly (`docker compose run <svc>`, `up <svc>`) starts without enabling its
  profile — which is how `tools` jobs (`run --rm migrate`) and one-shot certbot commands
  (`run --rm --entrypoint certbot certbot …`, `nginx-deploy`) work.
- **Environment split**: Compose reads `COMPOSE_FILE` from `.env` (pre-defined environment variables
  docs), so a developer's local `.env` can layer `compose.dev.yaml` while the server's plain base
  never does. Docker's production guidance: no code bind mounts, adjusted restart policy and log
  verbosity.

### Database roles: schema owner vs app

`data-access` and `ci-pipelines` require two database identities: a **schema owner** (DDL, used only
by the `migrate` job) and an **app** role (DML only). The official postgres image runs
`/docker-entrypoint-initdb.d/*.sh|*.sql` once, on an empty data directory — the place to create them.
`db/initdb/10-roles.sh` (committed; mounted read-only, SKILL.md skeleton):

```sh
#!/bin/sh
# Runs once, on an empty data directory only. psql reads the passwords itself (\set with backquotes),
# so they never appear in argv, env or the server log.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
\set owner_pw `cat /run/secrets/db_owner_password`
\set app_pw `cat /run/secrets/db_app_password`
CREATE ROLE app_owner LOGIN PASSWORD :'owner_pw';   -- DDL: migrations only
CREATE ROLE app_user LOGIN PASSWORD :'app_pw';      -- DML: the running app
ALTER DATABASE app OWNER TO app_owner;              -- PG15+: public schema belongs to the db owner
REVOKE ALL ON DATABASE app FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE app TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;           -- no CREATE: app_user can't change the schema
-- every table/sequence app_owner creates later (= every migration) is usable by app_user
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner GRANT USAGE, SELECT ON SEQUENCES TO app_user;
EOSQL
```

- Verified on `postgres:18`: `app_owner` can create tables; `app_user` can read/write them but gets
  `permission denied for schema public` on `CREATE TABLE` and `must be owner` on `ALTER TABLE`.
- Init scripts never re-run on an existing volume: on an existing database, run the same SQL once as
  the superuser (`docker compose exec -T db psql -U postgres -d app`), with the same `\set` lines.
- A migration that adds a **new schema** (`HasDefaultSchema`, `EnsureSchema`) must also
  `GRANT USAGE ON SCHEMA x TO app_user` (`migrationBuilder.Sql`) — default privileges cover the
  tables, not the schema itself.
- Connection strings: `db_connection` = `…;Username=app_user;…`, `db_schema_owner` =
  `…;Username=app_owner;…`; each role password sits in its role-password file and its
  connection-string file — generate them together (e.g. `openssl rand -hex 24`; hex needs no escaping).
- **SQL Server** has no init hook in the official image: run the equivalent once as a one-shot
  `sqlcmd` job (`profiles: [tools]`, password via `SQLCMDPASSWORD` read from a secret file, never `-P`):
  `CREATE LOGIN app_owner …; CREATE USER app_owner; ALTER ROLE db_ddladmin ADD MEMBER app_owner;`
  plus `db_datareader`/`db_datawriter` for it (migrations also move data), and for `app_user` only
  `db_datareader` + `db_datawriter` (or explicit `GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo`).

### Cache mounts in depth (Docker build cache docs)

- `RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore ... --locked-mode` — the cache
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
  removed, or gains a reference. A plain glob like `COPY src/**/*.csproj ./` does NOT preserve the
  directory structure (every csproj lands flat in one folder) and silently breaks restore.
- **`COPY --parents` removes the list** (Dockerfile reference; Dockerfile syntax 1.20+, which
  `# syntax=docker/dockerfile:1` resolves to): it keeps each source's parent directories, so
  `COPY --parents src/*/*.csproj src/*/packages.lock.json ./` (or `src/**/…` for nested layouts)
  recreates `src/X/X.csproj` + its lock file for every project in one line (verified, BuildKit
  with `# syntax=docker/dockerfile:1`). Same restore-layer caching as explicit lines —
  the layer invalidates only when a csproj changes. Prefer it once a solution has more than a
  couple of projects; explicit `COPY src/X/X.csproj src/X/` lines stay fine for one or two.
- Alternative that needs no csproj COPY list at all: restore from a bind mount —
  `RUN --mount=type=bind,source=.,target=/ctx,rw --mount=type=cache,id=nuget,target=/root/.nuget/packages dotnet restore /ctx/src/App.Api/App.Api.csproj --locked-mode`
  (the lock files come with the context; still RID-less).
  RUN bind mounts are read-only by default, and `dotnet restore` writes `obj/project.assets.json`
  plus `obj/*.nuget.g.props`/`.targets` into every project directory under `/ctx` — hence the
  `,rw`. Those writes still don't land in any image layer: a `rw` bind mount's contents are
  discarded when the step completes, so the restored `obj/` output never gets committed. The
  pattern's real value is warming the NuGet cache mount — with it in place, the re-restore that
  `dotnet publish` triggers later takes seconds instead of re-downloading packages. This step still
  effectively re-runs whenever anything in the mounted context changes, but that re-run is now a
  fast no-op restore. `COPY --parents` is usually the better trade: no list to maintain, and
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
  self-contained publishing is, by definition, also RID-specific. The Dockerfile's
  `publish -a $TARGETARCH` already is, and the RID-less locked restore covers it (cross-arch
  bullet above) — never switch the restore to `-r`.
- Trimming and Native AOT both demand source-generated `System.Text.Json`
  (`JsonSerializerContext`) — Native AOT disables reflection-based (de)serialization outright, and
  this is this stack's standard anyway.
- Native AOT's `CreateSlimBuilder()` (used by the `webapiaot` template) drops HTTPS/HTTP-3 support
  and a few other `CreateBuilder()` features from Kestrel — expected in this stack since TLS
  terminates at nginx, not Kestrel.
- Measure before adopting: publish time and CI cost go up; only startup/size go down. `docker
  history` before/after tells the size truth.

### Supply chain, COPY --link, and the CI pointer (Dockerfile reference)

- Pin base images by digest for reproducible builds (`aspnet:10.0.12@sha256:...`); at minimum the
  tags from the pinning rule above. Renovate/Dependabot can bump digests.
- `COPY --link` copies into an empty destination so the result lands in its own layer,
  independent of the parent layer's filesystem — BuildKit can then reuse that layer (or rebase it
  onto an updated base image) even when earlier layers changed, instead of re-copying. Worth
  adding on the final stage's `COPY --from=...` lines; requires
  `# syntax=docker/dockerfile:1` (1.4+). Caveat: a linked `COPY`/`ADD` can't read files from
  previous build state or follow a pre-existing symlink at the destination, and any subdirectories
  it creates get the copied path's own mode (use `--chmod` if that's wrong for the target dir).
- CI cache backends: on ephemeral CI runners BuildKit exports the layer cache via
  `--cache-to`/`--cache-from` (`type=registry`, `mode=max`) — the pipeline side lives in
  `noobit:ci-pipelines`. Local/on-host builds don't need any of it — the builder cache is already
  persistent.

### Backup and restore of database volumes

A named volume survives `docker compose down` but not a disk failure, a `down -v`, or a bad
migration — it is not a backup. Never copy a live database's volume files; take a logical or native
backup through the engine. Non-interactive (cron) calls need `docker compose exec -T` — without it
compose allocates a TTY, which fails without a terminal and mangles binary output.

Keep the commands in a script and let cron call the script — a `%` in a crontab line is a newline
to cron, so `$(date +%F)` inline breaks unless escaped as `\%`:

```sh
#!/bin/sh
# /opt/app/backup.sh — crontab: 15 3 * * * /opt/app/backup.sh >> /var/log/app-backup.log 2>&1
set -eu
cd /opt/app
mkdir -p backups
f="backups/app-$(date +%F).dump"
# write to .tmp, rename on success — a failed dump never looks like a good one
docker compose exec -T db pg_dump -U postgres -Fc app > "$f.tmp" && mv "$f.tmp" "$f"
```

- **PostgreSQL** — custom-format dump (compressed, selective restore) as above. Whole cluster incl.
  roles: `pg_dumpall -U postgres` (plain SQL, restore with `psql`).
  Restore into production: stop the app first (`docker compose stop app`), then
  `docker compose exec -T db pg_restore -U postgres -d app --clean --if-exists < backups/app-<date>.dump`.
  **`--clean` drops every object in the dump before recreating it** — everything written since the
  dump is gone. Prefer restoring into a new database (`createdb -O app_owner app_restore`, restore,
  verify, then swap) when you're not sure.
- **SQL Server** — native backup into a mounted backup volume. The password never goes on the command
  line (`-P` is visible in `ps`): read it from the secret file *inside* the container into
  `SQLCMDPASSWORD`, which `sqlcmd` uses when `-P` is absent:

  ```sh
  docker compose exec -T mssql sh -c "SQLCMDPASSWORD=\"\$(cat /run/secrets/mssql_sa_password)\" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -Q \"BACKUP DATABASE [app] TO DISK = N'/var/opt/mssql/backup/app.bak' WITH INIT, COMPRESSION, CHECKSUM\""
  ```

  (the `mssql` service mounts the sa password as the secret `mssql_sa_password`; `-b` makes a T-SQL
  error a non-zero exit). Then copy the `.bak` out of the backup volume. Restore with
  `RESTORE DATABASE [app] FROM DISK = … WITH REPLACE, CHECKSUM` (see `mssql`).
- **Schedule**: host cron (or a systemd timer) running the script is the simplest; a sidecar service
  under `profiles: [ops]` with the same image and a sleep loop also works and keeps the schedule in
  the compose file. Either way: rotate (e.g. 7 daily + 4 weekly) and **copy off-host**
  (restic/rclone/object storage with versioning) — a backup on the same disk dies with it.
- **Restore drill** (monthly, and after any backup-script change): restore the latest dump into a
  throwaway container — `docker run --rm -d --name restore-test -e POSTGRES_PASSWORD=drill postgres:18`,
  then `docker exec restore-test createdb -U postgres app` and
  `docker exec -i restore-test pg_restore -U postgres -d app --no-owner --no-acl < backups/app-<date>.dump`
  (`--no-owner --no-acl`: the throwaway server has no `app_owner`/`app_user` roles) — run a sanity
  query (row counts, latest timestamp), then `docker stop restore-test`. An untested backup is a
  hope, not a backup.
- Redis here is a cache (no persistence, SKILL.md) — nothing to back up. RabbitMQ: export
  definitions (`rabbitmqctl export_definitions`); messages in flight are not backed up.

## Anti-patterns

| Anti-pattern | Why it bites | Fix |
|---|---|---|
| `version:` key in compose files | Obsolete; only produces warnings | Delete it; optionally set `name:` |
| Secrets as build args or `ENV` in the Dockerfile | Persist in image history/`docker inspect` | Runtime env from `.env`, or compose `secrets:` at `/run/secrets/` |
| `apt-get update` in its own `RUN` | Cached stale index → old/missing packages | Single `RUN apt-get update && apt-get install ... && rm -rf /var/lib/apt/lists/*` |
| Copying the whole repo before `dotnet restore`/`npm ci` | Every source change re-downloads all packages | Manifest-first COPY ordering (see SKILL.md Dockerfile) |
| `HEALTHCHECK` with wget/curl on chiseled images | No shell, no binary → unhealthy forever | Full image + install wget, or external probing, or a copied-in probe binary |
| Assuming .NET 10 images are Debian | `10.0` is Ubuntu Noble now | Fine for `apt-get`, but don't reference Debian codenames in tags |
| Compose healthcheck on `/health/live` | `up --wait`/`service_healthy` pass while the DB is unreachable (compose never restarts on health) | Probe `/health/ready`; `/health/live` is for restarting orchestrators |
| `pg_dump` in a crontab line / `exec` without `-T` | `%` is a newline to cron; no TTY under cron | Script file called by cron; `docker compose exec -T` |
| No `--start-period` on app healthchecks | Failed probes during cold start count toward `--retries` → marked unhealthy; `up --wait` and `depends_on: service_healthy` dependents fail (compose never restarts on health) | Set `--start-period` beyond worst-case cold start |
| `docker compose up` after every change rebuilding everything | Rebuilds every `build:` service; recreates changed deps | `docker compose build app && docker compose up --no-deps -d app` |
| Default `json-file` logging without options | No rotation → disk fills | `logging: { driver: local }` or `json-file` with `max-size`/`max-file` |
| Build stages without `--platform=$BUILDPLATFORM` | arm64 dev box ships arm64 images to amd64 servers | `FROM --platform=$BUILDPLATFORM` + `-a $TARGETARCH` |
| Bare `.dockerignore` names (`node_modules`, `dist`) | Match only at the context root; nested folders still sent | `**/node_modules`, `**/dist`, … |
| Single network marked `internal: true` | nginx/app lose egress (ACME, SMTP, external APIs) | `edge` bridge (nginx + app) + internal `backend` (app + data services) |
| Treating the DB volume as the backup | Disk loss / `down -v` / bad migration = data gone | Scheduled dump, off-host copy, monthly restore drill |

## Sources

- https://docs.docker.com/build/building/best-practices/
- https://docs.docker.com/build/cache/optimize/
- https://docs.docker.com/compose/
- https://docs.docker.com/compose/how-tos/production/
- https://docs.docker.com/compose/how-tos/use-secrets/
- https://docs.docker.com/compose/how-tos/profiles/
- https://docs.docker.com/reference/compose-file/networks/
- https://docs.docker.com/build/concepts/context/#dockerignore-files
- https://docs.docker.com/build/building/multi-platform/
- https://learn.microsoft.com/aspnet/core/fundamentals/configuration/#key-per-file-configuration-provider
- https://learn.microsoft.com/dotnet/core/diagnostics/diagnostic-port
- https://www.postgresql.org/docs/current/app-pgdump.html
- https://pnpm.io/docker
- https://docs.docker.com/reference/compose-file/version-and-name/
- https://docs.docker.com/reference/compose-file/deploy/
- https://docs.docker.com/reference/dockerfile/
- https://docs.docker.com/reference/dockerfile/#run---mounttypecache
- https://docs.docker.com/reference/dockerfile/#run---mounttypebind
- https://docs.docker.com/reference/dockerfile/#copy---link
- https://docs.docker.com/reference/dockerfile/#copy---parents
- https://docs.docker.com/reference/dockerfile/#automatic-platform-args-in-the-global-scope
- https://docs.docker.com/engine/logging/configure/
- https://docs.docker.com/engine/logging/drivers/local/
- https://github.com/dotnet/dotnet-docker/blob/main/samples/build-for-a-platform.md
- https://hub.docker.com/_/node
- https://nodejs.org/en/about/previous-releases
- https://github.com/nodejs/Release#release-schedule
- https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- https://www.postgresql.org/support/versioning/
- https://github.com/dotnet/dotnet-docker/blob/main/README.aspnet.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/image-variants.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/distroless.md
- https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/trim-self-contained
- https://learn.microsoft.com/en-us/dotnet/core/deploying/ready-to-run
- https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/native-aot
