---
name: bff-security
description: Use when implementing authentication, authorization, login/logout, external login (Sign in with GitHub/Discord/…), sessions, cookies, CSRF/XSRF, security headers, CSP/XSS hardening, password hashing, login rate limiting, Data Protection keys, YARP credential forwarding, SignalR/WebSocket auth, or connecting an Angular SPA to an ASP.NET Core API — the standard is a custom cookie BFF with no OIDC provider and no tokens in the browser.
---

# BFF Security (Cookie-based, no OIDC)

## Overview

The frontend never sees a token. The ASP.NET Core app is the **Backend for Frontend**: it owns authentication with cookie auth (ASP.NET Core Identity or a custom user store), serves/fronts the Angular app on the **same origin**, and proxies any downstream APIs server-side (YARP) attaching credentials there. Browser state = one HttpOnly session cookie + one readable XSRF cookie. No JWTs in localStorage, ever.

**Scope guard — this pattern is for first-party browser clients.** It does NOT fit: third-party/public API consumers, machine-to-machine callers, or native/mobile apps (no shared-origin cookie jar) — those need token-based auth (API keys, client-credentials, or OIDC if the project adds a provider). A service can serve both: cookie BFF endpoints for its own SPA *and* a separately-authenticated token surface for external consumers — keep the two auth schemes and route groups explicitly separate rather than weakening the cookie rules to accommodate outsiders.

**External login ("Sign in with Discord/GitHub/…") belongs here, not in the provider's skill:** the BFF runs the OAuth code flow server-side as an external login and then issues its own session cookie — provider tokens never reach the browser. (Linking a Discord account to an existing user, without making it the login, is `discord`.)

## Auth wiring

```csharp
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.Cookie.Name = "__Host-session";          // __Host- prefix: Secure, no Domain, Path=/
        o.Cookie.HttpOnly = true;
        o.Cookie.SecurePolicy = CookieSecurePolicy.Always;
        o.Cookie.SameSite = SameSiteMode.Strict;   // Lax if external links must land logged-in
        o.ExpireTimeSpan = TimeSpan.FromHours(8);
        o.SlidingExpiration = true;
        // APIs get status codes, not redirects to a login page (ignored once o.EventsType is set — see below):
        o.Events.OnRedirectToLogin = ctx => { ctx.Response.StatusCode = 401; return Task.CompletedTask; };
        o.Events.OnRedirectToAccessDenied = ctx => { ctx.Response.StatusCode = 403; return Task.CompletedTask; };
    });
builder.Services.AddAuthorization();
```

- Password hashing: ASP.NET Core Identity's hasher (PBKDF2) or `Isopoh.Cryptography.Argon2`; never roll your own.
- Login endpoint: rate-limited, lockout after N failures, uniform error message ("invalid credentials") regardless of which part failed, no user enumeration on registration/reset.
- .NET 10 returns 401/403 by itself only for endpoints it detects as API (JSON in/out, `TypedResults`, `[ApiController]`, SignalR) — a handler returning `string`/`IResult` still redirects. Also call `.DisableCookieRedirect()` on the `/api` group and on `MapReverseProxy()`.
- Session versioning: stamp a `SecurityStamp` claim and validate it in a `CookieAuthenticationEvents` subclass registered via `o.EventsType` so password change / "log out everywhere" kills existing cookies. **With `EventsType` set, the handler resolves that class from DI and ignores every `o.Events` lambda** — override `RedirectToLogin`/`RedirectToAccessDenied` in the class too (code in references).
- **Data protection keys must be persisted and shared across instances** or cookies die on every deploy/scale-out. Default: `PersistKeysToDbContext<T>` in the app database (durable, backed up). **Not** in the cache Redis — it evicts (`allkeys-lru`) and has persistence off (`fusioncache-redis`, `docker`), and losing the key ring logs every user out.

## CSRF — required because cookies

Angular's `HttpClient` sends `X-XSRF-TOKEN` automatically when it can read an `XSRF-TOKEN` cookie (same-origin only):

```csharp
builder.Services.AddAntiforgery(o =>
{
    o.HeaderName = "X-XSRF-TOKEN";
    o.Cookie.Name = "__Host-af";                        // default name has no __Host- prefix
    o.Cookie.SecurePolicy = CookieSecurePolicy.Always;  // default is None
});
// Between UseAuthentication and UseAuthorization, so a 401 still carries the cookie.
// OnStarting: the token is minted for the FINAL HttpContext.User (after login/logout changed it).
// /api only: GetAndStoreTokens forces Cache-Control: no-cache, no-store on the response — on static
// bundles or output-cached responses that would kill caching. /api/me (startup) and login/logout cover it.
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        ctx.Response.OnStarting(() =>
        {
            var tokens = ctx.RequestServices.GetRequiredService<IAntiforgery>().GetAndStoreTokens(ctx);
            ctx.Response.Cookies.Append("XSRF-TOKEN", tokens.RequestToken!,
                new CookieOptions { HttpOnly = false, Secure = true, SameSite = SameSiteMode.Strict });
            return Task.CompletedTask;
        });
    }
    await next();
});
```

Tokens are bound to the user identity and cached per request: after `SignInAsync` set `http.User = principal` (after `SignOutAsync`, `new ClaimsPrincipal(new ClaimsIdentity())`) so the login/logout response carries a token for the *new* identity — otherwise the next POST fails with 400.

