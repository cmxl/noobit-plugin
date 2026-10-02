# Cookie-BFF Security Best Practices (ASP.NET Core + Angular)

Verified against official documentation, July 2026. Extends `SKILL.md` — read that first; this file adds verified detail, exact APIs, and pitfalls. Primary sources: Microsoft Learn (ASP.NET Core 10 security docs, YARP), OWASP Cheat Sheet Series, angular.dev, IETF OAuth WG. Full URL list at the bottom.

## Current versions / current guidance (July 2026)

- **.NET 10 cookie auth returns 401/403 only for endpoints it detects as API.** The framework adds `IDisableCookieRedirectMetadata` to `[ApiController]` controllers, minimal APIs that read a JSON body or write JSON, endpoints with `TypedResults` return types, and SignalR. Detection is metadata-based, not `Accept`-header- or `Map{Verb}`-based: a handler declared as returning `void`, `string` or `IResult` (e.g. `MapGet("/x", () => "hi").RequireAuthorization()`) **still redirects**, and so do YARP proxy endpoints. Make it explicit with `.DisableCookieRedirect()` on the `/api` group and on `MapReverseProxy()`, and keep the `RedirectToLogin`/`RedirectToAccessDenied` overrides as the guarantee (`AllowCookieRedirect()` / `[AllowCookieRedirect]` opt back in; the `Microsoft.AspNetCore.Authentication.Cookies.IgnoreRedirectMetadata` switch restores pre-10 behavior app-wide).
- **Antiforgery middleware does not protect JSON endpoints.** Per current docs, `UseAntiforgery()` validates only endpoints carrying `IAntiforgeryMetadata` with `RequiresValidation = true` (which form-binding minimal APIs get automatically), and only for POST/PUT/PATCH. JSON bodies never acquire that metadata, and DELETE is never auto-validated. Conclusion: the explicit endpoint filter from SKILL.md is mandatory, not optional — and it must use `IsRequestValidAsync` (returns `true` for GET/HEAD/OPTIONS/TRACE, `false` on a bad token). `ValidateRequestAsync` throws `AntiforgeryValidationException`, which nothing in a minimal-API filter chain maps to 400 — verified: a tokenless POST returns **500**.
- **Endpoint filters don't run on YARP endpoints.** `AddEndpointFilter` is applied by the route-handler (minimal API) endpoint factory only; `MapReverseProxy()` endpoints ignore it — verified both for `MapReverseProxy().AddEndpointFilter(...)` and for a proxy mapped inside a filtered `MapGroup("/api")`: the filter never ran and the POST was proxied. CSRF validation for `/api/gw/*` belongs in the proxy pipeline (YARP section).
- **IETF "OAuth 2.0 for Browser-Based Apps"** (draft-ietf-oauth-browser-based-apps-27, July 2026, intended status Best Current Practice) lists BFF as the *most secure* of its three architectures and calls it "strongly recommended for business applications, sensitive applications, and applications that handle personal data." Its core argument — no tokens in the browser, HttpOnly cookies as the only browser credential — applies verbatim to this stack even without OIDC.
- **SameSite is defense-in-depth only** (OWASP CSRF sheet): `Lax`/`Strict` scope is the *registrable site*, not the origin; `Lax` still allows top-level GET navigations; subdomain compromise bypasses it. Never treat SameSite as the CSRF defense — token validation is.
- **Angular support (angular.dev/reference/releases):** v22 active (June 2026), v21 and v20 in LTS (v20 LTS ends Nov 2026). `HttpClient` XSRF: an interceptor reads the `XSRF-TOKEN` cookie and adds `X-XSRF-TOKEN` on mutating requests to **relative and same-origin URLs** (absolute same-origin URLs work) — never on GET/HEAD, never on cross-origin URLs.
- **Header housekeeping (OWASP):** `X-XSS-Protection` is deprecated — send `X-XSS-Protection: 0` or remove it; `Expect-CT` and HPKP are dead, do not use. Prefer CSP `frame-ancestors` over `X-Frame-Options` (send both only for legacy clients).

## Established patterns

### Cookie hardening (Microsoft Learn: cookie auth without Identity)

SKILL.md's `AddCookie` block is current. Verified additions:

