---
name: grafana
description: 'Use when working with Grafana — self-hosting it with Docker/compose (GF_* config, provisioned datasources, reverse proxy, plugins, upgrades, backups), dashboards as code (dashboard JSON in git pushed to staging/prod with gcx or the HTTP API, file-provisioned dashboards, drift from UI edits, folders, service-account tokens), or designing dashboards and PromQL panels for a .NET service. Not for instrumenting the app with OpenTelemetry (aspnet-backend).'
---

# Grafana — self-hosted, dashboards as code

## Overview

Grafana runs as one hardened compose service behind nginx, with datasources **provisioned from YAML**
and dashboards **kept in git as Grafana resource files** and pushed to each instance by a guarded
script around `gcx`, the official Grafana CLI. Nobody edits staging or production dashboards in the
browser. Work happens in a dev Grafana or directly in the JSON, then gets pulled, committed and pushed.

Verified live in October 2026 against Grafana **13.2.3** and gcx **1.4.0**, with a .NET 10 app sending
OTLP to Prometheus, Loki and Tempo: every panel query, provisioning file, push and drift case below was
run. Where a detail is missing or doubtful, check the official docs (bottom) instead of guessing.
Version-sensitive facts:

- `/api/*` is **deprecated since 13.0**; the `/apis/dashboard.grafana.app/<version>` endpoints replace it.
  The server prefers v2 (dynamic dashboards; the UI creates v2). This skill authors v1 (classic
  JSON): it's portable, diff-friendly and accepted everywhere.
- Grafana 13 stores dashboards in "unified storage", migrated automatically on the first 13.x start.
- grafanactl is deprecated in favour of **gcx**. Grizzly is gone. The image-renderer plugin is gone,
  replaced by the renderer service.

## When to use

- Standing up Grafana (compose service, config, secrets, provisioning, nginx), upgrading or backing it up.
- Dashboards as code: repo layout, pushing to staging/prod, CI, UI drift, folders, deleting dashboards,
  converting UI exports, service-account tokens.
- Building or reviewing dashboards: panels, PromQL for ASP.NET Core / .NET runtime metrics, variables,
  units, thresholds, links from logs to traces.
- Symptoms: panels empty after a push, "Cannot save provisioned dashboard", a push that "succeeds" but
  changes nothing, UI edits lost, `${DS_PROMETHEUS}` in panels, bad admin password, 301 to the public URL.

Out of scope: emitting telemetry from the app (`noobit:aspnet-backend` → observability), running Loki,
Tempo or Mimir clusters, and Grafana Cloud billing or stack administration.

## Reference files — read the one you need

| File | Read when |
|---|---|
| [references/self-hosting.md](references/self-hosting.md) | Compose service, config/hardening, secrets, datasource provisioning, nginx, plugins, renderer, backup/upgrade, local dev |
| [references/dashboards-as-code.md](references/dashboards-as-code.md) | Repo layout, resource format, authoring loop, gcx contexts, the push script, drift, CI, deletion, alternatives (Git Sync, file provisioning, Terraform) |
| [references/dashboard-design.md](references/dashboard-design.md) | Panel/PromQL patterns, .NET metric names, variables, units, thresholds, layout, review checklist |
| [templates/aspnetcore-red.json](templates/aspnetcore-red.json) | Starter RED + runtime dashboard for one ASP.NET Core service (resource format, verified against live OTel data) |
| [scripts/push-dashboards.ps1](scripts/push-dashboards.ps1) | Validate + drift-check + push; copy into the project (`tools/grafana/`) |

## How dashboards reach an instance

| Situation | Use |
|---|---|
| Several instances (staging, prod), CI deploys, Grafana elsewhere than the repo | **Push**: resource files + `push-dashboards.ps1` (gcx). **Default.** |
| One instance deployed from the same repo/host as Grafana, nobody may edit | **File provisioning** (mounted folder, read-only in the UI) |
| GitHub/GitLab/Bitbucket/plain Git, Grafana should pull and offer "save as PR" | **Git Sync** (GA in 13); bidirectional and needs a reachable Git host |
| Grafana estate already managed in Terraform | Terraform provider |