Validate on every state-changing endpoint — and know that the built-in automatic validation does **not** cover you here: `UseAntiforgery()` auto-validates only endpoints with form-binding metadata (`[FromForm]`, `IFormFile`). JSON APIs (everything Angular sends) must validate explicitly — apply an endpoint filter on the `/api` group. Use `IsRequestValidAsync` (skips GET/HEAD/OPTIONS/TRACE, returns `false` on failure); `ValidateRequestAsync` *throws* and surfaces as a 500:

```csharp
api.AddEndpointFilter(async (ctx, next) =>
{
    var http = ctx.HttpContext;
    if (!await http.RequestServices.GetRequiredService<IAntiforgery>().IsRequestValidAsync(http))
        return TypedResults.Problem("Invalid or missing antiforgery token.", statusCode: StatusCodes.Status400BadRequest);
    return await next(ctx);
});
```

**Endpoint filters never run on `MapReverseProxy()` endpoints** — not even inside a filtered group. Validate in the proxy pipeline instead (references, YARP section). Login is a CSRF target too (login CSRF): keep it inside the validated group.

For genuine exceptions (webhooks), use `DisableAntiforgery()` on that endpoint and protect it another way: HMAC or provider signatures, verified either at ingress or — for payment providers — in a store-first inbox processor behind a body cap and rate limit (see the `paypal` skill).

## Same-origin layout

```
https://app.example.com/           → Angular static files (served by BFF MapFallbackToFile or nginx)
https://app.example.com/api/...    → BFF endpoints (cookie auth + antiforgery)
https://app.example.com/api/gw/... → YARP → downstream services (BFF attaches service credentials/headers)
```

- No CORS needed when same-origin — **do not** add permissive CORS instead of fixing origin layout.
- Downstream services live on a private network, never exposed publicly; they trust the BFF via network isolation + service credentials (API key / mTLS), and receive user identity as verified headers from the BFF, not from the client.
- Angular: `withXsrfConfiguration` defaults are correct; a 401 response triggers redirect to login route via interceptor; never store auth state beyond "who am I" from a `/api/me` endpoint. Call `GET /api/me` at app startup (`provideAppInitializer`) — when nginx serves `index.html`, that call is what first sets `XSRF-TOKEN`, and the login POST needs it.

## Security headers & middleware order

```csharp
// builder: HSTS is owned by the app (nginx doesn't send it) — UseHsts alone is only 30 days, no subdomains
builder.Services.AddHsts(o => { o.MaxAge = TimeSpan.FromDays(730); o.IncludeSubDomains = true; });
// o.Preload = true only as a deliberate opt-in: preload-list removal takes months

app.UseForwardedHeaders();       // needs ForwardedHeadersOptions + KnownIPNetworks — defaults ignore nginx in Docker (nginx-deploy)
if (!app.Environment.IsDevelopment()) app.UseHsts();
app.Use(async (ctx, next) =>
{
    var h = ctx.Response.Headers;
    // no script-src/default-src here: Angular's autoCsp <meta> owns script-src (see references)
    h.ContentSecurityPolicy = "object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'; style-src 'self' 'unsafe-inline'; upgrade-insecure-requests";
    h.XContentTypeOptions = "nosniff";
    h["Referrer-Policy"] = "strict-origin-when-cross-origin";
    await next();
});
app.UseAuthentication();
app.UseRateLimiter();            // AFTER authentication — before it, ctx.User is anonymous and identity partitions fall back to IP
// antiforgery cookie middleware (CSRF section)
app.UseAuthorization();
// endpoints
```

CSP for Angular is not a one-liner: runtime component `<style>` elements need a nonce or `'unsafe-inline'` in `style-src`, and `default-src 'self'` blocks them. Pick the static-hosting (`security.autoCsp`) or per-response-nonce policy from references. If nginx serves `index.html`, set the headers there too — app middleware only covers what the app serves. `AllowedHosts` (appsettings) lists the real hostname(s), never `*`: host filtering is the app's second line against Host-header poisoning behind nginx's catch-all server.

All endpoints `RequireAuthorization()` by default; opt **out** with `AllowAnonymous` (login, health, static) — never the reverse.

## Common mistakes

| Mistake | Fix |
|---|---|
| JWT in localStorage/sessionStorage | Cookie BFF — that's the whole point |
| API returns 302 to login page | 401/403 via cookie events (in the `EventsType` class once you have one) + `DisableCookieRedirect()` |
| `ValidateRequestAsync` in a filter | Throws → 500; use `IsRequestValidAsync` → 400 |
| Antiforgery filter assumed to cover `/api/gw/*` | Filters don't run on proxy endpoints; validate in the `MapReverseProxy` pipeline |
| `SameSite=None` "to make it work" | Fix same-origin layout instead |
| Antiforgery skipped on "internal" POSTs | Every state-changing browser-facing endpoint validates |
| Data protection keys in container FS or the cache Redis | `PersistKeysToDbContext<T>`; cookies survive redeploys, evictions and Redis restarts |
| Downstream API reachable from internet | Private network; only BFF is public |
| Login error says "user not found" | Uniform errors, rate limit, lockout |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing — for security code, never guess:
- ASP.NET Core security: https://learn.microsoft.com/en-us/aspnet/core/security/
- YARP: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/yarp-overview
- OWASP CSRF Prevention Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