- **Revocation / security stamp:** the cookie is the single source of identity; the server never re-checks the DB unless you make it. Implement `CookieAuthenticationEvents.ValidatePrincipal`, compare a stamp claim against the store, and on mismatch call `context.RejectPrincipal()` **plus** `SignOutAsync` to delete the cookie. Register with `options.EventsType` + a scoped DI registration. Docs warn this runs per request — keep the lookup a single indexed read, or cache it (below).
- **`EventsType` replaces `o.Events` entirely.** The handler resolves the `EventsType` instance from DI *instead of* `Options.Events`, so the `OnRedirectToLogin`/`OnRedirectToAccessDenied` lambdas from SKILL.md are silently dropped — verified: with `EventsType` set, an unauthenticated non-API endpoint went back to 302. Override the redirects in the class:

```csharp
public sealed class SecurityStampEvents(ISessionStampStore stamps) : CookieAuthenticationEvents
{
    public override async Task ValidatePrincipal(CookieValidatePrincipalContext context)
    {
        var ct = context.HttpContext.RequestAborted;
        var userId = context.Principal?.FindFirstValue(ClaimTypes.NameIdentifier);
        var stamp = context.Principal?.FindFirstValue("security_stamp");
        if (userId is null || stamp is null || !await stamps.IsStampCurrentAsync(userId, stamp, ct))
        {
            context.RejectPrincipal();
            await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        }
    }

    // o.Events is ignored once EventsType is set — the 401/403 overrides live here now
    public override Task RedirectToLogin(RedirectContext<CookieAuthenticationOptions> context)
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        return Task.CompletedTask;
    }

    public override Task RedirectToAccessDenied(RedirectContext<CookieAuthenticationOptions> context)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        return Task.CompletedTask;
    }
}
// builder.Services.AddScoped<SecurityStampEvents>();
// AddCookie(o => o.EventsType = typeof(SecurityStampEvents));   // drop the o.Events lambdas
```

  `ISessionStampStore` is your own app interface (named to avoid ASP.NET Core Identity's `IUserStore<TUser>`); with Identity, use its `SecurityStampValidator` instead of hand-rolling.
- **Cache the stamp check:** `ValidatePrincipal` runs on every authenticated request (sliding expiration keeps sessions alive, so the cost never stops). Read the stamp through FusionCache (key `stamp:{userId}`, short duration) and `RemoveAsync` that key when the stamp changes with background distributed/backplane operations switched off for that call (`o => { o.AllowBackgroundDistributedCacheOperations = false; o.AllowBackgroundBackplaneOperations = false; }`) — with the default background operations the eviction reaches other nodes only shortly after `RemoveAsync` returns (`fusioncache-redis`: invalidation is not instantly global). A cache factory must not capture the request-scoped DbContext (`fusioncache-redis`).

- **Sliding vs absolute:** `SlidingExpiration = true` + `ExpireTimeSpan` gives an idle timeout that renews forever. Setting `AuthenticationProperties.ExpiresUtc` at `SignInAsync` overrides `ExpireTimeSpan` and *disables sliding* for that ticket. To get both (OWASP session sheet: idle timeout 15–30 min typical, absolute 4–8 h for full-day apps), keep sliding config and enforce the absolute cap in `ValidatePrincipal` from an issued-at claim (`RejectPrincipal` past the cap).
- **Session fixation:** OWASP requires a new session identifier on any privilege change. Cookie auth mints a fresh encrypted ticket at every `SignInAsync`, so login is safe by construction — but if you also use `ISession`/server-side session state, regenerate it at login yourself.
- **Persistent cookies** (`IsPersistent = true`) only with an explicit "remember me" opt-in; default sessions should be non-persistent (browser-session cookies), per OWASP.
- **`__Host-` prefix** (SKILL.md) matches OWASP session guidance: requires `Secure`, no `Domain`, `Path=/` — the browser enforces it, killing subdomain cookie-tossing.
- **Logout** = `SignOutAsync` **and** bumping the security stamp if the intent is "log out everywhere"; deleting the cookie alone leaves stolen copies valid.
- **Using ASP.NET Core Identity's `MapIdentityApi`:** `AddIdentityApiEndpoints` activates cookies *and* proprietary bearer tokens, and `POST /login` returns tokens to the caller unless `?useCookies=true` — i.e. tokens in the browser. For this stack register cookies only (`AddAuthentication(IdentityConstants.ApplicationScheme).AddIdentityCookies()`, as in the Blazor standalone-with-Identity doc), always call `/login?useCookies=true`, and map the endpoints inside the antiforgery-filtered `/api` group — they are JSON endpoints like any other.
- **Passkeys (.NET 10):** Identity now supports WebAuthn passkeys (`SignInManager.MakePasskeyCreationOptionsAsync` / `PasskeySignInAsync`, `IdentityPasskeyOptions`). They are a primary, phishing-resistant factor — not a built-in 2FA step — and only the Blazor template ships UI, so an Angular client wires the WebAuthn calls itself. Set `IdentityPasskeyOptions.ServerDomain` explicitly rather than trusting the Host header. A custom (non-Identity) user store gets nothing here — that is a library decision for an ADR, not an inline add.

### Antiforgery for SPA/JSON (Microsoft Learn: anti-request-forgery)

- `AddAntiforgery` + issue `GetAndStoreTokens(ctx).RequestToken` in a **readable** cookie named `XSRF-TOKEN` (`HttpOnly = false`, `Secure = true` — OWASP: the JS-readable token cookie is the one cookie that must not be HttpOnly). SKILL.md's middleware is the documented pattern, with two hardenings:
  - **Antiforgery cookie defaults are weak:** the docs state the antiforgery cookie's `SecurePolicy` defaults to `None`, and its default name has no prefix. Set `o.Cookie.Name = "__Host-af"` + `o.Cookie.SecurePolicy = CookieSecurePolicy.Always` (the `__Host-` prefix also requires `Path=/` and no `Domain` — don't set a `PathBase`-scoped path).
  - **Mint the readable token in `Response.OnStarting`**, from middleware placed between `UseAuthentication` and `UseAuthorization`: 401 responses (e.g. the startup `GET /api/me` while logged out) still carry the cookie, and the token reflects the request's *final* `HttpContext.User`. Register the callback for `/api` requests only: `GetAndStoreTokens` calls `SetDoNotCacheHeaders`, which overwrites `Cache-Control` with `no-cache, no-store` ("overrides any user set value" — `DefaultAntiforgery` source), so on static bundles, proxied or output-cached responses it would disable caching.
