# PayPal webhooks — setup, receiving, verification, testing

Verified 2026-10-02 against https://developer.paypal.com/api/rest/webhooks/,
https://developer.paypal.com/api/rest/webhooks/rest/, the event-names page and
`notifications_webhooks_v1.json`. Contradictions between sources: see [docs-map.md](docs-map.md).

## Delivery facts

- PayPal POSTs JSON to your URL — **HTTPS on port 443 only**. Success = any `2xx`. Anything else → retried **up to 25 times over
  3 days**, then the event is marked failed (manual resend from the dashboard or the resend API).
- Events are **app-scoped**: a webhook only receives events for the REST app it is registered on.
- **Max 10 webhook URLs per app.** `*` subscribes to all event types.
- Delivery headers: `PAYPAL-TRANSMISSION-ID`, `PAYPAL-TRANSMISSION-TIME`, `PAYPAL-TRANSMISSION-SIG`
  (base64), `PAYPAL-CERT-URL`, `PAYPAL-AUTH-ALGO`, `CORRELATION-ID`. Store them all — verification needs them.
- Envelope: `id`, `create_time`, `resource_type`, `event_version`, `event_type`, `summary`,
  `resource_version`, `resource`, `links`. The `id` identifies the event (resend uses it) — dedupe on it.
- **No documented ordering guarantee** and no documented delivery timeout: assume out-of-order
  delivery and respond fast.

## 1. Choose the topology before registering

| Your setup | Webhooks | How the processor knows the account/tenant |
|---|---|---|
| **One REST app for all your merchants/tenants** (platform/partner, or a single merchant) | One webhook per environment, one global URL | From your own data: order id → tenant mapping stored at order creation; `custom_id` as cross-check |
| **One REST app per tenant** (each tenant enters their own client id/secret) | One webhook **per tenant app**, each with its own `webhook_id` | Put an opaque, unguessable tenant key in the URL path (`/webhooks/paypal/{key}`); the processor needs the tenant first to know which `webhook_id` verifies the signature |

Register **separate webhooks for sandbox and live** — different apps, different `webhook_id`s.

## 2. Pick event types (Orders v2 checkout)

| Event | Resource | Act |
|---|---|---|
| `PAYMENT.CAPTURE.COMPLETED` | capture | Book the payment (idempotent on capture id) |
| `PAYMENT.CAPTURE.PENDING` | capture | Record pending + `status_details.reason`; don't treat as paid; wait for COMPLETED |
| `PAYMENT.CAPTURE.DECLINED` (v1/platform name: `.DENIED`) | capture | Mark failed; handling both names is harmless |
| `PAYMENT.CAPTURE.REFUNDED` | refund (spec sample) — route on `resource_type` | Record refund — **includes refunds made in the PayPal dashboard**, not only via your API |
| `PAYMENT.CAPTURE.REVERSED` | route on `resource_type` (UNVERIFIED) | Chargeback/reversal — money is gone; mark the capture (keyed on capture id) as reversed and alert |
| `CHECKOUT.ORDER.APPROVED` | order | Buyer approved but your client may never have called capture → capture server-side (with `PayPal-Request-Id`) |
| `CHECKOUT.PAYMENT-APPROVAL.REVERSED` | order | Approval reversed before capture — cancel the pending order |
| `PAYMENT.REFUND.PENDING` / `.FAILED` | refund | Only if you issue refunds via API and need their final state |
| `PAYMENT.AUTHORIZATION.CREATED` / `.VOIDED` | authorization | Only with `intent: AUTHORIZE` |
| `CUSTOMER.DISPUTE.CREATED` / `.UPDATED` / `.RESOLVED` | dispute | Only if you handle disputes |

