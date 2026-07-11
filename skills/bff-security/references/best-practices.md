# Cookie-BFF Security Best Practices (ASP.NET Core + Angular)

Verified against official documentation, July 2026. Extends `SKILL.md` — read that first; this file adds verified detail, exact APIs, and pitfalls. Primary sources: Microsoft Learn (ASP.NET Core 10 security docs, YARP), OWASP Cheat Sheet Series, angular.dev, IETF OAuth WG. Full URL list at the bottom.

## Current versions / current guidance (July 2026)

- **.NET 10 cookie auth returns 401/403 for API endpoints automatically.** Since ASP.NET Core 10, endpoints the framework recognizes as API-shaped (minimal API `MapGet`/`MapPost`/…, `[ApiController]` controllers, JSON-negotiating endpoints, SignalR) no longer redirect to a login page on auth failure — they get status codes out of the box. The explicit `OnRedirectToLogin`/`OnRedirectToAccessDenied` overrides in SKILL.md remain correct and act as a guarantee for anything the framework doesn't classify as API.
- **Antiforgery middleware does not protect JSON endpoints.** Per current docs, `UseAntiforgery()` validates only endpoints carrying `IAntiforgeryMetadata` with `RequiresValidation = true` (which form-binding minimal APIs get automatically), and only for POST/PUT/PATCH. JSON bodies never acquire that metadata, and DELETE is never auto-validated. Conclusion: the explicit `IAntiforgery.ValidateRequestAsync` endpoint filter from SKILL.md is mandatory, not optional.
- **IETF "OAuth 2.0 for Browser-Based Apps"** (draft-ietf-oauth-browser-based-apps-27, July 2026, intended status Best Current Practice) lists BFF as the *most secure* of its three architectures and calls it "strongly recommended for business applications, sensitive applications, and applications that handle personal data." Its core argument — no tokens in the browser, HttpOnly cookies as the only browser credential — applies verbatim to this stack even without OIDC.
- **SameSite is defense-in-depth only** (OWASP CSRF sheet): `Lax`/`Strict` scope is the *registrable site*, not the origin; `Lax` still allows top-level GET navigations; subdomain compromise bypasses it. Never treat SameSite as the CSRF defense — token validation is.
- **Angular support (angular.dev/reference/releases):** v22 active (June 2026), v21 and v20 in LTS (v20 LTS ends Nov 2026). `HttpClient` XSRF: an interceptor reads the `XSRF-TOKEN` cookie and adds `X-XSRF-TOKEN` **only on mutating requests to relative/same-origin URLs** — never on GET/HEAD, never on absolute cross-origin URLs.
- **Header housekeeping (OWASP):** `X-XSS-Protection` is deprecated — send `X-XSS-Protection: 0` or remove it; `Expect-CT` and HPKP are dead, do not use. Prefer CSP `frame-ancestors` over `X-Frame-Options` (send both only for legacy clients).

## Established patterns

### Cookie hardening (Microsoft Learn: cookie auth without Identity)

SKILL.md's `AddCookie` block is current. Verified additions:

- **Revocation / security stamp:** the cookie is the single source of identity; the server never re-checks the DB unless you make it. Implement `CookieAuthenticationEvents.ValidatePrincipal`, compare a stamp claim against the store, and on mismatch call `context.RejectPrincipal()` **plus** `SignOutAsync` to delete the cookie. Register with `options.EventsType` + a scoped DI registration. Docs warn this runs per request — keep the lookup a single indexed/cached read.

```csharp
public sealed class SecurityStampEvents(IUserStore users) : CookieAuthenticationEvents
{
    public override async Task ValidatePrincipal(CookieValidatePrincipalContext context)
    {
        var ct = context.HttpContext.RequestAborted;
        var userId = context.Principal?.FindFirstValue(ClaimTypes.NameIdentifier);
        var stamp = context.Principal?.FindFirstValue("security_stamp");
        if (userId is null || stamp is null || !await users.IsStampCurrentAsync(userId, stamp, ct))
        {
            context.RejectPrincipal();
            await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        }
    }
}
// builder.Services.AddScoped<SecurityStampEvents>();
// AddCookie(o => o.EventsType = typeof(SecurityStampEvents));
```