- **Re-issue tokens after login/logout — it is not automatic.** Tokens are bound to the identity in `HttpContext.User`, and `IAntiforgery` caches the generated request token for the rest of the request. Without intervention the login response carries a token for the *anonymous* user and the first POST after login fails ("token was meant for a different claims-based user"). Fix: in the login endpoint set `http.User = principal` right after `SignInAsync`; in logout set `http.User = new ClaimsPrincipal(new ClaimsIdentity())` after `SignOutAsync`. The `OnStarting` middleware then mints the right token. Verified end-to-end: anon token → login (200) → POST with the login-response token (200); the pre-login token is rejected (400); logout → login with the post-logout token (200). (Calling `GetAndStoreTokens` a second time inside the endpoint does **not** work — it returns the cached anonymous token.)
- **Login CSRF:** the login POST is validated too (anonymous token), so the client needs `XSRF-TOKEN` before the login form submits. When nginx serves `index.html` nothing has set it yet — the app-startup `GET /api/me` does.
- The explicit endpoint filter must cover **every non-GET/HEAD/OPTIONS/TRACE method including DELETE** (middleware auto-validation never covers DELETE) — `IsRequestValidAsync` does. `DisableAntiforgery()` only for non-browser endpoints (webhooks) protected by HMAC/mTLS instead.
- ASP.NET Core's token is HMAC-protected via Data Protection and bound to the authenticated user — this satisfies OWASP's "signed double-submit with session binding" requirement; don't hand-roll a naive double-submit cookie.
- Defense-in-depth per OWASP: SameSite on both cookies + the fact that a custom header (`X-XSRF-TOKEN`) can't be set cross-origin without a CORS preflight. Layers, not replacements.

### Data protection keys in containers (Microsoft Learn: data protection configuration + key storage providers)

```csharp
builder.Services.AddDataProtection()
    .SetApplicationName("myapp")                                   // stable across deployments & instances
    .PersistKeysToDbContext<AppDbContext>()                        // AppDbContext : IDataProtectionKeyContext
    .ProtectKeysWithCertificate(cert);                             // see warning below
```

