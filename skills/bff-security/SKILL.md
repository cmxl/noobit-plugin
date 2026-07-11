---
name: bff-security
description: Use when implementing authentication, authorization, login/logout, sessions, cookies, CSRF/XSRF, security headers, or connecting an Angular SPA to an ASP.NET Core API — the standard is a custom cookie BFF with no OIDC provider and no tokens in the browser.
---

# BFF Security (Cookie-based, no OIDC)

## Overview

The frontend never sees a token. The ASP.NET Core app is the **Backend for Frontend**: it owns authentication with cookie auth (ASP.NET Core Identity or a custom user store), serves/fronts the Angular app on the **same origin**, and proxies any downstream APIs server-side (YARP) attaching credentials there. Browser state = one HttpOnly session cookie + one readable XSRF cookie. No JWTs in localStorage, ever.

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
        // APIs get status codes, not redirects to a login page:
        o.Events.OnRedirectToLogin = ctx => { ctx.Response.StatusCode = 401; return Task.CompletedTask; };
        o.Events.OnRedirectToAccessDenied = ctx => { ctx.Response.StatusCode = 403; return Task.CompletedTask; };
    });
builder.Services.AddAuthorization();
```

- Password hashing: ASP.NET Core Identity's hasher (PBKDF2) or `Isopoh.Cryptography.Argon2`; never roll your own.
- Login endpoint: rate-limited, lockout after N failures, uniform error message ("invalid credentials") regardless of which part failed, no user enumeration on registration/reset.
- Session versioning: stamp a `SecurityStamp` claim and validate in `OnValidatePrincipal` so password change / "log out everywhere" kills existing cookies.
- **Data protection keys must be persisted and shared across instances** (`PersistKeysToStackExchangeRedis`) or cookies die on every deploy/scale-out.

## CSRF — required because cookies

Angular's `HttpClient` sends `X-XSRF-TOKEN` automatically when it can read an `XSRF-TOKEN` cookie (same-origin only):

```csharp
builder.Services.AddAntiforgery(o => o.HeaderName = "X-XSRF-TOKEN");
// After auth middleware — issue the readable cookie:
app.Use(async (ctx, next) =>
{
    var af = ctx.RequestServices.GetRequiredService<IAntiforgery>();
    var tokens = af.GetAndStoreTokens(ctx);
    ctx.Response.Cookies.Append("XSRF-TOKEN", tokens.RequestToken!,
        new CookieOptions { HttpOnly = false, Secure = true, SameSite = SameSiteMode.Strict });
    await next();
});
```

Validate on every state-changing endpoint — and know that the built-in automatic validation does **not** cover you here: `UseAntiforgery()` auto-validates only endpoints with form-binding metadata (`[FromForm]`, `IFormFile`). JSON APIs (everything Angular sends) must validate explicitly — apply an endpoint filter on the `/api` group that calls `IAntiforgery.ValidateRequestAsync(ctx)` for non-GET/HEAD/OPTIONS requests:

```csharp
group.AddEndpointFilter(async (ctx, next) =>
{
    var http = ctx.HttpContext;
    if (!HttpMethods.IsGet(http.Request.Method) && !HttpMethods.IsHead(http.Request.Method)
        && !HttpMethods.IsOptions(http.Request.Method))
        await http.RequestServices.GetRequiredService<IAntiforgery>().ValidateRequestAsync(http);
    return await next(ctx);
});
```

For genuine exceptions (webhooks), use `DisableAntiforgery()` on that endpoint and protect it another way (HMAC signatures).

## Same-origin layout

```
https://app.example.com/           → Angular static files (served by BFF MapFallbackToFile or nginx)
https://app.example.com/api/...    → BFF endpoints (cookie auth + antiforgery)
https://app.example.com/api/gw/... → YARP → downstream services (BFF attaches service credentials/headers)
```

- No CORS needed when same-origin — **do not** add permissive CORS instead of fixing origin layout.
- Downstream services live on a private network, never exposed publicly; they trust the BFF via network isolation + service credentials (API key / mTLS), and receive user identity as verified headers from the BFF, not from the client.
- Angular: `withXsrfConfiguration` defaults are correct; a 401 response triggers redirect to login route via interceptor; never store auth state beyond "who am I" from a `/api/me` endpoint.

## Security headers & middleware order

```csharp
app.UseForwardedHeaders();       // nginx in front — X-Forwarded-For/Proto (see docker-nginx-deploy)
app.UseHsts();
// CSP etc. via middleware:
ctx.Response.Headers.ContentSecurityPolicy =
    "default-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
ctx.Response.Headers.XContentTypeOptions = "nosniff";
ctx.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
app.UseRateLimiter();            // global + stricter policy on /api/auth/*
app.UseAuthentication();
app.UseAuthorization();
// antiforgery cookie middleware, then endpoints
```

All endpoints `RequireAuthorization()` by default; opt **out** with `AllowAnonymous` (login, health, static) — never the reverse.

## Common mistakes

| Mistake | Fix |
|---|---|
| JWT in localStorage/sessionStorage | Cookie BFF — that's the whole point |
| API returns 302 to login page | 401/403 via cookie events (above) |
| `SameSite=None` "to make it work" | Fix same-origin layout instead |
| Antiforgery skipped on "internal" POSTs | Every state-changing browser-facing endpoint validates |
| Data protection keys in container FS | Persist to Redis; cookies survive redeploys |
| Downstream API reachable from internet | Private network; only BFF is public |
| Login error says "user not found" | Uniform errors, rate limit, lockout |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing — for security code, never guess:
- ASP.NET Core security: https://learn.microsoft.com/en-us/aspnet/core/security/
- YARP: https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/yarp-overview
- OWASP CSRF Prevention Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
