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
| `ssl_stapling on` with Let's Encrypt | LE OCSP responders shut down Aug 2025 | Remove; CRL revocation needs nothing server-side |
| Enabling HTTP/3 because a blog said so | Module is experimental and often not compiled in | `nginx -V` and look for `http_v3_module`; skip until stable |
| `proxy_buffering off` globally "for performance" | Slow clients tie up Kestrel connections | Keep on; disable per-location or via `X-Accel-Buffering: no` for streams only |
| Wildcard cert "to keep it simple" | Forces DNS-01 + API creds on the host | Per-hostname HTTP-01 certs; SAN list up to 100 names on `classic` |
| Trusting all proxies in `ForwardedHeadersOptions` while publishing app port | Header spoofing → scheme/IP forgery | Only nginx is reachable (internal network), app port never published — then clearing known networks is safe |

## Sources

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