- Package: `Microsoft.AspNetCore.DataProtection.EntityFrameworkCore`; the context implements
  `IDataProtectionKeyContext` (`DbSet<DataProtectionKey> DataProtectionKeys`) and gets a migration.
  The app database is already durable and backed up — the right home for the key ring.
- Alternatives: `PersistKeysToFileSystem` on a mounted volume (single host), `PersistKeysToAzureBlobStorage`,
  `PersistKeysToStackExchangeRedis` **only** on a dedicated Redis with persistence and `noeviction` —
  never the FusionCache Redis, which evicts and runs without persistence by design.
- **Documented warning:** specifying an explicit key location *deregisters encryption-at-rest* — keys are then stored in plaintext unless you add `ProtectKeysWith*` (certificate or Azure Key Vault). Do both in production.
- **Redis caveat (documented):** Redis does not persist to disk by default; a Redis restart — or an eviction under `allkeys-lru` — drops the key ring and invalidates every cookie and XSRF token.
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
app.UseAuthentication();
app.UseRateLimiter();                                   // after UseAuthentication (identity partition) and routing (per-endpoint policies)
authGroup.RequireRateLimiting("auth");                  // /api/auth/* gets the strict policy
```

- **Order matters for identity partitions:** before `UseAuthentication`, `ctx.User` is still anonymous, so `ctx.User.Identity?.Name` is always null and every request falls back to the IP key — verified (partition key was `127.0.0.1` for a signed-in user with the limiter first, the user name with it after). Microsoft's generic Kestrel middleware order lists `UseRateLimiter` before authentication; that is only right for IP-only limiters. Routing is implicit at the start of a `WebApplication` pipeline, so per-endpoint policies work in this position.
- `QueueLimit = 0` on auth endpoints: reject immediately, don't queue brute-force traffic.
- **Documented DoS warning:** partitioning on client IP is spoofable and behind a proxy every request shares the proxy IP — configure `UseForwardedHeaders` correctly first, and prefer user identity as the partition key once authenticated.
- Rate limiting is not DDoS protection; that belongs at the edge (WAF/CDN), per docs.

### Security headers with a verified Angular CSP (OWASP HTTP Headers + CSP sheets, angular.dev)

OWASP-recommended values: `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` (SKILL.md's `AddHsts` sends the same two years + `includeSubDomains`; `preload` stays a deliberate opt-in) · `X-Content-Type-Options: nosniff` · `Referrer-Policy: strict-origin-when-cross-origin` · `Permissions-Policy: geolocation=(), camera=(), microphone=()` (deny what you don't use) · `Cross-Origin-Opener-Policy: same-origin` (pages that open a payment/OAuth popup, e.g. PayPal checkout, need `same-origin-allow-popups` — see `paypal`) · `Cross-Origin-Resource-Policy: same-site` · remove `Server`/`X-Powered-By` · `Cache-Control: no-store` on authenticated API responses.

CSP for Angular (angular.dev/best-practices/security). Angular inserts component `<style>` elements at runtime, and critical-CSS inlining adds a `<style>` element **and inline scripts** to `index.html` — so `default-src 'self'` alone breaks the app, and "production builds need no inline scripts" is false. Two working policies:

**A — static `index.html` (nginx or `MapFallbackToFile`; the default here).** Set `"security": { "autoCsp": true }` in `angular.json`: at build time the CLI hashes every inline script in `index.html` (including the critical-CSS and SRI ones) and emits a `<meta>` CSP with `script-src 'strict-dynamic' 'sha256-…' https: 'unsafe-inline'; object-src 'none'; base-uri 'self';` (`'unsafe-inline'`/`https:` are fallbacks that CSP3 browsers ignore when hashes + `'strict-dynamic'` are present). Documented limits: it covers scripts only; browsers ignore `frame-ancestors`/`report-uri`/`sandbox` in `<meta>`; not compatible with SSR; and with multiple policies the browser enforces all — **so the response header must omit `script-src` and `default-src`**. Send the rest as a header:

```
object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'; style-src 'self' 'unsafe-inline'; upgrade-insecure-requests
```

`style-src 'unsafe-inline'` is unavoidable without a per-response nonce (OWASP: a compromise, far less dangerous than inline script).

**B — per-response nonce (BFF templates `index.html`).** angular.dev's minimal policy, hardened with the OWASP additions:

```
default-src 'self'; style-src 'self' 'nonce-{RANDOM}'; script-src 'self' 'nonce-{RANDOM}'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'
```

Generate a fresh, unpredictable nonce per response, stamp it on the root element (`<app-root ngCspNonce="{RANDOM}">`) or provide `CSP_NONCE`. Don't combine with `autoCsp`; check the browser console for blocked critical-CSS inline scripts (disable `inlineCritical` if they are).

### Angular client specifics (angular.dev/best-practices/security)

- XSRF: `provideHttpClient(withXsrfConfiguration({ cookieName: 'XSRF-TOKEN', headerName: 'X-XSRF-TOKEN' }))` — the defaults already match the BFF config; only mutating requests to relative or same-origin URLs get the header — a cross-origin URL (another host, port or scheme, e.g. a hard-coded `environment.apiUrl`) silently drops it. Call the API via relative paths (`/api/...`). `withNoXsrfProtection()` exists — never use it here.
- Auth state is a signal derived from the server, nothing more:

```ts
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  readonly user = signal<CurrentUser | null>(null);
  readonly isAuthenticated = computed(() => this.user() !== null);
  async refresh(): Promise<void> {
    try {
      this.user.set(await firstValueFrom(this.http.get<CurrentUser>('/api/me')));
    } catch {
      this.user.set(null);            // 401 = logged out; the response still set XSRF-TOKEN
    }
  }
}
// app.config.ts: provideAppInitializer(() => inject(AuthService).refresh())
```

  Run `refresh()` at startup (`provideAppInitializer`; `APP_INITIALIZER` is deprecated) — it seeds `XSRF-TOKEN` for the login POST. A functional interceptor maps 401 → clear the signal + navigate to the login route. No token handling anywhere.
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
        // headers are copied from the client by default — strip the trusted-identity namespace FIRST,
        // otherwise TryAdd appends to a client-forged value (or forwards it unchanged when sub is null)
        t.ProxyRequest.Headers.Remove("X-User-Id");
        t.ProxyRequest.Headers.Remove("X-Service-Key");
        t.ProxyRequest.Headers.TryAddWithoutValidation("X-Service-Key", serviceKey); // BFF credential
        var sub = t.HttpContext.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (sub is not null) t.ProxyRequest.Headers.TryAddWithoutValidation("X-User-Id", sub);
        return ValueTask.CompletedTask;
    }));
```