- **Sliding vs absolute:** `SlidingExpiration = true` + `ExpireTimeSpan` gives an idle timeout that renews forever. Setting `AuthenticationProperties.ExpiresUtc` at `SignInAsync` overrides `ExpireTimeSpan` and *disables sliding* for that ticket. To get both (OWASP session sheet: idle timeout 15–30 min typical, absolute 4–8 h for full-day apps), keep sliding config and enforce the absolute cap in `ValidatePrincipal` from an issued-at claim (`RejectPrincipal` past the cap).
- **Session fixation:** OWASP requires a new session identifier on any privilege change. Cookie auth mints a fresh encrypted ticket at every `SignInAsync`, so login is safe by construction — but if you also use `ISession`/server-side session state, regenerate it at login yourself.
- **Persistent cookies** (`IsPersistent = true`) only with an explicit "remember me" opt-in; default sessions should be non-persistent (browser-session cookies), per OWASP.
- **`__Host-` prefix** (SKILL.md) matches OWASP session guidance: requires `Secure`, no `Domain`, `Path=/` — the browser enforces it, killing subdomain cookie-tossing.
- **Logout** = `SignOutAsync` **and** bumping the security stamp if the intent is "log out everywhere"; deleting the cookie alone leaves stolen copies valid.

### Antiforgery for SPA/JSON (Microsoft Learn: anti-request-forgery)

- `AddAntiforgery(o => o.HeaderName = "X-XSRF-TOKEN")` + issue `GetAndStoreTokens(ctx).RequestToken` in a **readable** cookie named `XSRF-TOKEN` (`HttpOnly = false`, `Secure = true` — OWASP: the JS-readable token cookie is the one cookie that must not be HttpOnly). SKILL.md's middleware is the documented pattern.
- **Re-issue tokens after authentication.** Docs: refresh the token after the user signs in — antiforgery tokens are bound to the current user identity, so a token minted anonymously fails validation once signed in. Call `GetAndStoreTokens` again in the login endpoint's response path (the per-request middleware in SKILL.md achieves this automatically because it runs after auth on every response).
- The explicit endpoint filter must cover **every non-GET/HEAD/OPTIONS method including DELETE** (middleware auto-validation never covers DELETE). `DisableAntiforgery()` only for non-browser endpoints (webhooks) protected by HMAC/mTLS instead.
- ASP.NET Core's token is HMAC-protected via Data Protection and bound to the authenticated user — this satisfies OWASP's "signed double-submit with session binding" requirement; don't hand-roll a naive double-submit cookie.
- Defense-in-depth per OWASP: SameSite on both cookies + the fact that a custom header (`X-XSRF-TOKEN`) can't be set cross-origin without a CORS preflight. Layers, not replacements.

### Data protection keys in containers (Microsoft Learn: data protection configuration + key storage providers)

```csharp
builder.Services.AddDataProtection()
    .SetApplicationName("myapp")                                   // stable across deployments & instances
    .PersistKeysToStackExchangeRedis(redisMux, "DataProtection-Keys")
    .ProtectKeysWithCertificate(cert);                             // see warning below
```

- Package: `Microsoft.AspNetCore.DataProtection.StackExchangeRedis`. Alternatives: `PersistKeysToFileSystem` on a mounted volume, `PersistKeysToDbContext<T>` (EF Core), `PersistKeysToAzureBlobStorage`.
- **Documented warning:** specifying an explicit key location *deregisters encryption-at-rest* — keys are then stored in plaintext unless you add `ProtectKeysWith*` (certificate or Azure Key Vault). Do both in production.
- **Redis caveat (documented):** Redis does not persist to disk by default; a Redis restart can drop the key ring and invalidate every cookie and XSRF token. Enable Redis persistence (AOF/RDB) for the key database.
- `SetApplicationName` matters because the default app discriminator is the content-root path — identical in a container image, but set it explicitly so local/dev/staging and multi-instance deployments agree. Default key lifetime is 90 days (`SetDefaultKeyLifetime` to change).

### Rate limiting (Microsoft Learn: rate limiting middleware)

```csharp
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests; // do set this; 429 is not the default
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
        RateLimitPartition.GetFixedWindowLimiter(
            ctx.User.Identity?.Name ?? ctx.Connection.RemoteIpAddress?.ToString() ?? "anon",
            _ => new FixedWindowRateLimiterOptions { PermitLimit = 100, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    o.AddFixedWindowLimiter("auth", w => { w.PermitLimit = 5; w.Window = TimeSpan.FromMinutes(1); w.QueueLimit = 0; });
    o.OnRejected = (ctx, ct) =>
    {
        if (ctx.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retry))
            ctx.HttpContext.Response.Headers.RetryAfter = ((int)retry.TotalSeconds).ToString();
        return ValueTask.CompletedTask;
    };
});
app.UseRateLimiter();                                   // after UseRouting when using per-endpoint policies
authGroup.RequireRateLimiting("auth");                  // /api/auth/* gets the strict policy
```