**Refund events and the refund id — route on `resource_type`, never on the event-name prefix.** The
Payments v2 spec's sample `PAYMENT.CAPTURE.REFUNDED` event has `resource_type: "refund"`: `resource.id`
is the **refund** id (re-fetch via `GET /v2/payments/refunds/{id}`, dedupe on it) and the capture is the
`links[]` entry with `rel: "up"`. Sending that id to `/v2/payments/captures/{id}` just 404s. For
`.REVERSED` no official sample exists (UNVERIFIED which resource you get) — check `resource_type` on
each event. If an event ever carries a `capture` resource instead, it has no refund id: re-fetch the
capture for its new status/amounts and find the refund via Transaction Search — see
[orders-payments.md → Refunds of a capture](orders-payments.md#reconciliation).
Refunds made through your own API already return their id in the refund response.

`CHECKOUT.ORDER.COMPLETED` is documented as "for marketplaces and platforms only". Avoid `*` in
production — it stores payer data you don't need. The authoritative list for your account:
`GET /v1/notifications/webhooks-event-types`.

## 3. Register

Via dashboard (Developer Dashboard → Apps & Credentials → app → Webhooks) or the API.
Plain commands, one per step:

```bash
curl -s -u "$PAYPAL_CLIENT_ID:$PAYPAL_CLIENT_SECRET" -d grant_type=client_credentials https://api-m.sandbox.paypal.com/v1/oauth2/token
curl -s -X POST https://api-m.sandbox.paypal.com/v1/notifications/webhooks -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"url":"https://api.example.com/webhooks/paypal","event_types":[{"name":"PAYMENT.CAPTURE.COMPLETED"},{"name":"PAYMENT.CAPTURE.PENDING"},{"name":"PAYMENT.CAPTURE.DECLINED"},{"name":"PAYMENT.CAPTURE.REFUNDED"},{"name":"PAYMENT.CAPTURE.REVERSED"},{"name":"CHECKOUT.ORDER.APPROVED"}]}'
curl -s https://api-m.sandbox.paypal.com/v1/notifications/webhooks -H "Authorization: Bearer $TOKEN"
```

Save the returned webhook `id` as `PayPal:WebhookId` (`PayPalOptions.WebhookId`,
[orders-payments.md](orders-payments.md#options-paypal-section-validated-at-startup)) in each environment's
configuration, next to that environment's `Environment`/`BaseUrl` — it is not a secret, but verification
fails without the right one. One app per tenant: store it with the tenant's credentials instead. Update subscriptions with
`PATCH /v1/notifications/webhooks/{id}`; inspect with `GET /v1/notifications/webhooks/{id}/event-types`.

**Local development:** PayPal must reach a public HTTPS URL — use a tunnel (`devtunnel host -p 5000 --allow-anonymous`,
`ngrok http 5000`) and register the tunnel URL on the **sandbox** app only.

## 4. Receiving endpoint (ASP.NET Core minimal API)

The endpoint saves and acknowledges. It does not verify, resolve tenants, or book anything — those
happen in the processor (see [inbox-table.md](inbox-table.md)), where failures are retryable and replayable.

```csharp
app.MapPost("/webhooks/paypal", async (HttpRequest request, InboxDbContext db, TimeProvider clock,
                                       IOptions<PayPalOptions> options, CancellationToken ct) =>
{
    const int maxBytes = 256 * 1024;                       // PayPal events are small; cap junk
    if (request.ContentLength > maxBytes) return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);

    // raw bytes — never [FromBody]; bounded read also covers chunked requests without Content-Length
    using var buffer = new MemoryStream();
    var chunk = new byte[16 * 1024];
    int read;
    while ((read = await request.Body.ReadAsync(chunk, ct)) > 0)
    {
        if (buffer.Length + read > maxBytes) return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        buffer.Write(chunk, 0, read);
    }
    var body = Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);

    var (eventId, eventType, resourceId) = TryReadEnvelope(body);   // tolerant: nulls on garbage
    var environment = options.Value.Environment;                    // "sandbox" | "live"
    var path = request.Path.Value!;                                 // carries the tenant key in per-tenant-app setups
    var headers = HeadersToJson(request.Headers);
    var now = clock.GetUtcNow();

    db.WebhookInbox.Add(new WebhookInboxRow
    {
        Provider = WebhookProvider.PayPal,
        Environment = environment,
        DedupKey = eventId,
        EventType = eventType,
        ResourceId = resourceId,
        RequestPath = path,
        Headers = headers,
        Body = body,
        ReceivedAt = now,
        NextAttemptAt = now,
    });

    try
    {
        await db.SaveChangesAsync(ct);
    }
    catch (DbUpdateException ex) when (IsUniqueViolation(ex))
    {
        // Same event id already stored. The id comes from an unverified body, so a forgery can claim a
        // real event's id first — it must never swallow the genuine delivery.
        var sameEvent = db.WebhookInbox.Where(r =>
            r.Provider == WebhookProvider.PayPal && r.Environment == environment && r.DedupKey == eventId);

        // stored row is Rejected, or was parked (DeadLetter) before it was ever verified → nothing proves it
        // genuine: replace it with this delivery and verify again (otherwise every genuine retry gets 503)
        var replaced = await sameEvent.Where(r => r.Status == WebhookStatus.Rejected
                || (r.Status == WebhookStatus.DeadLetter && r.SignatureStatus == SignatureStatus.Unverified))
            .ExecuteUpdateAsync(s => s
                .SetProperty(r => r.Status, WebhookStatus.Pending)
                .SetProperty(r => r.SignatureStatus, SignatureStatus.Unverified)
                .SetProperty(r => r.EventType, eventType)
                .SetProperty(r => r.ResourceId, resourceId)
                .SetProperty(r => r.RequestPath, path)
                .SetProperty(r => r.Headers, headers)
                .SetProperty(r => r.Body, body)
                .SetProperty(r => r.ReceivedAt, now)
                .SetProperty(r => r.Attempts, 0)
                .SetProperty(r => r.NextAttemptAt, now)
                .SetProperty(r => r.LastError, (string?)null), ct);

        // stored row not verified yet and still in flight → can't tell which copy is genuine; 503 makes PayPal
        // retry later, by then the stored row is verified (→ 200), Rejected or parked unverified (→ replaced above)
        if (replaced == 0 && await sameEvent.AnyAsync(r => r.SignatureStatus == SignatureStatus.Unverified, ct))
            return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
        // otherwise a verified copy exists: a genuine PayPal retry — success
    }
    return Results.Ok();                                   // any other exception → 500 → PayPal retries
})
.AllowAnonymous()
.DisableAntiforgery()
.RequireRateLimiting("paypal-webhook");

// registration: ONE fixed window for the route (no per-IP partition — PayPal's sender IPs are no documented key),
// configuration-bound like bff-security's limits. Pipeline order: see the notes below.
builder.Services.AddOptions<PayPalWebhookRateLimitOptions>()
    .BindConfiguration(PayPalWebhookRateLimitOptions.Section).ValidateOnStart();
builder.Services.AddSingleton<IValidateOptions<PayPalWebhookRateLimitOptions>, PayPalWebhookRateLimitOptionsValidator>();
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;   // non-2xx → PayPal retries later
    o.AddPolicy("paypal-webhook", ctx => RateLimitPartition.GetFixedWindowLimiter("paypal-webhook",
        _ =>                                                        // runs once (one partition), not per request
        {
            var limits = ctx.RequestServices.GetRequiredService<IOptions<PayPalWebhookRateLimitOptions>>().Value;
            return new FixedWindowRateLimiterOptions
            {
                PermitLimit = limits.PermitLimit, Window = TimeSpan.FromSeconds(limits.WindowSeconds), QueueLimit = 0,
            };
        }));
    // bff-security's GlobalLimiter, with this route exempted: the named policy above is its real control
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
        ctx.Request.Path.StartsWithSegments("/webhooks/paypal")
            ? RateLimitPartition.GetNoLimiter("paypal-webhook")
            : RateLimitPartition.GetFixedWindowLimiter(               // bff-security's per-user / per-IP partition, unchanged
                ctx.User.FindFirstValue(ClaimTypes.NameIdentifier) is { } userId ? $"u:{userId}"
                    : $"ip:{ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown"}",
                _ =>
                {
                    var limits = ctx.RequestServices.GetRequiredService<IOptions<GlobalRateLimitOptions>>().Value;
                    return new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = limits.PermitLimit, Window = TimeSpan.FromSeconds(limits.WindowSeconds), QueueLimit = 0,
                    };
                }));
});

static (string? Id, string? Type, string? ResourceId) TryReadEnvelope(string body)
{
    try
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        return (Str(root, "id", 100), Str(root, "event_type", 100),
                root.TryGetProperty("resource", out var r) ? Str(r, "id", 64) : null);
    }
    catch (JsonException) { return (null, null, null); }

    // unverified input: anything longer than its column becomes null instead of a truncation error (→ 500)
    static string? Str(JsonElement e, string name, int maxLength) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String &&
        v.GetString() is { } s && s.Length <= maxLength
            ? s : null;
}

// Utf8JsonWriter: no reflection, works with JsonSerializerIsReflectionEnabledByDefault=false
static string HeadersToJson(IHeaderDictionary headers)
{
    var buffer = new ArrayBufferWriter<byte>();
    using (var w = new Utf8JsonWriter(buffer))
    {
        w.WriteStartObject();
        foreach (var (key, value) in headers)
            if (key.StartsWith("PAYPAL-", StringComparison.OrdinalIgnoreCase) ||
                key.Equals("CORRELATION-ID", StringComparison.OrdinalIgnoreCase))
                w.WriteString(key.ToUpperInvariant(), value.ToString());
        w.WriteEndObject();
    }
    return Encoding.UTF8.GetString(buffer.WrittenSpan);
}

// Keep the arm for your provider (each needs its package). Missing it turns every duplicate into a 500 → PayPal retries.
static bool IsUniqueViolation(DbUpdateException ex) => ex.InnerException switch
{
    SqlException { Number: 2601 or 2627 } => true,                                     // SQL Server: unique index / unique constraint (PK)
    PostgresException { SqlState: PostgresErrorCodes.UniqueViolation } => true,         // PostgreSQL (Npgsql): 23505
    _ => false,
};
```

`Security/RateLimitOptions.cs` — next to bff-security's `GlobalRateLimitOptions` / `AuthRateLimitOptions`:

```csharp
public sealed class PayPalWebhookRateLimitOptions
{
    public const string Section = "RateLimiting:PayPalWebhook";
    [Range(1, 1_000_000)] public int PermitLimit { get; set; } = 300;   // well above your real peak event rate
    [Range(1, 3_600)] public int WindowSeconds { get; set; } = 60;
}
[OptionsValidator] public partial class PayPalWebhookRateLimitOptionsValidator : IValidateOptions<PayPalWebhookRateLimitOptions>;
```

- The entity maps PascalCase properties to the snake_case columns of [inbox-table.md](inbox-table.md)
  (`ToTable("webhook_inbox")` + `HasColumnName`, or a snake_case naming convention); enums stored in
  `TINYINT` columns need a `byte` backing type (`enum WebhookProvider : byte`, `WebhookStatus`,
  `SignatureStatus`).
- **Duplicate event id:** the three branches above are what keeps a forged event that reused a real
  event id from swallowing the genuine one — the processor must set `signature_status` (1 valid /
  2 invalid) when it verifies. Only a row with `signature_status = 1` makes a duplicate a plain 200: a row
  parked as `DeadLetter` while still unverified (poison row, or verification kept failing until max
  attempts) is treated like `Rejected` — the next delivery replaces it and is verified afresh. If that next
  delivery is the forgery, it ends `Rejected` and the genuine retry after it replaces it again; once PayPal
  stops retrying, reconciliation covers the rest. A test should cover forged-first-then-genuine for the
  Rejected, the parked-unverified and the still-in-flight (503) case.
- The endpoint is anonymous by necessity. Unlike HMAC-signed webhooks it does **not** verify at the door:
  PayPal's RSA signature is checked asynchronously in the processor, so a verification bug or a PayPal
  cert outage never loses an event. Its protection at ingress is the body cap above plus **one
  fixed-window limiter for the whole route** (`RateLimiting:PayPalWebhook:PermitLimit` / `:WindowSeconds`,
  defaults 300 / 60, validated on start), sized well above your real event rate. It is not partitioned per
  IP: PayPal publishes IP ranges ([help article ts1056](https://www.paypal.com/us/cshelp/article/what-are-the-ip-addresses-for-paypal-nvpsoap-servers-ts1056))
  but advises against allow-listing them, and doesn't document them as webhook sender addresses.
- **Middleware order:** `RequireRateLimiting` is endpoint metadata, so `app.UseRateLimiter()` must run
  after routing (implicit in a minimal-API `WebApplication`, or after an explicit `UseRouting()`) —
  before it, the middleware can't see which policy applies. Place it where
  [bff-security](../../bff-security/SKILL.md#security-headers--middleware-order) puts it: after
  `UseAuthentication()`, before `UseAuthorization()`. This anonymous route's limiter has no identity
  partition, so the auth position doesn't change its behavior — but one `UseRateLimiter()` serves every
  policy, and the user-partitioned ones need it after authentication.
- **Exempt the route from bff-security's global limiter** (the `GetNoLimiter` branch above — same pattern
  as the Discord routes). `RequireRateLimiting("paypal-webhook")` adds an endpoint policy; it does not replace
  `o.GlobalLimiter` (per-user / per-IP, `RateLimiting:Global`, in
  [bff-security](../../bff-security/references/best-practices.md#rate-limiting-microsoft-learn-rate-limiting-middleware)),
  and a request would need both leases. PayPal delivers from a pool of shared addresses, and behind a proxy
  without correct `UseForwardedHeaders` every delivery lands in one partition — 100/min would silently
  become the limit for all of PayPal. Don't use `DisableRateLimiting()` instead: it is all-or-nothing and
  skips the named policy too. If the app also hosts Discord routes, keep both path checks in the one
  partitioner. PayPal treats a 429 like any non-2xx and retries, so a modest limit only delays delivery.
- **The global limiter is itself an attack surface:** anyone can fill the window with junk and push
  genuine PayPal deliveries into 429s. Those are retried (up to 25 times over 3 days), so a short flood
  only delays events; a sustained one can exhaust the retries. Alert on the **429 rate on this route**,
  block abusive source IPs at the edge (WAF / reverse proxy), and rely on reconciliation for anything
  that still falls through.
- Exclude it from antiforgery, auth redirects, response compression quirks, and any middleware that
  reads/rewrites the body.
- Per-tenant-app setups map `/webhooks/paypal/{key}`. The key acts as a credential-like selector — keep
  it out of request logs (redact the path segment in your request-logging enricher).
- The UTF-8 string round-trips to the original bytes for any valid UTF-8 body; if you want byte-exact
  storage regardless, store `varbinary(max)`/`bytea` instead.

## 5. Signature verification (in the processor)

Verify first — before parsing or using anything from the body. Failed → status `Rejected`; alert on the
**rate** of rejections (a spike is either an attack or a misconfigured `webhook_id`).

### Option A — postback API (simplest to build)

`POST /v1/notifications/verify-webhook-signature` with `auth_algo`, `cert_url`, `transmission_id`,
`transmission_sig`, `transmission_time`, `webhook_id`, `webhook_event`. Response
`{"verification_status":"SUCCESS"|"FAILURE"}`.

`webhook_event` must be the event **exactly as received**. Don't deserialize and re-serialize it —
splice the stored raw body into the request:

```csharp
static readonly string[] SignatureHeaders =
    ["PAYPAL-AUTH-ALGO", "PAYPAL-CERT-URL", "PAYPAL-TRANSMISSION-ID", "PAYPAL-TRANSMISSION-SIG", "PAYPAL-TRANSMISSION-TIME"];

// null = a signature header is missing or the body isn't exactly one JSON object → Rejected
// (the body is spliced verbatim, so it must be validated here — otherwise it could inject extra keys)
static string? BuildVerifyRequest(IReadOnlyDictionary<string, string> h, string webhookId, string rawBody) =>
    SignatureHeaders.All(h.ContainsKey) && IsSingleJsonObject(rawBody)
        ? $$"""
          {"auth_algo":{{Q(h["PAYPAL-AUTH-ALGO"])}},"cert_url":{{Q(h["PAYPAL-CERT-URL"])}},"transmission_id":{{Q(h["PAYPAL-TRANSMISSION-ID"])}},"transmission_sig":{{Q(h["PAYPAL-TRANSMISSION-SIG"])}},"transmission_time":{{Q(h["PAYPAL-TRANSMISSION-TIME"])}},"webhook_id":{{Q(webhookId)}},"webhook_event":{{rawBody}}}
          """
        : null;

static bool IsSingleJsonObject(string json)
{
    try
    {
        using var doc = JsonDocument.Parse(json);           // rejects trailing content after the value
        return doc.RootElement.ValueKind == JsonValueKind.Object;
    }
    catch (JsonException) { return false; }
}

static string Q(string value) => $"\"{JsonEncodedText.Encode(value)}\"";   // JSON string literal, no reflection

// webhookId: PayPalOptions.WebhookId (one app) or the tenant's, resolved from request_path (one app per tenant)
// if (BuildVerifyRequest(headers, webhookId, row.Body) is not { } json) → Rejected
// var content = new StringContent(json, Encoding.UTF8, "application/json");
// POST to {baseUrl}/v1/notifications/verify-webhook-signature with a cached OAuth bearer token.
```

Costs one API round trip per event; simulator events always return `FAILURE`.

### Option B — offline verification (PayPal's preferred method, no API call)

Signed string: `{transmission_id}|{transmission_time}|{webhook_id}|{crc32}` where `crc32` is the
CRC-32 (IEEE) of the **raw body bytes as an unsigned decimal**. Algorithm SHA256withRSA; the
certificate comes from `PAYPAL-CERT-URL` and should be cached.

```csharp
// NuGet: System.IO.Hashing
// Register as a SINGLETON (the cert cache must outlive one request), with a named client that
// does NOT follow redirects — an open redirect on any PayPal host would otherwise hand over the cert:
//   services.AddHttpClient("paypal-certs").ConfigurePrimaryHttpMessageHandler(
//       () => new SocketsHttpHandler { AllowAutoRedirect = false });
//   services.AddSingleton<PayPalSignatureVerifier>();
//   services.AddSingleton(TimeProvider.System);   // not registered by the framework - without it Build() fails in Development (ValidateOnBuild), the first resolve throws in Production
// trustCheck: tests pass their own (self-signed certs don't chain); production uses the default
public sealed class PayPalSignatureVerifier(IHttpClientFactory httpClientFactory, TimeProvider clock,
                                           Func<X509Certificate2, X509Certificate2Collection, bool>? trustCheck = null)
{
    private const int MaxCertBytes = 64 * 1024;                    // a PEM chain is a few KB
    private static readonly string[] CertHosts =
        ["api.paypal.com", "api-m.paypal.com", "api.sandbox.paypal.com", "api-m.sandbox.paypal.com"];
    private static readonly string[] CertSubjects =
        ["messageverificationcerts.paypal.com", "messageverificationcerts.sandbox.paypal.com"];

    // caches the public key + validity only — no X509Certificate2 instances to dispose or race on
    private sealed record PayPalCert(RSAParameters Key, DateTime NotBefore, DateTime NotAfter);
    private readonly ConcurrentDictionary<string, PayPalCert> _certs = new();

    public async Task<bool> VerifyAsync(IReadOnlyDictionary<string, string> h, string webhookId,
                                        string rawBody, CancellationToken ct)
    {
        // a missing header is a failed verification (→ Rejected), never an exception (→ endless retries)
        if (!h.TryGetValue("PAYPAL-CERT-URL", out var certUrlText) || !TryGetCertUri(certUrlText, out var certUri)) return false;
        if (!h.TryGetValue("PAYPAL-AUTH-ALGO", out var algo) || algo != "SHA256withRSA") return false;
        if (!h.TryGetValue("PAYPAL-TRANSMISSION-ID", out var transmissionId) ||
            !h.TryGetValue("PAYPAL-TRANSMISSION-TIME", out var transmissionTime) ||
            !h.TryGetValue("PAYPAL-TRANSMISSION-SIG", out var sig)) return false;

        var signature = new byte[sig.Length];
        if (!Convert.TryFromBase64String(sig, signature, out var sigLength)) return false;

        var crc = Crc32.HashToUInt32(Encoding.UTF8.GetBytes(rawBody));
        var signed = $"{transmissionId}|{transmissionTime}|{webhookId}|{crc}";

        if (await GetCertAsync(certUri, ct) is not { } cert) return false;
        using var rsa = RSA.Create(cert.Key);
        return rsa.VerifyData(Encoding.UTF8.GetBytes(signed), signature.AsSpan(0, sigLength),
                              HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    // null = not a usable PayPal cert → verification fails (Rejected), never an exception (→ retries)
    private async Task<PayPalCert?> GetCertAsync(Uri uri, CancellationToken ct)
    {
        var key = uri.GetLeftPart(UriPartial.Path);                  // query/fragment can't grow the cache
        var now = clock.GetUtcNow().UtcDateTime;
        if (_certs.TryGetValue(key, out var cached) && cached.NotBefore <= now && now < cached.NotAfter) return cached;

        using var response = await httpClientFactory.CreateClient("paypal-certs")
            .GetAsync(key, HttpCompletionOption.ResponseHeadersRead, ct);
        if ((int)response.StatusCode is >= 300 and < 500) return null;   // redirect or 4xx: not a cert
        response.EnsureSuccessStatusCode();                              // 5xx: transient → retry later
        if (await ReadCappedAsync(response.Content, MaxCertBytes, ct) is not { } pem) return null;

        var certs = new X509Certificate2Collection();
        try
        {
            try { certs.ImportFromPem(pem); }
            catch (CryptographicException) { return null; }

            // leaf = PayPal's verification-cert subject; any other certs in the PEM are intermediates
            var leaf = certs.FirstOrDefault(c => CertSubjects.Contains(
                c.GetNameInfo(X509NameType.DnsName, forIssuer: false), StringComparer.OrdinalIgnoreCase));
            if (leaf is null) return null;
            var (notBefore, notAfter) = (leaf.NotBefore.ToUniversalTime(), leaf.NotAfter.ToUniversalTime());
            if (now < notBefore || now >= notAfter) return null;

            var intermediates = new X509Certificate2Collection(certs.Where(c => c != leaf).ToArray());
            if (!(trustCheck ?? IsTrustedChain)(leaf, intermediates)) return null;

            using var rsa = leaf.GetRSAPublicKey();
            if (rsa is null) return null;
            return _certs[key] = new PayPalCert(rsa.ExportParameters(includePrivateParameters: false), notBefore, notAfter);
        }
        finally
        {
            foreach (var c in certs) c.Dispose();
        }
    }

    // Chain to a trusted public CA; intermediates from the PEM go into ExtraStore (AIA fetch covers the
    // rest). Revocation off: a CRL/OCSP outage must not reject real events.
    private static bool IsTrustedChain(X509Certificate2 leaf, X509Certificate2Collection intermediates)
    {
        using var chain = new X509Chain();
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.ExtraStore.AddRange(intermediates);
        try { return chain.Build(leaf); }
        finally { foreach (var e in chain.ChainElements) e.Certificate.Dispose(); }
    }

    private static async Task<string?> ReadCappedAsync(HttpContent content, int maxBytes, CancellationToken ct)
    {
        if (content.Headers.ContentLength > maxBytes) return null;
        await using var stream = await content.ReadAsStreamAsync(ct);
        var buffer = new byte[maxBytes + 1];
        int total = 0, read;
        while (total < buffer.Length && (read = await stream.ReadAsync(buffer.AsMemory(total), ct)) > 0) total += read;
        return total > maxBytes ? null : Encoding.ASCII.GetString(buffer, 0, total);
    }

    // Not documented by PayPal — never fetch a "cert" from anywhere but PayPal's cert endpoint.
    private static bool TryGetCertUri(string text, out Uri uri) =>
        Uri.TryCreate(text, UriKind.Absolute, out uri!) && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort &&
        CertHosts.Contains(uri.Host, StringComparer.OrdinalIgnoreCase) &&
        uri.AbsolutePath.StartsWith("/v1/notifications/certs/", StringComparison.Ordinal);
}
```

- Use the header values **verbatim** (don't reformat the timestamp).
- The host/path allow-list, the no-redirect client and the chain + subject check together close the
  classic hole in hand-rolled offline verification: an attacker hosting their own cert and signing
  forged events. Observed PayPal cert: subject `CN=messageverificationcerts[.sandbox].paypal.com`,
  `O=PayPal, Inc.`, issued by DigiCert. If PayPal ever changes it, verification fails loudly
  (rejection-rate alert) rather than silently accepting.
- Optionally reject events whose `PAYPAL-TRANSMISSION-TIME` is far in the past (replay window) — but
  remember legitimate retries arrive up to 3 days later.

**Either way, then re-fetch the resource named by `resource_type`** (`capture` → `/v2/payments/captures/{id}`,
`refund` → `/v2/payments/refunds/{id}`; see [inbox-table.md](inbox-table.md#processing-one-row)) and act on
the API's current state, not the event's — a verified event can still be stale.

## 6. Testing

| Tool | Use for | Limits |
|---|---|---|
| Webhook simulator (dashboard) / `POST /v1/notifications/simulate-event` | Endpoint reachability, envelope parsing, inbox insert | Mock data; simulated events belong to no app, so they don't appear in the dashboard's event list and can't be resent; **postback verification always fails** — offline-verify with webhook id `WEBHOOK_ID` |
| Real sandbox transactions (sandbox buyer + merchant accounts) | End-to-end: real resources, real signatures, re-fetch, booking | Needs a reachable URL (tunnel) |
| Negative testing (sandbox) | Forcing declines/errors on API calls | Sandbox only |
| `POST /v1/notifications/webhooks-events/{id}/resend` | Replaying a real event after a fix; testing dedup | Pending notifications aren't resent |
| `GET /v1/notifications/webhooks-events?event_type=…&start_time=…` | Finding what PayPal sent vs. what you stored | — |

Automated tests: feed recorded real sandbox deliveries (body + headers) into the endpoint and assert
(a) one row per event id, (b1) a duplicate of a verified row returns 200 without a second row,
(b2) a duplicate of a pending/unverified row returns 503 without a second row, (c) unparseable bodies are
still stored, (d) the processor books once even when the capture response and the webhook both arrive,
(e) `PENDING` followed by `COMPLETED` for the same capture ends `COMPLETED`, (f) a captured amount that
differs from the expected one is not booked. Unit-test the offline verifier with a test CA + leaf `CN=messageverificationcerts.paypal.com` (the
subject check always applies; pass `trustCheck: (_, _) => true`) and a stub HTTP handler: valid, tampered
body, wrong webhook id, foreign cert host, missing header, expired cert, oversized cert response.