Pick **one mode per dashboard**. The API refuses to save a file-provisioned dashboard (400 "Cannot save
provisioned dashboard"), and a provisioning file whose folder annotation differs from its provider's
folder is rejected.

## Core rules

1. **Pin the image exactly:** `grafana/grafana:13.2.3` (OSS). Bump it on purpose. Before every upgrade,
   read that version's upgrade guide and back up the data volume and `secret_key` (references → upgrade).
2. **Configure through `GF_<SECTION>_<KEY>` env vars in compose; secrets go through `__FILE`.**
   - Use compose secret files written **without a trailing CR/LF**: the entrypoint strips `\n` but keeps
     `\r` (Windows-written files break the password).
   - The files must be readable by uid 472.
   - The admin password only applies on the **first** start of an empty volume.
   - Set `secret_key` before the first start; it encrypts datasource secrets.
3. **Hardened by default:**
   - `cookie_secure`, `enforce_domain`, and `GF_AUTH_BASIC_ENABLED=false` (API = service-account tokens only).
   - Anonymous access off, external snapshots off, telemetry/update checks off, gravatar off.
   - `read_only` + `tmpfs` + `cap_drop: [ALL]` + `no-new-privileges`. With `read_only` you also need
     `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false`: otherwise Grafana 13 rewrites its bundled plugins from
     grafana.com on every start (errors on a read-only filesystem, drift on a writable one).
4. **Own hostname (`grafana.example.com`), not a sub-path of the app's origin.** Same-origin Grafana
   pages could ride the app's BFF session cookie and antiforgery token. When a user asks for
   `app.example.com/grafana`, say so and recommend the hostname. Only if they keep the sub-path, use
   the verified fallback config (self-hosting.md §5) and record the trade-off in an ADR. Only nginx
   publishes ports. Grafana sits on its own `grafana` network (nginx + Grafana) and an internal
   `observability` network (Grafana + telemetry stores). It's **never on `edge`**: the app trusts that
   subnet for `X-Forwarded-*`, and a datasource could call the app from there with forged headers.
   It's **not on `backend`** either, so datasources can't reach db/redis/rabbit; add `backend` only
   for a SQL datasource.
5. **Provision datasources from YAML with fixed `uid`s that are identical on every instance.** Dashboards
   reference exactly those uids. Also set `editable: false` and `prune: true`.
   - Secrets via `$__file{/run/secrets/x}` in `secureJsonData`, never literals or `environment:`.
   - `$$` is a literal `$`.
   - When mounting your own `provisioning/`, keep the empty `plugins/` and `alerting/` folders.
6. **Health:** `GET /api/health` checks the database (503 when it's down) and is not redirected by
   `enforce_domain`; use it as the compose healthcheck (`wget`, which the Alpine image includes).
   **CI and gcx must call the `root_url` hostname:** with `enforce_domain`, any other Host gets a 301.
7. **Git is the source of truth for dashboards.** Each dashboard is a **resource file**:
   `apiVersion: dashboard.grafana.app/v1`, `kind: Dashboard`, `metadata.name` = uid (≤ 40 chars,
   `[A-Za-z0-9_-]`), a `grafana.app/folder` annotation, and `spec` holding the dashboard JSON.
   - Name the file `<uid>.json`.
   - Folders are `folder.grafana.app/v1` resources in the same tree.
   - `gcx` **silently skips classic JSON and still exits 0.**
8. **Push only through `push-dashboards.ps1`, never with a bare `gcx resources push` in CI.** The script
   does four things gcx doesn't:
   - offline validation;
   - a drift guard. It refuses when a target dashboard's `grafana.app/updatedBy` (or `createdBy`
     when it was never saved again) is `user:…` **and** its spec/folder differs from the repo file,
     i.e. a UI edit would be lost. gcx itself is last-write-wins;
   - a check that gcx pushed exactly as many resources as the folder holds;
   - a post-push `get` confirming every repo dashboard exists.

   `-ValidateOnly` on PRs. After pulling and merging a UI edit, push with the printed
   `-AcceptDrift <uid>@<resourceVersion>`: on a manual pipeline run via the `acceptDrift` parameter,
   so prod tokens stay in CI. It's refused if someone saved again in the meantime. `-Force` only to
   deliberately discard UI edits.
9. **Datasources in dashboards: `{ "type": …, "uid": "<fixed uid>" }` or a `${datasource}` variable**,
   never by name. Never commit "Share with another instance" exports (`__inputs`, `${DS_*}`): panels
   pushed that way lose their datasource. No numeric `spec.id`.
10. **One token per environment:** a service account with the Editor role, or least privilege
    (verified): org role None plus Edit on the managed folders, which an admin creates once. It's
    created in the UI, with an expiry, and rotated. Staging/prod tokens live only in the pipeline's
    secret variables; developers' gcx keychains hold dev tokens.
11. **Staging/prod dashboards are read-only for people.** `"editable": false` is only a UI hint; the
    real control is folder permissions. Grafana's default gives the *Editor role → Edit* on every new
    folder (verified), so on managed folders remove that entry, give teams View, and leave Edit to the
    deploy service account and the admins. Authoring happens in a dev Grafana (same datasource uids),
    followed by `gcx resources pull dashboards/<uid>`, review and commit.
12. **Deleting is explicit:** gcx push never prunes. Remove the file **and** run
    `gcx resources delete dashboards/<uid>` in the same change; disposable dashboards don't belong in
    managed folders.
13. **Panels that answer questions:** one RED dashboard per service, then runtime. Queries use
    `$__rate_interval`, histograms go through `histogram_quantile(q, sum by (le) (rate(…_bucket…)))`,
    and grouping uses `http_route`, never raw paths. Every panel has a unit and a description.
    Set the datasource `timeInterval` to the OTLP export interval (.NET default **60 s**) so rates
    don't come out empty.

## Stack fit (deliberate deviations)

- **No cookie BFF in front of Grafana** (vs `noobit:bff-security`): Grafana has its own session
  (`grafana_session`, verified `HttpOnly; Secure; SameSite=Lax`), so the BFF rules apply to the app,
  not here. Separation comes from rule 4's separate origin. Users are local Grafana accounts on a
  small team. SSO needs an OAuth IdP the stack doesn't have, so it's out of scope; don't build an
  auth-proxy bridge without an RFC.
- **pwsh script + gcx instead of a .NET tool:** dashboard delivery is deployment glue. The script is
  tested (Pester) and ships with the project (`tools/grafana/`), unlike the one-line ad-hoc rule of
  `noobit:simple-scripts`.
- **SQLite (WAL) by default** for Grafana's own database even when the app runs Postgres. A single
  replica needs nothing more. Use Postgres only for several Grafana replicas (references → database).

## Quick reference

| Thing | Value |
|---|---|
| Image / user / port | `grafana/grafana:13.2.3` (Alpine; `-slim` = without bundled plugins; **not** `-distroless`: it ignores `GF_*__FILE`) · uid 472, gid 0 · 3000 |
| Data / provisioning | `/var/lib/grafana` (volume) · `/etc/grafana/provisioning/{datasources,dashboards,alerting,plugins}` |
| Classic `schemaVersion` | 42 |
| Dashboard API | `/apis/dashboard.grafana.app/v1/namespaces/default/dashboards/<uid>` (`org-<id>`; Cloud `stacks-<id>`) |
| Legacy save codes (13.2) | stale/duplicate save **409** "Dashboard already exists"; bad id **400**; provisioned **400** |
| gcx | `gcx config check` · `resources pull/push/get/delete` · `--context <env>` · CI env `GRAFANA_SERVER`/`GRAFANA_TOKEN`/`GRAFANA_ORG_ID` |
| Push | `pwsh -NoProfile -File tools/grafana/push-dashboards.ps1 -Path grafana/resources -Context staging` |

## Common mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| `grafana/grafana:latest` / `grafana-oss` | Surprise major upgrade (one-way storage migration) / frozen image | Exact `grafana/grafana:<x.y.z>` |
| Secret file written by Windows tools | `\r` becomes part of the password; login fails | `Set-Content -NoNewline` / `printf '%s'`; recreate the volume if the admin was created with it |
| Changing `GF_SECURITY_ADMIN_PASSWORD__FILE` later | Ignored (first start only) | `docker compose exec grafana grafana cli admin reset-admin-password '<pw>'` |
| Classic dashboard JSON in the push folder | gcx reports 0 pushed and exit 0 | Pull it with gcx, or wrap it (dashboards-as-code.md → getting a dashboard into the repo) |
| UI "Export as code" (V2 Resource) committed as-is | Server fields, no folder annotation; its `resourceVersion` doesn't stop overwrites | `gcx resources pull` instead, or strip `metadata` to name + folder annotation |
| Pushing to an instance where people edit | UI edits silently overwritten | Drift guard + `editable: false` + View-only folders |
| Datasource by name / `${DS_*}` | Empty panels on other instances | Fixed provisioned uids |
| `GF_INSTALL_PLUGINS` / `GF_PLUGINS_INSTALL` | Deprecated | `GF_PLUGINS_PREINSTALL_SYNC=id@version` |
| `rate(x[1m])` with 60 s OTLP export | Gaps / empty graphs | `$__rate_interval` + datasource `timeInterval` = export interval |
| Folder annotation on a file-provisioned dashboard | File rejected ("folderUID does not match") | No annotation; the provider decides the folder |
| `gcx dev lint run <path>` as the quality gate | gcx 1.4.0 reported 0 violations even for broken PromQL | Review + a dev-instance render; don't rely on it |
| `gcx resources get dashboards` in your own scripts | Silently only the first 50 items | `--limit 0` |
| 5xx ratio without `or vector(0)` | Stat shows "No data" exactly when the service is healthy | `(sum(rate(…5..…)) or vector(0)) / sum(rate(…))` |
| Image renderer plugin (`GF_PLUGINS_PREINSTALL=grafana-image-renderer`) | Removed in 13 | Renderer service (self-hosting.md → renderer) |

## Official docs — verify, don't guess

Append `.md` to any grafana.com docs URL for raw Markdown.
- Grafana docs: https://grafana.com/docs/grafana/latest/ · upgrade guides: https://grafana.com/docs/grafana/latest/upgrade-guide/
- Docker: https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/ · configuration: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
- Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- As code (gcx, Git Sync, Foundation SDK): https://grafana.com/docs/grafana/latest/as-code/observability-as-code/ · gcx: https://github.com/grafana/gcx
- HTTP API (`/apis`): https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/apis/
- Dashboard best practices: https://grafana.com/docs/grafana/latest/visualizations/dashboards/build-dashboards/best-practices/
- Reverse proxy: https://grafana.com/tutorials/run-grafana-behind-a-proxy/