- `QueueLimit = 0` on auth endpoints: reject immediately, don't queue brute-force traffic.
- **Documented DoS warning:** partitioning on client IP is spoofable and behind a proxy every request shares the proxy IP — configure `UseForwardedHeaders` correctly first, and prefer user identity as the partition key once authenticated.
- Rate limiting is not DDoS protection; that belongs at the edge (WAF/CDN), per docs.

### Security headers with a verified Angular CSP (OWASP HTTP Headers + CSP sheets, angular.dev)

OWASP-recommended values: `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` · `X-Content-Type-Options: nosniff` · `Referrer-Policy: strict-origin-when-cross-origin` · `Permissions-Policy: geolocation=(), camera=(), microphone=()` (deny what you don't use) · `Cross-Origin-Opener-Policy: same-origin` · `Cross-Origin-Resource-Policy: same-site` · remove `Server`/`X-Powered-By` · `Cache-Control: no-store` on authenticated API responses.

CSP — angular.dev documents this minimal policy for a new Angular app:

```
default-src 'self'; style-src 'self' 'nonce-{RANDOM}'; script-src 'self' 'nonce-{RANDOM}';
```

Harden it with the OWASP additions: `object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'; upgrade-insecure-requests`. The nonce covers Angular's runtime-injected component `<style>` elements: generate a fresh nonce per response when serving `index.html` and stamp it on the root element (`<app-root ngCspNonce="{RANDOM}">`) or provide the `CSP_NONCE` injection token. A static-file-served SPA cannot do per-response nonces — either template `index.html` through the BFF, or fall back to `style-src 'self' 'unsafe-inline'` (accepting OWASP's caveat that `'unsafe-inline'` is a migration compromise; keep `script-src` free of it — Angular production builds need no inline scripts).

### Angular client specifics (angular.dev/best-practices/security)

- XSRF: `provideHttpClient(withXsrfConfiguration({ cookieName: 'XSRF-TOKEN', headerName: 'X-XSRF-TOKEN' }))` — the defaults already match the BFF config; only mutating same-origin **relative-URL** requests get the header, so call the API via relative paths (`/api/...`), never an absolute URL, or the header is silently dropped. `withNoXsrfProtection()` exists — never use it here.
- Auth state is a signal derived from the server, nothing more:

```ts
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  readonly user = signal<CurrentUser | null>(null);
  readonly isAuthenticated = computed(() => this.user() !== null);
  async refresh(): Promise<void> {
    this.user.set(await firstValueFrom(this.http.get<CurrentUser>('/api/me')));
  }
}
```

  A functional interceptor maps 401 → clear the signal + navigate to the login route. No token handling anywhere.
- XSS: rely on Angular's default sanitization; treat every `bypassSecurityTrust*` call as a security review item; build AOT (default) — never assemble templates from user data. For Trusted Types enforcement add `require-trusted-types-for 'script'` with policies `angular` (+ `angular#bundler`; `angular#unsafe-bypass` only if DomSanitizer bypasses exist).

### YARP header/credential hygiene (Microsoft Learn: YARP transforms)

Defaults (verified): YARP **suppresses the incoming `Host` header** (destination host is used — keep it that way; `RequestHeaderOriginalHost` only for virtual-hosting backends), and sets `X-Forwarded-For/-Proto/-Host/-Prefix` on proxy requests, replacing inbound values so clients can't smuggle forged forwarding headers. All other request headers are copied (`RequestHeadersCopy` default `true`) — **including `Cookie` and `X-XSRF-TOKEN`**. The browser's session must terminate at the BFF:

```csharp
builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(ctx => ctx.AddRequestTransform(t =>
    {
        t.ProxyRequest.Headers.Remove("Cookie");        // browser credentials never leave the BFF
        t.ProxyRequest.Headers.Remove("X-XSRF-TOKEN");
        t.ProxyRequest.Headers.TryAddWithoutValidation("X-Service-Key", serviceKey); // BFF credential
        var sub = t.HttpContext.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (sub is not null) t.ProxyRequest.Headers.TryAddWithoutValidation("X-User-Id", sub);
        return ValueTask.CompletedTask;
    }));
```