Map the proxy with `RequireAuthorization()` (routes also support `AuthorizationPolicy` in `RouteConfig`) — but **endpoint filters don't run on proxy endpoints**, so the `/api` antiforgery filter does not protect `/api/gw/*`. Validate inside the proxy pipeline:

```csharp
app.MapReverseProxy(proxy =>
{
    proxy.Use(async (ctx, next) =>                      // runs only for proxied routes
    {
        if (!await ctx.RequestServices.GetRequiredService<IAntiforgery>().IsRequestValidAsync(ctx))
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;                                     // never forwarded
        }
        await next(ctx);
    });
    proxy.UseSessionAffinity();                         // this overload drops YARP's defaults —
    proxy.UseLoadBalancing();                           // re-add them explicitly
    proxy.UsePassiveHealthChecks();
}).RequireAuthorization().DisableCookieRedirect();
```

Verified: tokenless POST → 400 and not forwarded; POST with a valid token → proxied; GET → proxied. Downstream services must trust these identity headers only from the private network + service credential — never from a public interface.

### SignalR / WebSockets

CORS does not apply to WebSockets: browsers send no preflight and ignore `Access-Control-*` on the upgrade, but they do send the `Origin` header — and the session cookie rides along unless SameSite stops it (cross-site WebSocket hijacking). Defaults accept **any** origin. Restrict it:

```csharp
app.UseWebSockets(new WebSocketOptions { AllowedOrigins = { "https://app.example.com" } }); // 403 otherwise
```

Verified against a `MapHub<T>` endpoint: a foreign `Origin` gets 403 on the upgrade, the listed one connects. Only the WebSocket transport is covered — long polling/SSE are plain HTTP and stay governed by same-origin + CORS (none configured).

