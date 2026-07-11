# Best Practices: .NET + Angular behind nginx with Let's Encrypt

Verified against official documentation, July 2026. Sources: docs.docker.com (build best practices,
Compose reference, Dockerfile reference), github.com/dotnet/dotnet-docker (README.aspnet.md,
image-variants.md, distroless.md), nginx.org/en/docs, letsencrypt.org/docs, eff-certbot.readthedocs.io,
and the Mozilla server-side TLS guidelines v6.0 (now hosted at configurator.tlsref.org). Full URL list
at the bottom. This file extends SKILL.md — read that first; nothing here overrides it.

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
- **nginx**: stable **1.30.3**, mainline **1.31.2**. `http2 on;` directive (since 1.25.1) replaces
  the legacy `listen ... http2` parameter. Since **1.29.7** `proxy_http_version` defaults to `1.1`
  (previously `1.0`) and accepts `2` for proxying — stable 1.30.x includes this.
- **HTTP/3** (`ngx_http_v3_module`) is still marked **experimental** and is not built by default
  (`--with-http_v3_module`); check `nginx -V` before enabling. Requires `listen 443 quic reuseport;`
  plus an `Alt-Svc: h3=":443"` header; 0-RTT needs OpenSSL 3.5.1+.
- **Compose**: the top-level `version:` key is **obsolete** — Compose validates against the latest
  Compose Specification schema and warns if `version:` is present. Use top-level `name:` for the
  project name (`COMPOSE_PROJECT_NAME`).
- **Let's Encrypt profiles** (select via ACME `profile`): `classic` = 90 days (default),
  `tlsserver` = 45 days, `shortlived` = 160 h (~6.7 days, no revocation/CRL URLs). `tlsclient` was
  discontinued 2026-07-08. Certbot selects with `--preferred-profile` / `--required-profile`.
- **Let's Encrypt OCSP is gone**: responders shut down 2025-08-06; certificates carry CRL URLs
  instead. `ssl_stapling` in nginx is a no-op for LE certs — leave it out.

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
- Optional speed-up for CI with persistent BuildKit cache: cache mounts
  (`RUN --mount=type=cache,target=/root/.nuget/packages dotnet restore`,
  same idea with the npm cache). Don't bother for simple single-host deploys.

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

### nginx reverse proxy correctness (nginx docs)

- Defaults worth knowing: `proxy_buffering on`, `proxy_connect_timeout 60s`,
  `proxy_read_timeout 60s`, `proxy_send_timeout 60s`, `proxy_request_buffering on`.
- **Keep buffering on** for normal API/static traffic — it shields Kestrel from slow clients. Turn it
  off *only* for streaming endpoints (SSE, long-poll): `proxy_buffering off;` in that location, or
  better, have ASP.NET Core send `X-Accel-Buffering: no` on streaming responses so nginx disables
  buffering per-response.
- **WebSockets/SignalR**: `proxy_http_version 1.1;` (explicit — required below nginx 1.29.7 and
  harmless above) plus `Upgrade`/`Connection` headers as in SKILL.md. `proxy_read_timeout` kills
  idle sockets; 60s default is too short for SignalR — SKILL.md's 100s works with default
  keep-alives, raise further for quiet long-lived sockets.
- **Body size**: `client_max_body_size` must be >= Kestrel's `MaxRequestBodySize`; nginx rejects
  larger uploads with 413 before the app ever sees them.
- **HTTP/2**: `http2 on;` inside the `listen 443 ssl` server (SKILL.md already does this).
  **HTTP/3**: experimental — skip it for this stack until nginx promotes it; if you must, verify
  the module is compiled in and add the `quic` listener + `Alt-Svc` header.
- Compress in nginx only (gzip; add `gzip_vary on;`) — never double-compress in Kestrel.

### TLS configuration (Mozilla guidelines v6.0 — ssl-config.mozilla.org now redirects to configurator.tlsref.org)