Put `MapReverseProxy()` behind the same `RequireAuthorization()` + antiforgery filter as native endpoints (routes also support `AuthorizationPolicy` in `RouteConfig`). Downstream services must trust these identity headers only from the private network + service credential — never from a public interface.

### Login endpoint hardening (OWASP Authentication cheat sheet)

- **One error for everything:** "Invalid user ID or password" for unknown user, wrong password, and locked account alike — login, registration, and password reset must all be non-enumerable.
- **Uniform timing:** run the same work on every path — when the user doesn't exist, verify the password against a fixed dummy hash so response time doesn't reveal account existence.
- **Lockout:** threshold + observation window + duration; OWASP suggests exponential backoff (1 s doubling) over hard lockout to blunt lockout-as-DoS; combine with the `"auth"` rate-limit policy above and log every failure and lockout for review.
- **Hashing:** Argon2id preferred, PBKDF2 acceptable (OWASP Password Storage sheet) — matches SKILL.md; never roll your own.

```csharp
authGroup.MapPost("/login", async Task<Results<Ok, UnauthorizedHttpResult>> (
    LoginRequest req, IUserService users, HttpContext http, CancellationToken ct) =>
{
    var user = await users.FindByEmailAsync(req.Email, ct);
    var valid = users.VerifyPassword(user, req.Password)   // verifies dummy hash when user is null
                && user is { IsLockedOut: false };
    if (!valid)
    {
        await users.RegisterFailedAttemptAsync(req.Email, ct);
        return TypedResults.Unauthorized();                 // same body, same timing, every failure
    }
    await http.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme,
        users.CreatePrincipal(user), new AuthenticationProperties());
    return TypedResults.Ok();
}).AllowAnonymous().RequireRateLimiting("auth");
```

## Anti-patterns

| Anti-pattern | Why it fails | Fix |
|---|---|---|
| Trusting `UseAntiforgery()` to protect JSON APIs | Middleware validates only form-metadata endpoints, POST/PUT/PATCH only | Explicit `ValidateRequestAsync` endpoint filter on the whole `/api` group |
| Relying on `SameSite=Strict` instead of tokens | Site-scoped not origin-scoped; subdomains and client-side CSRF bypass it (OWASP) | SameSite **and** antiforgery validation |
| Calling the API with absolute URLs from Angular | `HttpClient` skips `X-XSRF-TOKEN` on absolute URLs → mysterious 400s | Relative `/api/...` paths only |
| `PersistKeysTo*` without `ProtectKeysWith*` | Explicit persistence disables encryption-at-rest (documented) | Add certificate/Key Vault protection |
| Data protection keys in default-config Redis | Redis restart drops keys → all sessions and XSRF tokens die | Enable Redis AOF/RDB persistence |
| Sliding expiration with no absolute cap | Active session lives forever; stolen cookie too | Absolute cap via issued-at claim in `ValidatePrincipal` (OWASP: 4–8 h) |
| Logout that only deletes the cookie | Stolen/other-device copies stay valid until expiry | Bump security stamp; `ValidatePrincipal` rejects old tickets |
| YARP forwarding `Cookie` downstream | Session cookie leaks to every internal service; replayable | Strip `Cookie`/`X-XSRF-TOKEN` in a request transform; attach service credential |
| Rate-limit partition on client IP behind a proxy | All users share the proxy IP; spoofable (documented DoS warning) | `UseForwardedHeaders` first; partition on identity where possible |
| Different login errors / response times per failure cause | User enumeration + timing oracle (OWASP) | Uniform message, dummy-hash verification, uniform path |
| `X-XSS-Protection: 1; mode=block` "for extra safety" | Deprecated; the auditor itself enabled attacks (OWASP) | Send `0` or remove; use CSP |
| Anti-CSRF token cookie marked HttpOnly | Angular can't read it → no header → all writes fail, tempting devs to disable CSRF | `XSRF-TOKEN` cookie is intentionally readable; the session cookie is the HttpOnly one |

## Sources

- https://learn.microsoft.com/en-us/aspnet/core/security/authentication/cookie?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/authentication/api-endpoint-auth?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/configuration/overview?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/implementation/key-storage-providers?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/performance/rate-limit?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/yarp-overview?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/transforms?view=aspnetcore-10.0
- https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
- https://angular.dev/best-practices/security
- https://angular.dev/api/core/CSP_NONCE
- https://angular.dev/reference/releases
- https://datatracker.ietf.org/doc/draft-ietf-oauth-browser-based-apps/ (draft-27, July 2026, intended BCP)
