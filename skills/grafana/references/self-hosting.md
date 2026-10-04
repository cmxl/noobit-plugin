# Self-hosting Grafana with Docker compose

Verified live (October 2026) with `grafana/grafana:13.2.3` behind `nginx:1.29`, datasources on
`grafana/otel-lgtm:0.35.0`. Everything in this file was run: healthcheck, `__FILE` secrets,
`read_only`, provisioning, `$__file{}`, Live websocket through nginx, admin reset. The exceptions are
marked "(docs)".

## Contents

1. [Compose service](#1-compose-service)
2. [Secrets](#2-secrets)
3. [Configuration reference](#3-configuration-reference)
4. [Datasource provisioning](#4-datasource-provisioning)
5. [nginx](#5-nginx)
6. [Plugins](#6-plugins)
7. [Database](#7-database)
8. [Image renderer](#8-image-renderer)
9. [Backup, restore, upgrade](#9-backup-restore-upgrade)
10. [Local development](#10-local-development)
11. [Alerting as files](#11-alerting-as-files)

## 1. Compose service

This service joins the `noobit:docker` compose skeleton, with its **own** `grafana` network shared
only with nginx, plus an internal `observability` network shared with the telemetry stores. nginx and certbot come from
`noobit:nginx-deploy`. Add `grafana` to the nginx service's `networks:` (`[edge, grafana]`). Grafana
never joins `edge`, the subnet the app trusts for `X-Forwarded-*`.

```yaml
services:
  grafana:
    image: grafana/grafana:13.2.3            # exact; Renovate bumps it, a human reads the upgrade guide
    restart: unless-stopped
    environment:
      GF_SERVER_DOMAIN: grafana.example.com
      GF_SERVER_ROOT_URL: https://grafana.example.com/
      GF_SERVER_ENFORCE_DOMAIN: "true"       # other Host headers → 301 to root_url (DNS rebinding)
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin_password   # first start only
      GF_SECURITY_SECRET_KEY__FILE: /run/secrets/grafana_secret_key           # encrypts datasource secrets
      GF_SECURITY_COOKIE_SECURE: "true"
      GF_SECURITY_DISABLE_GRAVATAR: "true"
      GF_AUTH_BASIC_ENABLED: "false"         # no user:password on the API — service-account tokens only
      GF_SNAPSHOTS_EXTERNAL_ENABLED: "false" # no publishing to snapshots.raintank.io
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_NEWS_NEWS_FEED_ENABLED: "false"
      GF_PLUGINS_PREINSTALL_AUTO_UPDATE: "false"   # pinned image = pinned plugins; required with read_only
      GF_DATABASE_WAL: "true"                # SQLite write-ahead log (single instance)
    secrets: [grafana_admin_password, grafana_secret_key]
    volumes:
      - grafana-data:/var/lib/grafana                       # grafana.db, plugins, search index
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    healthcheck:   # /api/health checks the DB (503 when failing); not subject to enforce_domain
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:3000/api/health"]
      interval: 30s
      start_period: 60s
    networks: [grafana, observability]       # never `edge`/`backend`; never `ports:` (nginx is the only published service)
    logging: { driver: local }
networks:
  grafana:    # nginx ↔ grafana only; normal bridge, so plugin installs keep egress. No fixed subnet:
              # nobody trusts it for forwarded headers
  observability:   # grafana ↔ Prometheus/Loki/Tempo (they also join `backend` to receive OTLP)
    internal: true
secrets:   # files on the server, gitignored, no trailing newline, readable by uid 472
  grafana_admin_password: { file: ./secrets/grafana_admin_password }
  grafana_secret_key: { file: ./secrets/grafana_secret_key }
volumes: { grafana-data: {} }
```

Repo layout:

```
grafana/
  provisioning/
    datasources/datasources.yaml
    dashboards/            # empty unless file provisioning is used (dashboards-as-code.md §7)
    alerting/.gitkeep      # keep the dirs: a missing one logs an error on every start
    plugins/.gitkeep       # (the .gitkeep itself is skipped with a harmless warning)
  resources/               # dashboards as code, pushed by CI (dashboards-as-code.md)
tools/grafana/push-dashboards.ps1
```

Why each setting is there:

- **`read_only` works** because everything Grafana writes is under `/var/lib/grafana` (volume) or
  `/tmp` (tmpfs). The exception is the bundled-plugin auto-update, hence
  `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`: without it Grafana 13 downloads newer core datasource
  plugins on every start and fails writing them to the image.
- **Grafana stays off `edge`:**
  - The app trusts `edge` (the docker skeleton's fixed `172.28.0.0/16`) as its forwarded-headers
    proxy network.
  - Grafana makes HTTP requests on its users' behalf (datasources, custom headers). On `edge`, a
    datasource pointed at `http://app:8080` would reach the app directly, from a trusted proxy IP,
    with a forged `X-Forwarded-For`, skipping nginx and the per-IP login rate limiting.
  - Its own `grafana` network gives nginx access and outbound internet for plugins.
- **Grafana stays off `backend` too.** That network holds db, redis and rabbit, and any datasource
  an admin adds could reach them. Grafana shares the internal `observability` network only with the
  telemetry stores (Prometheus/Loki/Tempo or the OTLP collector). The stores also join `backend`
  where the app pushes OTLP to them, so Grafana reaches the stores but not the app or the databases
  (verified). The app's `KnownIPNetworks` stays exactly the `edge` subnet (`noobit:nginx-deploy`).
  Add `backend` to Grafana only for a SQL datasource (§4), and say why in the compose file.
- **Image variants:**
  - Default Alpine (has `wget` for the healthcheck). Use it.
  - `-ubuntu`.
  - `-slim` = no bundled plugins (installed at first start, which needs internet).
  - **Not `-distroless` with this config.** It has no `/run.sh` entrypoint, so every `GF_*__FILE` is
    silently ignored, and you get `admin`/`admin` and the default `secret_key` (verified). If you
    must use it, set values as `GF_SECURITY_ADMIN_PASSWORD: $$__file{/run/secrets/x}` (Grafana's own
    expansion, verified; `$$` escapes compose), drop the healthcheck (no shell) and probe externally.
  - `grafana/grafana-oss` stopped receiving updates (last tag 13.0.2).
  - `grafana/grafana-enterprise` is free to run but proprietary-licensed: use it only for Enterprise
    features.
- **User:** uid 472, gid 0. Named volumes get the right ownership. Bind mounts must be writable by
  472 (`chown -R 472:0`).

## 2. Secrets

Grafana's entrypoint reads `GF_*__FILE` with `$(cat file)`. That strips trailing `\n` but **keeps
`\r`**, so a secret file written by a Windows tool silently contains a carriage return, and the admin
password no longer matches what you type. Write secrets without any line ending:

```bash
printf '%s' "$(openssl rand -base64 24 | tr -d '\r\n')" > secrets/grafana_admin_password
printf '%s' "$(openssl rand -base64 32 | tr -d '\r\n')" > secrets/grafana_secret_key
chmod 644 secrets/grafana_*   # container user 472 must read them (directory stays 700, owned by the deploy user)
```

```powershell
Set-Content -NoNewline secrets/grafana_admin_password ([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)))
Set-Content -NoNewline secrets/grafana_secret_key ([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)))
```

- **The admin password is applied only when the database is created.** Changing the secret later does
  nothing; reset it with
  `docker compose exec grafana grafana cli admin reset-admin-password '<new>'` (13.x: `grafana cli`,
  the `grafana-cli` binary is gone). This works with `read_only`.
- **`secret_key` must exist before the first start and never change.** It wraps the data keys that
  encrypt datasource passwords and tokens (envelope encryption). Losing it means re-entering every
  datasource secret. Back it up with the volume (§9).
- **Datasource secrets** come from files too (§4), never `environment:` (visible in `docker inspect`).

## 3. Configuration reference

Override any `grafana.ini` key as `GF_<SECTION>_<KEY>` (upper case, `.`/`-` → `_`); add `__FILE` to
read the value from a file. Prefer env vars in compose over mounting a custom `grafana.ini`.

| Setting | Default | Set to | Why |
|---|---|---|---|
| `server.root_url` / `domain` | `http://localhost:3000/` | public URL / host | Links, redirects, OAuth callbacks, Live origin check |
| `server.enforce_domain` | false | true | Redirects foreign Host headers (DNS rebinding). CI/gcx must use the public host |
| `server.serve_from_sub_path` | false | only with a sub-path `root_url` | See §5 for why a sub-path is discouraged |
| `security.cookie_secure` | false | true | Session cookie only over HTTPS (TLS ends at nginx) |
| `security.cookie_samesite` | lax | keep `lax` | `strict` breaks OAuth/SAML redirects |
| `security.allow_embedding` | false | keep | Sends `X-Frame-Options: deny` (verified) |
| `auth.basic.enabled` | true | false | Removes password auth on the API; the login form still works |
| `auth.anonymous.enabled` | false | keep | A public dashboard is a deliberate share, not anonymous org access |
| `users.allow_sign_up` | false | keep | Users are created by an admin |
| `snapshots.external_enabled` | true | false | No data leaves the instance |
| `analytics.*`, `news.news_feed_enabled` | true | false | No phoning home |
| `plugins.preinstall_auto_update` | true | false | Reproducible, read-only-compatible |
| `dashboards.min_refresh_interval` | 5s | `30s`+ on busy instances | Clamps over-eager dashboard refresh |
| `database.wal` | false | true (SQLite) | Fewer "database is locked" errors |

Brute-force protection on the login form is on by default (5 attempts per 5 minutes per user). nginx
rate limiting is optional on top. HSTS comes from nginx (§5): unlike the app host, no ASP.NET Core
app sits behind this hostname to send it.

## 4. Datasource provisioning

`grafana/provisioning/datasources/datasources.yaml`. The **uids are the contract**: every dashboard
references `prometheus`, `loki` and `tempo`, and every instance (dev, staging, prod) provisions the
same uids pointing at its own backends.

```yaml
apiVersion: 1
prune: true   # a datasource removed from this file is removed from Grafana
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 60s       # = OTLP metric export interval (.NET default 60 s) or scrape interval
      httpMethod: POST
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: tempo
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: false
    jsonData:
      derivedFields:          # OTLP logs carry trace_id as structured metadata → link to the trace
        - name: TraceID
          matcherType: label
          matcherRegex: trace_id
          datasourceUid: tempo
          url: "$${__value.raw}"   # $$ = literal $; provisioning expands $VAR / ${VAR}
          urlDisplayLabel: View trace
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    editable: false
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        filterByTraceID: true
        spanStartTimeShift: -5m
        spanEndTimeShift: 5m
      serviceMap:
        datasourceUid: prometheus
  - name: App database (read-only)
    uid: app-db
    type: grafana-postgresql-datasource
    url: db:5432
    user: grafana_reader      # SELECT-only role on reporting views — never app_user/app_owner
    editable: false
    jsonData: { database: app, sslmode: disable }
    secureJsonData:
      password: $__file{/run/secrets/grafana_db_reader}   # verified: the file's content is used
```

(`grafana_db_reader` is one more entry in the grafana service's `secrets:` list. A SQL datasource is
the one case where Grafana also joins `backend`, to reach `db`; note that in the compose file.)

Rules:

- **Fixed `uid`** (≤ 40 chars of `[A-Za-z0-9_-]`; 13.2 rejects e.g. dots with "Invalid datasource UID"), never
  auto-generated: auto uids differ per instance and break every dashboard reference.
- **`editable: false` + `prune: true`**: the file is the only source, and UI changes are impossible.
- **Secrets:** `$__file{/run/secrets/<name>}` in `secureJsonData`, with the file in the service's compose
  `secrets:`. Not `$ENV_VAR`, which works but puts the secret in the container environment.
- **Literal `$`** inside provisioning values is `$$`. `${VAR}` is expanded before `$VAR`.
- **SQL datasources** connect with a dedicated read-only role, never the app's roles
  (`noobit:docker` → database roles). Grafana users can run arbitrary queries in Explore.
- Check health after changes:
  `curl -H "Authorization: Bearer $TOKEN" https://grafana.example.com/api/datasources/uid/prometheus/health`.

## 5. nginx

Grafana gets **its own hostname** and server block, in the `noobit:nginx-deploy` layout (catch-all,
port-80 redirect, certbot webroot, cert issuance via `--webroot` once nginx runs). Verified with
nginx 1.29: TLS, login, and the Live websocket (`/api/live/ws` → 101; a foreign `Origin` → 403 from
Grafana).

```nginx
upstream grafana { zone grafana 64k; server grafana:3000 resolve; }   # resolver as in nginx-deploy

server {
    listen 443 ssl;
    http2 on;
    server_name grafana.example.com;
    ssl_certificate     /etc/letsencrypt/live/grafana.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/grafana.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 10m;          # large dashboard JSON via the API
    add_header Strict-Transport-Security "max-age=31536000" always;   # no app behind this host sends it

    location / {
        proxy_pass http://grafana;
        proxy_http_version 1.1;
        proxy_set_header Host $host;   # must equal domain (enforce_domain)
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;            # Grafana Live websocket
        proxy_set_header Connection $connection_upgrade;   # map from nginx-deploy ('' → '')
    }
}
```

**Why not `app.example.com/grafana/`:** a sub-path shares the app's origin. Any script running on a
Grafana page (a panel plugin, an HTML text panel, an XSS) is same-origin with the app. It can call
the app's API with the BFF's session cookie and read the antiforgery token, which defeats SameSite
and CSRF protection. If a separate hostname is truly impossible (verified fallback, Grafana 13.2.3):

- **Grafana:** `GF_SERVER_DOMAIN: app.example.com`,
  `GF_SERVER_ROOT_URL: https://app.example.com/grafana/` and `GF_SERVER_SERVE_FROM_SUB_PATH: "true"`.
  The healthcheck stays `http://localhost:3000/api/health`: under `serve_from_sub_path` both
  `/api/health` and `/grafana/api/health` answer 200.
- **nginx**, inside the app's existing 443 server block, before `location /`:

  ```nginx
  location /grafana/ {
      proxy_pass http://grafana;          # no URI part: the /grafana/ prefix is passed through unchanged
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
  }
  ```

  `add_header` lines in the server block (an app CSP, for example) apply to this location too and
  can break Grafana's UI. nginx inheritance means one `add_header` inside the location drops *all*
  server-level ones, so either set Grafana's headers explicitly there or keep the app's security
  headers in the app's own `location /`.
- **gcx / CI:** the server URL includes the path (`https://app.example.com/grafana`). Verified: gcx
  and the push script work with it.
- **Record the trade-off in an ADR** (`noobit:adr`): same-origin exposure accepted, and why a
  hostname wasn't possible.

## 6. Plugins

- Pin versions and install before start: `GF_PLUGINS_PREINSTALL_SYNC: "grafana-clock-panel@3.1.0"`
  (comma list; `id@version@url` for custom zips). It installs into the volume, so it works with
  `read_only`.
- **Deprecated:** `GF_PLUGINS_INSTALL` (since 12.1) and `GF_INSTALL_PLUGINS` (now only a build arg of
  Grafana's custom Dockerfile).
- Angular plugins stopped working in 12. The image-renderer *plugin* was removed in 13 (§8).
- 12.4+: plugin processes no longer inherit the host environment. Pass plugin config through
  provisioning, not env vars.

## 7. Database

- **SQLite (default) + `GF_DATABASE_WAL=true`** for one instance: no extra service. The database is
  backed up with the volume.
- **Postgres when running more than one Grafana replica** (or a large org):
  - Use its own database and owner on the stack's Postgres, set via `GF_DATABASE_TYPE: postgres`,
    `GF_DATABASE_HOST: db:5432`, `GF_DATABASE_NAME: grafana`, `GF_DATABASE_USER: grafana` and
    `GF_DATABASE_PASSWORD__FILE`.
  - Each replica keeps its own search index under `/var/lib/grafana/unified-search` (don't share it).
  - Grafana Live across replicas needs the Redis engine (docs).
- Moving SQLite → Postgres later is a migration project (docs). Decide before the instance holds
  important state.

## 8. Image renderer

(docs; not run live) PNG/PDF export and alert images need the separate `grafana/grafana-image-renderer`
service (v5.12.x) on the internal `observability` network, since the plugin is gone in 13:

```yaml
  renderer:
    image: grafana/grafana-image-renderer:v5.12.5
    restart: unless-stopped
    environment:
      AUTH_TOKEN: ${GRAFANA_RENDERER_TOKEN:?}   # the service reads AUTH_TOKEN (or --server.auth-token); default "-"
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    networks: [observability]                   # reaches grafana:3000 for the callback; port 8081 /render, internal only
    logging: { driver: local }
```

(Not run live here: check the renderer docs for a health endpoint before adding a `healthcheck`, and
for whether its browser runs with `read_only` + `tmpfs`.)

On the Grafana side: `GF_RENDERING_SERVER_URL: http://renderer:8081/render`,
`GF_RENDERING_CALLBACK_URL: http://grafana:3000/`, and `GF_RENDERING_RENDERER_TOKEN__FILE` pointing at
a secret file with the same token. Never leave the default `-`. The renderer takes the token only
from its environment or a flag, so it comes from the server's gitignored `.env`. That's an accepted
exception for an internal-only token. Size it generously (the docs suggest ≥ 16 GiB / 4 cores
for heavy use). Skip it unless PNG export or alert images are actually needed.

## 9. Backup, restore, upgrade

**Back up** the `grafana-data` volume together with `secrets/grafana_secret_key`. With SQLite, stop
Grafana first for a consistent copy:

```bash
docker compose stop grafana
docker run --rm -v app_grafana-data:/data:ro -v "$PWD/backups:/backup" alpine:3.24 tar czf /backup/grafana-$(date +%F).tgz -C /data .
docker compose start grafana
```

Then copy the archive and the `secret_key` **off the host**, and rehearse a restore now and then
(`noobit:docker` → backups: a backup on the same disk dies with it).

Restore is the reverse into an empty volume, with the **same** `secret_key`. Dashboards in git
(dashboards-as-code.md) are not a backup of users, permissions, alert state or annotations. The
volume is.

**Upgrade:**

1. Read every upgrade guide between the current and target version
   (`https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v<major>.<minor>/`).
2. Back up (above).
3. Bump the exact tag, then `docker compose up -d grafana` and watch the logs plus `/api/health`.
4. Push the dashboards (CI) and check the main dashboards render.

Upgrading to 13.x migrates dashboards and folders to unified storage on the first start. **Downgrading
afterwards requires the pre-upgrade backup.** Skip 13.0.0 (pulled); go to the latest 13.x patch.

## 10. Local development

The authoring instance runs the same image, the same provisioning and the **same datasource uids**.
For a local telemetry backend, `grafana/otel-lgtm` bundles an OTLP endpoint, Prometheus, Loki and
Tempo (dev only, not for production):

```yaml
# compose.dev.yaml
services:
  grafana:
    ports: ["127.0.0.1:3000:3000"]
    environment:
      GF_SERVER_DOMAIN: localhost
      GF_SERVER_ROOT_URL: http://localhost:3000/
      GF_SECURITY_COOKIE_SECURE: "false"
  lgtm:
    image: grafana/otel-lgtm:0.35.0     # OTLP :4317/:4318, Prometheus :9090, Loki :3100, Tempo :3200
    networks: [backend, observability]   # receives OTLP from the app, serves Grafana
# app: OTEL_EXPORTER_OTLP_ENDPOINT=http://lgtm:4318
```

In dev, point the datasource URLs at `http://lgtm:9090`, `http://lgtm:3100` and `http://lgtm:3200`,
keeping the uids: use a second datasources file in a dev-only provisioning folder, or `$VAR`
interpolation of the URLs. To get data on screen sooner, set `OTEL_METRIC_EXPORT_INTERVAL=15000` in
dev with `timeInterval: 15s`.

## 11. Alerting as files

Alert rules, contact points and notification policies can be provisioned from
`provisioning/alerting/*.yaml` (export the YAML from the UI: *Alerting → … → Export*). Rules created
through `/api/v1/provisioning/alert-rules` are locked in the UI unless the request sends
`X-Disable-Provenance: true` (docs). Contact-point secrets (webhook URLs, SMTP passwords) stay out of
git: inject them at provisioning time instead of committing them. Variable expansion in alerting
files is per the provisioning docs, so verify `$__file{}` there before relying on it.
Alerting design itself (what to page on) belongs with the service's SLOs, not in dashboards.
