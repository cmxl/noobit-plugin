# PayPal Orders v2 / Payments v2 — server-side essentials

Verified 2026-10-02 against `checkout_orders_v2.json`, `payments_payment_v2.json`,
`reporting_transactions_v1.json` (github.com/paypal/paypal-rest-api-specifications) and
https://developer.paypal.com/api/rest/requests/ + /authentication/.

## Base URLs and auth

- Sandbox `https://api-m.sandbox.paypal.com`, live `https://api-m.paypal.com`.
- `POST /v1/oauth2/token` with HTTP Basic `client_id:secret` and `grant_type=client_credentials`.
  Response carries `access_token` and `expires_in` (seconds; ~9 h in PayPal's sample). **Cache the token**
  and refresh shortly before expiry — don't fetch one per request. Credentials live in a secret store,
  never in code or logs.
- **Token cache = FusionCache** (`noobit:fusioncache-redis`), **L1 only**: a bearer token is a credential —
  skip the Redis L2 and backplane for it (every node fetching its own token is cheap). The `GetOrSetAsync`
  factory gives single-flight refresh (concurrent requests don't all fetch a token), and adaptive caching
  sets the duration from `expires_in`. See the client sketch below.
- **One app per tenant?** Then every API call — create, capture, the processor's re-fetch — uses that
  tenant's credentials, and the token cache key includes tenant + environment.
- Log the error body's `debug_id` (plus `name` and `details[].issue`) on every failed call — PayPal support asks for it.
- Retries: `AddStandardResilienceHandler` retries **every** HTTP method by default, POST included.
  On the PayPal client call `options.Retry.DisableForUnsafeHttpMethods()` and retry create/capture/refund
  at the application level with the same stored `PayPal-Request-Id` (the processor's backoff already
  does this). Never let a POST without a request id be retried automatically.

## Checkout flow

1. **Create** — `POST /v2/checkout/orders` with `intent: CAPTURE` (or `AUTHORIZE`), `purchase_units[]`
   (`amount`, `reference_id`, `custom_id`, `invoice_id`), and a `PayPal-Request-Id`.
   **Persist `order.id → your order + tenant` before returning to the client** — that mapping is how
   webhooks find their way back later.
2. **Approve** — the buyer approves via the JS SDK buttons or the `rel: approve` link.
3. **Capture** — `POST /v2/checkout/orders/{id}/capture` (new `PayPal-Request-Id`, reused on retries of
   *this* capture). The response contains `purchase_units[].payments.captures[]` → book via the shared,
   idempotent booking routine.
4. **Backup path** — `CHECKOUT.ORDER.APPROVED` / `PAYMENT.CAPTURE.*` webhooks feed the same routine, so a
   buyer who closes the tab after approving still gets captured/booked.

**The capture race:** the client-triggered capture and a server-side capture from the
`CHECKOUT.ORDER.APPROVED` webhook can collide. With `intent=CAPTURE` only one capture per order is
allowed; the loser gets error issue **`ORDER_ALREADY_CAPTURED`**
(https://developer.paypal.com/api/rest/reference/orders/v2/errors/). Treat it as success:
`GET /v2/checkout/orders/{id}` and run the booking routine with the capture found there.

`GET /v2/checkout/orders/{id}` returns the current state; `PATCH` works only while `CREATED` or `APPROVED`.
`Prefer: return=representation` returns the full resource (default `return=minimal`: id, status, links).

## Statuses

| Resource | Statuses |
|---|---|
| Order | `CREATED`, `SAVED`, `APPROVED`, `VOIDED`, `COMPLETED`, `PAYER_ACTION_REQUIRED` |
| Capture | `COMPLETED`, `PENDING`, `DECLINED`, `PARTIALLY_REFUNDED`, `REFUNDED`, `FAILED` |
| Refund | `PENDING`, `COMPLETED`, `FAILED`, `CANCELLED` |

`PENDING` captures carry `status_details.reason` (e.g. `PENDING_REVIEW`, `ECHECK`, `UNILATERAL`,
`RECEIVING_PREFERENCE_MANDATES_MANUAL_ACTION`) — money is **not** yours yet; wait for `COMPLETED`.
An order being `COMPLETED` is not the same as money received — check the capture status.

## Identifiers you control

| Field | Limits | Semantics |
|---|---|---|
| `reference_id` | ≤ 256 | Identifies a purchase unit inside the order; required per unit when there are several |
| `custom_id` | ≤ 255 | Free reference, not shown to the payer, appears in reports; present on the capture resource. A refund's `custom_id` is whatever the refund request set (≤ 127) — empty for dashboard refunds |
| `invoice_id` | ≤ 127 | **Unique per merchant account by default** — a duplicate is rejected. Use your invoice number only if it is really unique; don't put retry-able ids here |

## Idempotency — `PayPal-Request-Id`

- Supported on create order, authorize, capture, capture-of-authorization, reauthorize, void, refund.
  Max length 108 on the Orders API (Payments API allows more) — keep every key ≤ 108.
- Mandatory for single-step create-order calls that include a `payment_source`.
- Same key + same request → PayPal returns the original result instead of executing twice.
- **Retention differs by source:** the Orders v2 spec says keys are stored **6 h** (72 h on request via
  your account manager); the general requests page says "up to 45 days" (its example is a refund) — it
  may differ per API. Assume 6 h for orders; for anything longer, your own unique constraints (capture
  id, refund id) are the guarantee.
- Generate the key per *logical operation* (e.g. `capture:{orderId}`), persist it, reuse it on retries.
  A new GUID per HTTP attempt defeats the purpose.

Also note `PayPal-Partner-Attribution-Id` (BN code, ≤ 36) — required only for partner/multiparty
integrations; `PayPal-Auth-Assertion` for acting on behalf of a merchant.

## Refunds

`POST /v2/payments/captures/{capture_id}/refund` — empty body = full refund, `amount` = partial; send a
`PayPal-Request-Id`. Refunds can also be issued by the merchant in the PayPal dashboard — your system
only learns about those via `PAYMENT.CAPTURE.REFUNDED` webhooks or reconciliation. Book refunds
idempotently on the refund id.

## Reconciliation

Webhooks are best-effort; reconcile on a schedule:

- **Local sweep** (minutes): orders you created that are still `CREATED`/`APPROVED` or captures still
  `PENDING` after a threshold → `GET` the order/capture and run the booking routine.
- **Transaction Search** (`GET /v1/reporting/transactions`, daily or hourly): transactions appear with up
  to **3 hours** delay; date range ≤ **31 days** per request; history up to 3 years; `fields=all` for
  full detail. Compare against your bookings by capture id; anything missing goes through the same
  idempotent routine. `/v1/reporting/balances` has the same lag.
- **Refunds of a capture:** `transaction_id=<capture id>` returns the capture itself, not its refunds.
  Query a date window (capture time → now, ≤ 31 days per request) with `transaction_type=T1107`
  (payment refund) and match `transaction_info.paypal_reference_id` == capture id
  (`paypal_reference_id_type` `TXN`; documented as the related, pre-existing transaction — confirm on a
  sandbox refund before relying on it).

## Typed client sketch (`IPayPalClient`)

Plain `HttpClient` + source-generated JSON; the website endpoints and the webhook processor share it.
Shows the three things a hand-rolled client gets wrong: `PayPal-Request-Id` on POSTs, `debug_id` +
`details[].issue` on every failure, and 422 issues as typed checks (`ORDER_ALREADY_CAPTURED`).

```csharp
// services.AddHttpClient<IPayPalClient, PayPalClient>((sp, c) =>
//         c.BaseAddress = new Uri(sp.GetRequiredService<IOptions<PayPalOptions>>().Value.BaseUrl))   // trailing "/"
//     .AddStandardResilienceHandler(o => o.Retry.DisableForUnsafeHttpMethods());
public interface IPayPalClient
{
    Task<PayPalOrder> CreateOrderAsync(CreateOrderBody body, string requestId, CancellationToken ct);
    Task<PayPalOrder> CaptureOrderAsync(string orderId, string requestId, CancellationToken ct);
    Task<PayPalOrder> GetOrderAsync(string orderId, CancellationToken ct);
    Task<PayPalCapture> GetCaptureAsync(string captureId, CancellationToken ct);
}

public sealed class PayPalApiException(HttpStatusCode status, PayPalError? error)
    : Exception($"PayPal {(int)status} {error?.Name}: {error?.Message} (debug_id {error?.DebugId})")
{
    public HttpStatusCode Status => status;
    public PayPalError? Error => error;
    public bool HasIssue(string issue) => error?.Details?.Any(d => d.Issue == issue) == true;
}

public sealed class PayPalClient(HttpClient http, IFusionCache cache, IOptions<PayPalOptions> options,
                                 ILogger<PayPalClient> logger) : IPayPalClient
{
    // bearer token: L1 only — never written to Redis, no backplane traffic; no fail-safe (stale = expired)
    private static readonly FusionCacheEntryOptions TokenCacheOptions = new()
    {
        SkipDistributedCacheRead = true,
        SkipDistributedCacheWrite = true,
        SkipBackplaneNotifications = true,
        SkipDistributedLocker = true,      // nothing is shared — don't take a cluster-wide lock per node
        IsFailSafeEnabled = false,
    };

    private string TokenKey => $"paypal:token:{options.Value.Environment}";   // + tenant with one app per tenant

    public Task<PayPalOrder> CreateOrderAsync(CreateOrderBody body, string requestId, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, "v2/checkout/orders",
                  JsonContent.Create(body, PayPalJson.Default.CreateOrderBody), requestId, PayPalJson.Default.PayPalOrder, ct);

    public Task<PayPalOrder> CaptureOrderAsync(string orderId, string requestId, CancellationToken ct) =>
        SendAsync(HttpMethod.Post, $"v2/checkout/orders/{Uri.EscapeDataString(orderId)}/capture",
                  new StringContent("{}", Encoding.UTF8, "application/json"), requestId, PayPalJson.Default.PayPalOrder, ct);

    public Task<PayPalOrder> GetOrderAsync(string orderId, CancellationToken ct) =>
        SendAsync(HttpMethod.Get, $"v2/checkout/orders/{Uri.EscapeDataString(orderId)}", null, null, PayPalJson.Default.PayPalOrder, ct);

    public Task<PayPalCapture> GetCaptureAsync(string captureId, CancellationToken ct) =>
        SendAsync(HttpMethod.Get, $"v2/payments/captures/{Uri.EscapeDataString(captureId)}", null, null, PayPalJson.Default.PayPalCapture, ct);

    private async Task<T> SendAsync<T>(HttpMethod method, string path, HttpContent? content, string? requestId,
                                       JsonTypeInfo<T> type, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, path) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await GetTokenAsync(ct));
        request.Headers.Add("Prefer", "return=representation");
        if (requestId is not null) request.Headers.Add("PayPal-Request-Id", requestId);   // ≤ 108 chars

        using var response = await http.SendAsync(request, ct);
        if (response.IsSuccessStatusCode)
            return await response.Content.ReadFromJsonAsync(type, ct)
                   ?? throw new PayPalApiException(response.StatusCode, null);

        if (response.StatusCode == HttpStatusCode.Unauthorized) await cache.RemoveAsync(TokenKey, TokenCacheOptions, ct);   // L1 only — don't evict other nodes' tokens
        PayPalError? error = null;
        try { error = await response.Content.ReadFromJsonAsync(PayPalJson.Default.PayPalError, ct); }
        catch (JsonException) { }                                        // HTML error page from an edge proxy
        logger.LogWarning("PayPal {Method} {Path} failed: {Status} {Name} {Issues} debug_id {DebugId}",
            method, path, (int)response.StatusCode, error?.Name,
            string.Join(",", error?.Details?.Select(d => d.Issue) ?? []), error?.DebugId);
        throw new PayPalApiException(response.StatusCode, error);
    }

    private ValueTask<string> GetTokenAsync(CancellationToken ct) =>
        cache.GetOrSetAsync<string>(TokenKey, async (ctx, ct) =>
        {
            var o = options.Value;
            using var request = new HttpRequestMessage(HttpMethod.Post, "v1/oauth2/token")
            {
                Content = new FormUrlEncodedContent([new("grant_type", "client_credentials")]),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic",
                Convert.ToBase64String(Encoding.UTF8.GetBytes($"{o.ClientId}:{o.ClientSecret}")));
            using var response = await http.SendAsync(request, ct);
            response.EnsureSuccessStatusCode();                          // never log the request: it carries the secret
            var token = await response.Content.ReadFromJsonAsync(PayPalJson.Default.TokenResponse, ct)
                        ?? throw new InvalidOperationException("Empty PayPal token response");
            ctx.Options.Duration = TimeSpan.FromSeconds(Math.Max(60, token.ExpiresIn - 300));   // refresh 5 min early
            return token.AccessToken;
        }, TokenCacheOptions, ct);
}

public sealed record TokenResponse(string AccessToken, int ExpiresIn);
public sealed record PayPalError(string? Name, string? Message, string? DebugId, IReadOnlyList<PayPalErrorDetail>? Details);
public sealed record PayPalErrorDetail(string? Field, string? Issue, string? Description);
public sealed record Money(string CurrencyCode, string Value);
public sealed record Payee(string? MerchantId);
public sealed record CreateOrderBody(string Intent, IReadOnlyList<PurchaseUnit> PurchaseUnits);
public sealed record PurchaseUnit(string ReferenceId, string? CustomId, Money Amount);
public sealed record PayPalOrder(string Id, string Status, IReadOnlyList<OrderPurchaseUnit>? PurchaseUnits);
public sealed record OrderPurchaseUnit(Payee? Payee, OrderPayments? Payments);
public sealed record OrderPayments(IReadOnlyList<PayPalCapture>? Captures);
public sealed record PayPalCapture(string Id, string Status, Money Amount, Payee? Payee, string? CustomId,
                                   SupplementaryData? SupplementaryData);
public sealed record SupplementaryData(RelatedIds? RelatedIds);
public sealed record RelatedIds(string? OrderId);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
                             DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(TokenResponse))]
[JsonSerializable(typeof(PayPalError))]
[JsonSerializable(typeof(CreateOrderBody))]
[JsonSerializable(typeof(PayPalOrder))]
[JsonSerializable(typeof(PayPalCapture))]
internal sealed partial class PayPalJson : JsonSerializerContext;
```

- Callers decide what an issue means: the capture endpoint catches `HasIssue("ORDER_ALREADY_CAPTURED")`
  and books the order's existing capture (see [website-checkout.md](website-checkout.md#server-endpoints-aspnet-core));
  the processor maps 5xx/timeouts to `Failed` (retry) and other 4xx to `DeadLetter`.
- Add refund (`POST v2/payments/captures/{id}/refund`) and `GET v2/payments/refunds/{id}` the same way.
- One app per tenant: resolve the tenant's credentials + base URL per call and put the tenant in `TokenKey`.

## SDKs

- **.NET:** NuGet `PayPalServerSDK` (repo `paypal/PayPal-Dotnet-Server-SDK`) — covers Orders v2,
  Payments v2, Transaction Search v1, Vault v3 (US), Subscriptions v1. **No webhook API and no signature
  verification helper** — implement those over `HttpClient` (see [webhooks.md](webhooks.md)).
- `PayPal` (PayPal-NET-SDK) and `PayPalCheckoutSdk` NuGet packages are **deprecated** — don't add them to
  new code; migrate existing usage to `PayPalServerSDK` or plain `HttpClient`.
- Calling the REST API directly with a typed `HttpClient` (+ resilience handler, + cached token) is a
  perfectly good alternative — the API surface for checkout is small ([sketch above](#typed-client-sketch-ipaypalclient)).
- Check the SDK's README for its current coverage before assuming an endpoint exists in it.