Intermediate profile (the correct default; "modern" = TLS 1.3-only, drops older clients):

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
# TLS1.3 suites (AES-GCM/CHACHA20) are built in; for TLS1.2 keep the Mozilla intermediate
# ECDHE-only cipher list from the generator — do not hand-roll cipher strings.
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
# dhparam only if you serve DHE suites; Mozilla ships a standard 2048-bit ffdhe group.
add_header Strict-Transport-Security "max-age=63072000" always;  # only once the cert setup is proven
```

Do **not** configure `ssl_stapling` for Let's Encrypt certs — LE's OCSP responders were shut down
in August 2025; revocation is CRL-based and needs no server config.

### ACME challenge choice and renewal (Let's Encrypt + certbot docs)

- **HTTP-01 (webroot)** — the SKILL.md default and the right one for a single compose host: port 80
  must be reachable, no wildcards, trivially automated, no credentials stored anywhere.
- **DNS-01** — required for wildcards and works without any public port, but the DNS API credential
  then lives on the host ("risky to store API credentials on web servers" per LE docs) and
  propagation timing varies. Use only when you actually need `*.example.com` or the host has no
  inbound 80.
- **TLS-ALPN-01** — port 443 only; nginx has no built-in responder and certbot support is limited;
  not useful in this stack.
- **Renewal**: run `certbot renew` at least **twice a day** (the compose loop's 12 h cadence
  matches LE's integration guide, which also says clients should honor ARI — certbot handles the
  actual "is it time yet" decision, renewing at ~1/3 of lifetime remaining). Failures should back
  off exponentially, max once/day — certbot does this; don't wrap it in tight retry loops.
- `--deploy-hook` runs only after a *successful* renewal — the right place to reload a co-located
  nginx. In the SKILL.md split-container topology the certbot container cannot reach nginx, hence
  the nginx-side periodic `nginx -s reload` loop instead. Both are valid; don't mix them.
- Consider `--preferred-profile tlsserver` (45-day certs) once renewal automation is proven; stay
  off `shortlived` unless you can tolerate ~6-day validity and monitor renewals closely.

## Anti-patterns

| Anti-pattern | Why it bites | Fix |
|---|---|---|
| `version:` key in compose files | Obsolete; only produces warnings | Delete it; optionally set `name:` |
| Secrets as build args or `ENV` in the Dockerfile | Persist in image history/`docker inspect` | Runtime env from `.env`, or compose `secrets:` at `/run/secrets/` |
| `apt-get update` in its own `RUN` | Cached stale index → old/missing packages | Single `RUN apt-get update && apt-get install ... && rm -rf /var/lib/apt/lists/*` |
| Copying the whole repo before `dotnet restore`/`npm ci` | Every source change re-downloads all packages | Manifest-first COPY ordering (see SKILL.md Dockerfile) |
| `HEALTHCHECK` with wget/curl on chiseled images | No shell, no binary → unhealthy forever | Full image + install wget, or external probing, or a copied-in probe binary |
| Assuming .NET 10 images are Debian | `10.0` is Ubuntu Noble now | Fine for `apt-get`, but don't reference Debian codenames in tags |
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 | Remove; CRL revocation needs nothing server-side |
| Enabling HTTP/3 because a blog said so | Module is experimental and often not compiled in | `nginx -V` and look for `http_v3_module`; skip until stable |
| `proxy_buffering off` globally "for performance" | Slow clients tie up Kestrel connections | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host | Per-hostname HTTP-01 certs; SAN list up to 100 names on `classic` |
| No `--start-period` on app healthchecks | EF migrations/startup marked unhealthy → restart loops | Set `--start-period` beyond worst-case cold start |
| `docker compose up` after every change rebuilding everything | Downtime for unrelated services | `docker compose build app && docker compose up --no-deps -d app` |
| Trusting all proxies in `ForwardedHeadersOptions` while publishing app port | Header spoofing → scheme/IP forgery | Only nginx is reachable (internal network), app port never published — then clearing known networks is safe |

## Sources

- https://docs.docker.com/build/building/best-practices/
- https://docs.docker.com/compose/
- https://docs.docker.com/compose/how-tos/production/
- https://docs.docker.com/compose/how-tos/use-secrets/
- https://docs.docker.com/reference/compose-file/version-and-name/
- https://docs.docker.com/reference/compose-file/deploy/
- https://docs.docker.com/reference/dockerfile/
- https://github.com/dotnet/dotnet-docker/blob/main/README.aspnet.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/image-variants.md
- https://github.com/dotnet/dotnet-docker/blob/main/documentation/distroless.md
- https://nginx.org/en/download.html
- https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- https://nginx.org/en/docs/http/ngx_http_v2_module.html
- https://nginx.org/en/docs/http/ngx_http_v3_module.html
- https://letsencrypt.org/docs/challenge-types/
- https://letsencrypt.org/docs/profiles/
- https://letsencrypt.org/docs/integration-guide/
- https://letsencrypt.org/2024/12/05/ending-ocsp/
- https://eff-certbot.readthedocs.io/en/stable/using.html
- https://configurator.tlsref.org/ (Mozilla server-side TLS guidelines v6.0; ssl-config.mozilla.org redirects here)
