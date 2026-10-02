# Best Practices: nginx + Let's Encrypt in front of ASP.NET Core

Verified against official documentation, July 2026. Sources: nginx.org/en/docs,
letsencrypt.org/docs, eff-certbot.readthedocs.io, and the Mozilla server-side TLS guidelines v6.0
(now hosted at configurator.tlsref.org). Full URL list at the bottom. This file extends SKILL.md —
read that first; nothing here overrides it. Docker builds, images, and compose: see the `docker`
skill.

## Current versions (July 2026)

- **nginx**: stable **1.30.3**, mainline **1.31.2**. `http2 on;` directive (since 1.25.1) replaces
  the legacy `listen ... http2` parameter. Since **1.29.7** `proxy_http_version` defaults to `1.1`
  (previously `1.0`) and accepts `2` for proxying — stable 1.30.x includes this.
- **HTTP/3** (`ngx_http_v3_module`) is still marked **experimental** and is not built by default
  (`--with-http_v3_module`); check `nginx -V` before enabling. Requires `listen 443 quic reuseport;`
  plus an `Alt-Svc: h3=":443"` header; 0-RTT needs OpenSSL 3.5.1+.
- **Let's Encrypt profiles** (select via ACME `profile`): `classic` = 90 days (default),
  `tlsserver` = 45 days, `shortlived` = 160 h (~6.7 days, no revocation/CRL URLs). `tlsclient` was
  discontinued 2026-07-08. Certbot selects with `--preferred-profile` / `--required-profile`.
  Max names per cert: `classic` 100, `tlsserver`/`shortlived` 25.
- **Lifetimes keep shrinking**: LE's `classic` goes to **64 days on 2027-02-10** and **45 days on
  2028-02-16** (authorization reuse 10 days, then 7 hours) — ahead of the CA/B Forum caps of 100 days
  (from 2027-03-15) and 47 days (from 2029-03-15). Only unattended, ARI-aware renewal survives this.
- **No expiry emails**: LE ended expiry notifications on 2025-06-04 — `--email` is now only an
  account contact; monitor certificate expiry yourself.
- **Let's Encrypt OCSP is gone**: responders shut down 2025-08-06; certificates carry CRL URLs
  instead. `ssl_stapling` in nginx is a no-op for LE certs — leave it out.

## Established patterns

### nginx reverse proxy correctness (nginx docs)

- Defaults worth knowing: `proxy_buffering on`, `proxy_connect_timeout 60s`,
  `proxy_read_timeout 60s`, `proxy_send_timeout 60s`, `proxy_request_buffering on`.
- **Keep buffering on** for normal API/static traffic — it shields Kestrel from slow clients. Turn it
  off *only* for streaming endpoints (SSE, long-poll): `proxy_buffering off;` in that location, or
  better, have ASP.NET Core send `X-Accel-Buffering: no` on streaming responses so nginx disables
  buffering per-response.
- **WebSockets/SignalR**: `proxy_http_version 1.1;` (explicit — required below nginx 1.29.7 and
  harmless above) plus `Upgrade` and `Connection $connection_upgrade` (the `map` idiom from the nginx
  WebSocket docs, as in SKILL.md). `proxy_read_timeout` kills idle sockets; SignalR's server pings
  every 15 s (`KeepAliveInterval`), so even the 60s default holds — raise it only for raw
  WebSockets without app-level pings.
- **Body size**: set `client_max_body_size` and Kestrel's `MaxRequestBodySize` (default ~28.6 MB)
  deliberately to the same value — nginx rejects larger bodies with 413 before the app sees them,
  and a higher nginx limit only buffers bodies Kestrel will reject anyway.
- **Upstream re-resolution**: a literal hostname in `proxy_pass` is resolved once at start/reload.
  In compose, use `resolver 127.0.0.11` + `upstream { zone …; server app:8080 resolve; }` (OSS
  since 1.27.3) so a recreated app container's new IP is picked up without a reload.
- **Catch-all server**: `listen 80 default_server; listen 443 ssl default_server;
  ssl_reject_handshake on; return 444;` — otherwise the first server block answers any Host header.
  Pair with `server_tokens off;` and a real `AllowedHosts` in the app.
