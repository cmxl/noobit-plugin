---
name: nginx-deploy
description: Use when configuring nginx — reverse proxy in front of ASP.NET Core, TLS/HTTPS/Let's Encrypt/certbot, HTTP/2, gzip, WebSocket/SignalR proxying, forwarded headers, production deployment, or exposing a hosted app stack to the internet.
---

# nginx reverse proxy + Let's Encrypt

## Overview

A single **nginx** reverse proxy terminates TLS with **Let's Encrypt** certs in front of the app container. Only nginx publishes ports (80/443). The BFF serves the Angular build output (same origin — see `bff-security`). Dockerfiles, images, and the surrounding compose stack (app/db/redis/rabbitmq, networks, secrets, healthchecks) live in the `docker` skill — this skill adds the two services below to that stack.

## nginx + certbot services (join the `docker` compose skeleton)

```yaml
  nginx:
    image: nginx:1.30-alpine   # pin the stable line, never a floating tag
    profiles: [prod]       # server .env: COMPOSE_PROFILES=prod — keeps nginx off dev machines
    restart: unless-stopped
    # periodic reload picks up renewed Let's Encrypt certs — the certbot container has no
    # docker CLI/socket, so a certbot --deploy-hook can NOT reload nginx from over there.
    # The script waits on nginx: if the nginx master dies the container exits and `restart:` recovers
    # it. The trap forwards docker stop (image STOPSIGNAL is SIGQUIT) as a graceful quit — a bare sh
    # as PID 1 ignores it and gets SIGKILLed after 10 s. Trade-off: overriding `command` skips the
    # image's /docker-entrypoint.d scripts (envsubst templates, IPv6 listen auto-patching).
    command: ["/bin/sh", "-c", "(while :; do sleep 6h; nginx -s reload; done) & nginx -g 'daemon off;' & n=$$!; trap 'nginx -s quit; wait $$n' TERM QUIT; wait $$n"]
    ports: ["80:80", "443:443"]
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - certbot-webroot:/var/www/certbot:ro
      - letsencrypt:/etc/letsencrypt:ro
    healthcheck:           # busybox wget; hits the loopback-only health server in app.conf
      test: ["CMD", "wget", "-qO", "/dev/null", "http://127.0.0.1:8081/nginx-health"]
      interval: 30s
      start_period: 10s
    depends_on:
      app: { condition: service_healthy }   # no 502 window at stack start
    networks: [edge]       # (+ `grafana` when the grafana skill adds Grafana) — never `backend`: nginx only talks to proxied services
    logging: { driver: local }
  certbot:
    image: certbot/certbot:v5.8.0
    profiles: [prod]
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c", "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot; sleep 12h & wait $${!}; done"]
    volumes:
      - certbot-webroot:/var/www/certbot
      - letsencrypt:/etc/letsencrypt
    networks: [edge]       # needs egress to Let's Encrypt — the backend network has none
    logging: { driver: local }
    # no healthcheck, deliberately: a renew loop that is idle 12 h has nothing to probe and nothing
    # depends on it — monitor certificate expiry instead
```

Plus two named volumes on the stack: `certbot-webroot: {}`, `letsencrypt: {}`.

## nginx server blocks (`nginx/conf.d/app.conf`)

```nginx
server_tokens off;
resolver 127.0.0.11 valid=10s;   # Docker's embedded DNS: re-resolve `app` after a redeploy
upstream app { zone app 64k; server app:8080 resolve; }   # OSS `resolve` needs nginx 1.27.3+
# '' '' (not the docs' '' close): no Connection header on plain requests keeps upstream keepalive on
map $http_upgrade $connection_upgrade { default upgrade; '' ''; }

server {                          # catch-all: unknown Host → 444 on :80, unknown SNI → TLS handshake refused on :443
    listen 80 default_server;
    listen 443 ssl default_server;
    ssl_reject_handshake on;      # no cert needed here
    return 444;
}
server {                          # container healthcheck only — loopback, never published
    listen 127.0.0.1:8081;
    access_log off;
    location = /nginx-health { return 200 "ok\n"; }
}
server {
    listen 80;
    server_name app.example.com;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}
server {                          # needs the cert on disk — see First-time cert issuance
    listen 443 ssl;
    http2 on;
    server_name app.example.com;
    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    gzip on; gzip_vary on; gzip_types application/json application/javascript text/css image/svg+xml;
    client_max_body_size 30000000;   # = Kestrel MaxRequestBodySize default (30,000,000 bytes) — change both together

    location / {
        proxy_pass http://app;     # upstream above — a literal app:8080 resolves once at startup
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # SignalR/WebSockets:
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        # proxy_read_timeout stays at its 60s default: SignalR pings every 15 s. Raise it per location
        # only for raw WebSockets without app-level pings or deliberately slow endpoints.
    }
}
```

ASP.NET Core side (required or Secure cookies + redirects break behind the proxy):

