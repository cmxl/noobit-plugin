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
- **One app per tenant?** Then every API call — create, capture, the processor's re-fetch — uses that
  tenant's credentials, and the token cache is keyed per tenant + environment (single-flight refresh, so
  concurrent requests don't all fetch a new token).
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

## SDKs

- **.NET:** NuGet `PayPalServerSDK` (repo `paypal/PayPal-Dotnet-Server-SDK`) — covers Orders v2,
  Payments v2, Transaction Search v1, Vault v3 (US), Subscriptions v1. **No webhook API and no signature
  verification helper** — implement those over `HttpClient` (see [webhooks.md](webhooks.md)).
- `PayPal` (PayPal-NET-SDK) and `PayPalCheckoutSdk` NuGet packages are **deprecated** — don't add them to
  new code; migrate existing usage to `PayPalServerSDK` or plain `HttpClient`.
- Calling the REST API directly with a typed `HttpClient` (+ resilience handler, + cached token) is a
  perfectly good alternative — the API surface for checkout is small.
- Check the SDK's README for its current coverage before assuming an endpoint exists in it.