- **`add_header` inheritance**: a level inherits `add_header` directives only if it defines none
  itself — one `add_header` in a `location` silently drops every server-level header.
  Repeat them, or use `add_header_inherit merge;` (since 1.29.3, so in stable 1.30).
- **Rate limiting at the edge**: `limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;` +
  `limit_req zone=login burst=5 nodelay;` on login/auth locations, `limit_conn` for connection
  floods. App-level rate limiting (ASP.NET Core) stays the source of truth for per-user limits.
- **IPv6**: add `listen [::]:80;` / `listen [::]:443 ssl;` (and `[::]` on the catch-all) only if
  Docker IPv6 is enabled for the published ports — binding fails in a container without IPv6.
- **Static assets**: the BFF serves the Angular build, so long-cache headers for hashed bundles
  (`Cache-Control: public, max-age=31536000, immutable`; `index.html` `no-cache`) belong in the app.
  Only if nginx serves the files itself, set them in a `location` there.
  The same goes for CSP and the other security headers (`bff-security`). If nginx ever serves
  `index.html` itself, it must send them — and with Angular `autoCsp`, without `script-src`/`default-src`.
- **HTTP/2**: `http2 on;` inside the `listen 443 ssl` server (SKILL.md already does this).
  **HTTP/3**: experimental — skip it for this stack until nginx promotes it; if you must, verify
  the module is compiled in and add the `quic` listener + `Alt-Svc` header.
- Compress in nginx only (gzip + `gzip_vary on;`) — never double-compress in Kestrel.

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
# HSTS is owned by the ASP.NET Core app (UseHsts, see bff-security) — don't also send it here,
# or browsers get the header twice. Only for non-.NET upstreams:
# add_header Strict-Transport-Security "max-age=63072000" always;
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
- Smoke-test the renewal path after setup and after any webroot/nginx change:
  `certbot renew --dry-run` (staging server, nothing saved).

## Anti-patterns

| Anti-pattern | Why it bites | Fix |
|---|---|---|
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 | Remove; CRL revocation needs nothing server-side |
| Enabling HTTP/3 because a blog said so | Module is experimental and often not compiled in | `nginx -V` and look for `http_v3_module`; skip until stable |
| `proxy_buffering off` globally "for performance" | Slow clients tie up Kestrel connections | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host | Per-hostname HTTP-01 certs; SAN list up to 100 names on `classic`, 25 on `tlsserver`/`shortlived` |
| Trusting all proxies in `ForwardedHeadersOptions` while publishing app port | Header spoofing → scheme/IP forgery | App port never published; narrow `KnownIPNetworks` to the compose network instead of leaving both lists empty (MS docs: trusting any source is "not recommended") |
| `Connection $http_connection` for WebSockets | Forwards whatever the client sent | `map $http_upgrade $connection_upgrade` (nginx WebSocket docs) |

## Sources

- https://nginx.org/en/download.html
- https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- https://nginx.org/en/docs/http/ngx_http_upstream_module.html#resolve
- https://nginx.org/en/docs/http/websocket.html
- https://nginx.org/en/docs/http/ngx_http_ssl_module.html#ssl_reject_handshake
- https://nginx.org/en/docs/http/ngx_http_headers_module.html#add_header
- https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
- https://nginx.org/en/docs/http/ngx_http_v2_module.html
- https://nginx.org/en/docs/http/ngx_http_v3_module.html
- https://letsencrypt.org/docs/challenge-types/
- https://letsencrypt.org/docs/profiles/
- https://letsencrypt.org/docs/integration-guide/
- https://letsencrypt.org/2024/12/05/ending-ocsp/
- https://letsencrypt.org/2025/01/22/ending-expiration-emails/
- https://letsencrypt.org/2025/12/02/from-90-to-45/
- https://learn.microsoft.com/aspnet/core/host-and-deploy/proxy-load-balancer
- https://eff-certbot.readthedocs.io/en/stable/using.html
- https://configurator.tlsref.org/ (Mozilla server-side TLS guidelines v6.0; ssl-config.mozilla.org redirects here)