Keep hubs under `RequireAuthorization()`. `Origin` is only checked when present (non-browser clients omit it) and is not authentication — it is a browser-side guard, alongside `SameSite=Strict` on the session cookie.

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
    // reset the failure counter; rehash if the stored hash uses outdated parameters
    // (Identity's hasher reports PasswordVerificationResult.SuccessRehashNeeded)
    await users.RegisterSuccessfulLoginAsync(user!, req.Password, ct);
    var principal = users.CreatePrincipal(user!);
    await http.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme,
        principal, new AuthenticationProperties());
    http.User = principal;                                  // XSRF token in this response binds to the new user
    return TypedResults.Ok();
}).AllowAnonymous().RequireRateLimiting("auth");           // inside the antiforgery-filtered /api group
```

Logout mirrors it: `SignOutAsync`, then `http.User = new ClaimsPrincipal(new ClaimsIdentity())`.

### Testing the security wiring (`dotnet-testing`)

The quality gate applies to auth plumbing too — these regress silently. `WebApplicationFactory` with `AllowAutoRedirect = false` and `HandleCookies = true` (HTTPS base address, since every cookie is `Secure`):

- unauthenticated `GET /api/...` and `/api/gw/...` → 401, not 302;
- `POST` without `X-XSRF-TOKEN` → 400 (not 500) on `/api/...` **and** on `/api/gw/...` (and the backend is never hit);
- startup `GET /api/me` while logged out → 401 **with** `XSRF-TOKEN` set;
- login → the next `POST` with the login-response token succeeds; the pre-login token is rejected;
- `Set-Cookie` flags: `__Host-session` HttpOnly + Secure + SameSite=Strict; `__Host-af` Secure;
- security stamp bump → the old cookie gets 401; the `"auth"` limiter → 429 on attempt N+1.

## Anti-patterns

| Anti-pattern | Why it fails | Fix |
|---|---|---|
| Trusting `UseAntiforgery()` to protect JSON APIs | Middleware validates only form-metadata endpoints, POST/PUT/PATCH only | Explicit `IsRequestValidAsync` endpoint filter on the whole `/api` group |
| `ValidateRequestAsync` in an endpoint filter | Throws `AntiforgeryValidationException` → 500, error noise, misleading monitoring | `IsRequestValidAsync` → `TypedResults.Problem(statusCode: 400)` |
| Relying on the `/api` filter for the YARP routes | Endpoint filters don't run on `MapReverseProxy` endpoints → no CSRF check on `/api/gw/*` | Validate in the `MapReverseProxy(proxy => …)` pipeline |
| `o.Events` lambdas plus `o.EventsType` | `EventsType` wins; the 401/403 lambdas are dropped → 302s are back | Override `RedirectToLogin`/`RedirectToAccessDenied` in the events class |
| Login response's XSRF token assumed fresh | Token bound to the anonymous user and cached per request → first POST after login is 400 | `http.User = principal` after `SignInAsync`; mint the cookie in `OnStarting` |
| `UseRateLimiter()` before `UseAuthentication()` | `ctx.User` is anonymous → identity partitions collapse onto IP | Rate limiter after authentication |
| Relying on `SameSite=Strict` instead of tokens | Site-scoped not origin-scoped; subdomains and client-side CSRF bypass it (OWASP) | SameSite **and** antiforgery validation |
| Calling the API on another origin from Angular (`environment.apiUrl`) | `HttpClient` skips `X-XSRF-TOKEN` on cross-origin URLs → 400 on every write | Relative `/api/...` paths, same origin |
| `default-src 'self'` as the whole Angular CSP | Blocks runtime component `<style>`s and critical-CSS inline scripts | `autoCsp` + header without `script-src`/`default-src`, or per-response nonce |
| `PersistKeysTo*` without `ProtectKeysWith*` | Explicit persistence disables encryption-at-rest (documented) | Add certificate/Key Vault protection |
| Data protection keys in the cache Redis | Restart or LRU eviction drops keys → all sessions and XSRF tokens die | `PersistKeysToDbContext<T>` (or a dedicated persistent `noeviction` Redis) |
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
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/middleware?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/websockets?view=aspnetcore-10.0#websocket-origin-restriction
- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/kestrel/host-filtering?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/authentication/identity-api-authorization?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/authentication/passkeys/?view=aspnetcore-10.0
- https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/HTTP_Headers_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html
- https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
- https://angular.dev/best-practices/security
- https://angular.dev/api/core/CSP_NONCE
- https://angular.dev/reference/releases
- https://datatracker.ietf.org/doc/draft-ietf-oauth-browser-based-apps/ (draft-27, July 2026, intended BCP)
