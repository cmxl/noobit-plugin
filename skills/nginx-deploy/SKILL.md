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
    depends_on: [app]
    networks: [internal]
  certbot:
    image: certbot/certbot:v5.8.0
    profiles: [prod]
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c", "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot; sleep 12h & wait $${!}; done"]
    volumes:
      - certbot-webroot:/var/www/certbot
      - letsencrypt:/etc/letsencrypt
```

Plus two named volumes on the stack: `certbot-webroot: {}`, `letsencrypt: {}`.

## nginx server block

```nginx
server_tokens off;
resolver 127.0.0.11 valid=10s;   # Docker's embedded DNS: re-resolve `app` after a redeploy
upstream app { zone app 64k; server app:8080 resolve; }   # OSS `resolve` needs nginx 1.27.3+
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {                          # catch-all: unknown Host/SNI never reaches the app
    listen 80 default_server;
    listen 443 ssl default_server;
    ssl_reject_handshake on;      # no cert needed here
    return 444;
}
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
    // Defaults trust loopback only; nginx is another container. Clearing both trusts ANY source —
    // safe only while the app port is never published. Narrow it to the compose network's fixed
    // subnet (docker skeleton: 172.28.0.0/16), read from config so compose and app change together:
    o.KnownIPNetworks.Clear(); o.KnownProxies.Clear();
    o.KnownIPNetworks.Add(System.Net.IPNetwork.Parse(builder.Configuration["ForwardedHeaders:KnownNetwork"]!));
});
app.UseForwardedHeaders();   // first in the pipeline
```

Also set `AllowedHosts` (appsettings) to the real hostname(s) instead of `*` — defense in depth behind the catch-all server.

## First-time cert issuance

1. Start nginx with only the port-80 server block (plus the catch-all — it needs no cert).
2. `docker compose run --rm --entrypoint certbot certbot certonly -n --webroot -w /var/www/certbot -d app.example.com --agree-tos`
   `--entrypoint certbot` is required: the service's entrypoint is the renew loop, which would swallow
   `certonly …` as ignored script arguments and never issue the first certificate. No `--email`
   needed with `-n`: Let's Encrypt stopped expiry mails in June 2025, so monitor expiry yourself;
   add `-m you@example.com --no-eff-email` only if you want an account contact.
3. Enable the 443 block, `docker compose exec nginx nginx -s reload`. Renewal is handled by the certbot loop; renewed certs are picked up by the nginx service's 6-hourly reload loop (see services above).
4. Smoke-test renewal: `docker compose run --rm --entrypoint certbot certbot renew --dry-run` (staging server, nothing saved).

## Common mistakes

| Mistake | Fix |
|---|---|
| Compression in Kestrel *and* nginx | nginx only |
| Missing `UseForwardedHeaders` | Scheme=http inside → Secure cookies dropped, wrong redirect URLs |
| Certs baked into images | letsencrypt volume shared nginx↔certbot |
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 — remove it |
| `proxy_buffering off` globally "for performance" | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host; per-hostname HTTP-01 instead |
| Trusting all proxies while publishing the app port | App port never published + `KnownIPNetworks` narrowed to the compose network |
| `proxy_pass http://app:8080` (literal host) | Resolved once at startup → 502 after `up --no-deps app` gives a new IP; use `resolver` + `upstream … resolve` |
| No `default_server` | First server block catches every Host → Host-header poisoning; keep the catch-all |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- nginx: https://nginx.org/en/docs/
- certbot: https://certbot.eff.org/ | Let's Encrypt: https://letsencrypt.org/docs/
- **Established patterns & current versions (verified July 2026): [references/best-practices.md](references/best-practices.md) — read it before writing config in this area.**
