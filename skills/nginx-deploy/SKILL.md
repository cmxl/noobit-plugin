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
