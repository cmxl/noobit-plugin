---
name: docker-nginx-deploy
description: Use when containerizing or deploying — Dockerfiles, docker compose, nginx reverse proxy config, TLS/HTTPS/Let's Encrypt/certbot, health checks, or hosting an ASP.NET Core + Angular app in production.
---

# Docker + nginx + Let's Encrypt

## Overview

Standard hosting: everything in Docker Compose behind a single **nginx** reverse proxy that terminates TLS with **Let's Encrypt** certs. The BFF serves the Angular build output (same origin — see `bff-security`). Databases/Redis/RabbitMQ are on an internal compose network, never published.

## .NET Dockerfile (multi-stage, non-root)

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Directory.*.props Directory.Build.rsp* global.json* nuget.config* ./
COPY src/App.Api/App.Api.csproj src/App.Api/
RUN dotnet restore src/App.Api/App.Api.csproj        # layer-cached restore
COPY src/ src/
RUN dotnet publish src/App.Api/App.Api.csproj -c Release -o /app /p:UseAppHost=false

FROM node:22 AS ngbuild
WORKDIR /web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npm run build -- --configuration production

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
# aspnet images ship with NEITHER wget NOR curl — install one or the HEALTHCHECK reports unhealthy forever
RUN apt-get update && apt-get install -y --no-install-recommends wget && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
COPY --from=ngbuild /web/dist/app/browser wwwroot/   # adjust "app" to the Angular project name
USER $APP_UID                                        # non-root
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:8080/health/live || exit 1
ENTRYPOINT ["dotnet", "App.Api.dll"]
```

For a smaller attack surface, `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled` (stable main repo, not `nightly`) — but chiseled has no shell at all, so drop the Dockerfile HEALTHCHECK and probe `/health` from nginx or a sidecar instead.

## Compose skeleton

```yaml
services:
  app:
    build: .
    restart: unless-stopped
    environment:
      ASPNETCORE_URLS: http://+:8080
      ConnectionStrings__Default: ${DB_CONNECTION}
      ConnectionStrings__Redis: redis:6379
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    networks: [internal]
  db:
    image: postgres:17
    volumes: [dbdata:/var/lib/postgresql/data]
    environment: { POSTGRES_PASSWORD: ${DB_PASSWORD} }
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U postgres"], interval: 10s }
    networks: [internal]
  redis:
    image: redis:8
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 10s }
    networks: [internal]
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
networks: { internal: {} }
volumes: { dbdata: {}, certbot-webroot: {}, letsencrypt: {} }
```

Secrets via `.env` (gitignored) or docker secrets — never in the compose file. RabbitMQ when needed: `rabbitmq:4-management`, health `rabbitmq-diagnostics -q ping`, management UI bound to localhost only.

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
3. Enable the 443 block, `docker compose exec nginx nginx -s reload`. Renewal is handled by the certbot loop; renewed certs are picked up by the nginx service's 6-hourly reload loop (see compose above).

## Common mistakes

| Mistake | Fix |
|---|---|
| Publishing db/redis/rabbit ports to host | Internal network only; `ports:` solely on nginx |
| Compression in Kestrel *and* nginx | nginx only |
| Missing `UseForwardedHeaders` | Scheme=http inside → Secure cookies dropped, wrong redirect URLs |
| `latest` image tags in prod | Pin major versions |
| Certs baked into images | letsencrypt volume shared nginx↔certbot |
| Running as root | `USER $APP_UID`; writable paths mounted explicitly |
| No healthchecks | Every service defines one; `depends_on.condition: service_healthy` |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- Docker: https://docs.docker.com/ (Compose: https://docs.docker.com/compose/)
- Official .NET images: https://github.com/dotnet/dotnet-docker
- nginx: https://nginx.org/en/docs/
- certbot: https://certbot.eff.org/ | Let's Encrypt: https://letsencrypt.org/docs/