```csharp
// Set only in compose (docker skeleton: the edge subnet 172.28.0.0/16). Absent under `dotnet run` and
// WebApplicationFactory tests → keep the loopback-only defaults instead of crashing on a null Parse.
var knownNetwork = builder.Configuration["ForwardedHeaders:KnownNetwork"];
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    if (knownNetwork is null) return;
    // .NET 10: KnownNetworks + HttpOverrides.IPNetwork are [Obsolete] (ASPDEPR005) — use KnownIPNetworks
    // with System.Net.IPNetwork. Trust exactly the edge network nginx sits on, nothing else:
    o.KnownIPNetworks.Clear(); o.KnownProxies.Clear();
    o.KnownIPNetworks.Add(System.Net.IPNetwork.Parse(knownNetwork));
});
app.UseForwardedHeaders();   // first in the pipeline
```

Also set `AllowedHosts` (appsettings) to the real hostname(s) **plus `localhost`** instead of `*` (`app.example.com;localhost`) — defense in depth behind the catch-all server; `localhost` is needed because the in-container HEALTHCHECK sends `Host: localhost` and would otherwise get 400 (`noobit:aspnet-backend`).

## First-time cert issuance

The committed `app.conf` is final — no hand edits, no "enable the 443 block later". nginx can't start
until the certificate exists, so the first certificate is issued **before nginx ever starts**, with
certbot's standalone server on port 80:

1. On the fresh server, before the first `docker compose up`:
   `docker compose run --rm -p 80:80 --entrypoint certbot certbot certonly -n --standalone -d app.example.com --agree-tos -m ops@example.com --no-eff-email`
   `--entrypoint certbot` is required: the service's entrypoint is the renew loop, which would swallow
   `certonly …` as ignored script arguments and never issue the first certificate. (`run` starts the
   `prod`-profiled service without activating the profile.) With `-n` and no existing account, certbot
   aborts unless it gets `-m <email>` (account contact; `--no-eff-email` skips the newsletter prompt)
   or `--register-unsafely-without-email`. Let's Encrypt stopped expiry mails in June 2025 — the
   address is only a contact, so monitor expiry yourself either way.
2. `docker compose run --rm migrate` — schema before the app ever starts (the migration bundle
   copied to `migrations/` first, exactly as the `ci-pipelines` deploy does; `run` starts `db` via
   `depends_on`) — otherwise the app serves its first requests against missing tables.
3. `docker compose up -d` — nginx starts with every server block, the cert is on the shared volume.
4. Smoke-test webroot renewal now that nginx owns port 80:
   `docker compose run --rm --entrypoint certbot certbot reconfigure --cert-name app.example.com --webroot -w /var/www/certbot`
   Strictly redundant for the switch itself — the renew loop already passes `--webroot -w …`, which
   overrides the stored `standalone` method and is saved after the first successful renewal — but
   `reconfigure` runs a staging test renewal *now* and stores webroot immediately, so a broken
   challenge path surfaces today instead of in 60 days. Renewed certs are picked up by the nginx
   service's 6-hourly reload loop (see services above).
5. Later smoke tests (after any webroot/nginx change):
   `docker compose run --rm --entrypoint certbot certbot renew --dry-run` (staging server, nothing saved).

**Adding a hostname later** (nginx is running): add it to the port-80 `server_name` first, reload,
then issue with `--webroot -w /var/www/certbot` instead of `--standalone`, then add its 443 server.

## Common mistakes

| Mistake | Fix |
|---|---|
| Compression in Kestrel *and* nginx | nginx only |
| Missing `UseForwardedHeaders` | Scheme=http inside → Secure cookies dropped, wrong redirect URLs |
| Certs baked into images | letsencrypt volume shared nginx↔certbot |
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 — remove it |
| `proxy_buffering off` globally "for performance" | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host; per-hostname HTTP-01 instead |
| Trusting all proxies while publishing the app port | App port never published + `KnownIPNetworks` narrowed to the `edge` subnet |
| `IPNetwork.Parse(config["…"]!)` unconditionally | Throws under `dotnet run`/tests where the key is unset — apply only when configured |
| nginx starting before the first cert exists | Issue with `--standalone` before the first `up`, then `reconfigure` to webroot as smoke test |
| `certonly -n` without `-m`/`--register-unsafely-without-email` | Aborts on a fresh host (no ACME account yet) — pass `-m ops@example.com --no-eff-email` |
| `proxy_pass http://app:8080` (literal host) | Resolved once at startup → 502 after `up --no-deps app` gives a new IP; use `resolver` + `upstream … resolve` |
| No `default_server` | First server block catches every Host → Host-header poisoning; keep the catch-all |
| WebSocket map with `'' close` | Sends `Connection: close` on every plain request → no upstream keepalive (default since 1.29.7); map `''` to `''` |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- nginx: https://nginx.org/en/docs/
- certbot: https://certbot.eff.org/ | Let's Encrypt: https://letsencrypt.org/docs/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing config in this area.**
