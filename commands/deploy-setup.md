---
description: Generate/refresh Docker, nginx, and Let's Encrypt deployment assets for the current project
argument-hint: [domain] (e.g. app.example.com)
---

Generate or update production deployment assets for the current project, per the `docker-nginx-deploy` skill (load it first). Domain argument: "$1" — if that is blank, use a `DOMAIN` placeholder throughout and say so in your report.

1. **Inventory the project**: detect the .NET host project(s), Angular app, database provider, Redis/RabbitMQ usage (check csproj packages, appsettings, existing compose files). Base everything on what the project actually uses — don't add services it doesn't need.
2. **Create/refresh**, preserving any existing customizations you find (read existing files first; merge, don't clobber):
   - Multi-stage `Dockerfile` (non-root, healthcheck, Angular build stage if a frontend exists)
   - `compose.yaml` (internal network, healthchecks, no published DB/cache ports) + `compose.override.yaml` for local dev
   - `nginx/conf.d/<domain>.conf` (TLS, HTTP→HTTPS redirect, ACME webroot, proxy headers, websocket support)
   - certbot service + first-issuance instructions
   - `.env.example` covering every env var referenced
   - Verify `UseForwardedHeaders` is configured in the app; add it if missing.
3. **Validate**: `docker compose config -q`, then `docker build` the image — if Docker isn't running, start it and wait for readiness first (procedure in `dotnet-testing`); only skip the build with an explicit note if it can't be started. Report results honestly.
4. Update `docs/deployment.md` (via the `docs-maintenance` conventions) with the real commands for this project.
