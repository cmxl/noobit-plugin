# PayPal on a website — JS SDK v6 (and v5 for existing integrations)

Verified 2026-10-02 against https://developer.paypal.com/sdk/js/set-up.md, https://developer.paypal.com/sdk/js/reference,
https://developer.paypal.com/v5-v6, https://developer.paypal.com/docs/checkout/standard/integrate/,
https://developer.paypal.com/sdk/js/v5/best-practices (CSP) and the sample repos in https://github.com/paypal-examples.

## Which SDK

| Situation | Use |
|---|---|
| **New integration** | **JS SDK v6** — PayPal's recommendation ("For a faster, more secure integration, use the latest JavaScript SDK v6") |
| Existing v5 integration (`paypal.com/sdk/js?client-id=…`, `paypal.Buttons(...)`) | Keep running — PayPal labels v5 "deprecated" in the migration guide while the integration pages say it "remains supported"; no sunset date found. Plan migration with https://developer.paypal.com/v5-v6 |
| React | `@paypal/react-paypal-js` → import from `@paypal/react-paypal-js/sdk-v6` (`PayPalProvider`, `usePayPalOneTimePaymentSession`, `usePayPalCardFields`) |
| Bundler / SPA without React | `@paypal/paypal-js` → `loadCoreSdkScript({ environment: "sandbox" | "production" })` from `@paypal/paypal-js/sdk-v6` (`loadScript` is the v5 loader) |

`/sdk/js/reference` is now the v6 reference; the v5 SDK pages live under `/sdk/js/v5/` (reference, configuration, best practices incl. CSP) and some v5 guides under `/v5/`.
Official v6 sample (client + Node server): https://github.com/paypal-examples/v6-web-sdk-sample-integration.

## The flow (any SDK version)

The browser never decides the amount and never captures. It only asks **your** server to create an
order and, after approval, asks **your** server to capture it.

```text
Browser                         Your server                          PayPal
  click ──► POST /api/paypal/orders {checkoutId}
                                price frozen checkout server-side ─► POST /v2/checkout/orders
                                store orderId → checkout/tenant/amount ◄─ { id }
        ◄── { orderId }
  session.start(..., orderId) ───────────── buyer approves in PayPal popup/modal ─────────►
  onApprove({orderId}) ──► POST /api/paypal/orders/{id}/capture
                                verify order belongs to caller ───► POST /v2/checkout/orders/{id}/capture
                                book via the shared idempotent routine ◄─ capture
        ◄── result (COMPLETED / PENDING / declined)
```

Webhooks (`CHECKOUT.ORDER.APPROVED`, `PAYMENT.CAPTURE.*`) are the backup for buyers who close the tab
between approval and capture — see [webhooks.md](webhooks.md) and [orders-payments.md](orders-payments.md).

## v6 client

```html
<!-- sandbox: https://www.sandbox.paypal.com/web-sdk/v6/core -->
<script async src="https://www.paypal.com/web-sdk/v6/core" onload="onPayPalWebSdkLoaded()"></script>

<paypal-button hidden></paypal-button>
```

```javascript
async function onPayPalWebSdkLoaded() {
  const { clientId } = await getJson("/api/paypal/client-id");   // public value, per environment
  const sdk = await window.paypal.createInstance({
    clientId,
    components: ["paypal-payments"],
    pageType: "checkout",
  });

  const methods = await sdk.findEligibleMethods({ currencyCode: "EUR" });
  if (!methods.isEligible("paypal")) return;                    // keep the button hidden

  const session = sdk.createPayPalOneTimePaymentSession({
    async onApprove({ orderId }) {
      showResult(await postJson(`/api/paypal/orders/${orderId}/capture`));   // server's verdict, not the SDK's
    },
    onCancel() { /* buyer closed PayPal — nothing to do */ },
    onError(err) { showError(err); },                           // e.g. INSTRUMENT_DECLINED → offer another method
  });

  const button = document.querySelector("paypal-button");
  button.removeAttribute("hidden");
  button.addEventListener("click", async () => {
    // call createOrder() WITHOUT await before start() — keeps the click's transient activation for the popup
    await session.start({ presentationMode: "auto" }, createOrder());
  });
}

function createOrder() {
  return postJson("/api/paypal/orders", { checkoutId: currentCheckoutId })   // an id only — never amounts
    .then((data) => ({ orderId: data.id }));                    // v6 requires { orderId }
}

// Plain-JS pages only. In Angular, call createOrder/capture through an HttpClient-based service or store
// method with relative /api/... URLs — HttpClient adds X-XSRF-TOKEN itself; don't copy these helpers.
// Your app's normal API helper: same-origin cookies + your antiforgery header
// (here the common XSRF-TOKEN cookie → X-XSRF-TOKEN header convention).
async function postJson(url, body) {
  const xsrf = document.cookie.split("; ").find((c) => c.startsWith("XSRF-TOKEN="))?.split("=")[1];
  const res = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", ...(xsrf && { "X-XSRF-TOKEN": decodeURIComponent(xsrf) }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${url} failed: ${res.status}`);
  return res.json();
}

async function getJson(url) {
  const res = await fetch(url, { credentials: "same-origin" });
  if (!res.ok) throw new Error(`${url} failed: ${res.status}`);
  return res.json();
}
```

- **Authentication:** `clientId` is the recommended option and safe in frontend code. A `clientToken`
  (server-minted via `POST /v1/oauth2/token` with `response_type=client_token` and `domains[]`) is only
  needed for **Fastlane**. The set-up page's parameter table still calls `clientToken` "required" —
  the page text and the official sample use `clientId`.
- **Environment** is decided by the script host (`www.sandbox.paypal.com` vs `www.paypal.com`) or the
  loader's `environment` option — not by the client id. Serve the sandbox script with sandbox credentials only.
- Run initialization from the script's `onload` (not an inline script / `DOMContentLoaded`).
- Buttons: `<paypal-button>`, `<paypal-pay-later-button>`, `<paypal-credit-button>` — reveal each only
  when `isEligible("paypal" | "paylater" | "credit")`.
- `presentationMode`: `auto` (recommended: popup, modal fallback), `popup`, `modal` (WebViews), `redirect`
  (mobile; needs return/cancel URLs).
- `onError` codes include `ERR_DOMAIN_MISMATCH`, `ERR_DEV_UNABLE_TO_OPEN_POPUP`, `INSTRUMENT_DECLINED`, `NETWORK_ERROR`.
- Other components: `paypal-messages` (Pay Later messaging), `card-fields`, `venmo-payments`,
  `googlepay-payments`, `applepay-payments` (needs the Apple domain-association file), `fastlane`.
  Look up the reference before using any of them.

## Server endpoints (ASP.NET Core)

```csharp
// a CHILD of your existing /api group, so it inherits that group's auth + antiforgery endpoint filter.
// app.MapGroup("/api/paypal") would be a sibling and silently skip CSRF validation.
var paypal = api.MapGroup("/paypal");

paypal.MapGet("/client-id", (IOptions<PayPalOptions> o) => Results.Ok(new ClientIdResponse(o.Value.ClientId)));

paypal.MapPost("/orders", async (CreatePayPalOrderRequest req, ICheckoutService checkouts, IPayPalClient client,
                                 IPayPalOrderStore store, CancellationToken ct) =>
{
    // a FROZEN checkout snapshot (lines + prices fixed), owned by the caller — not a cart that can still change
    var checkout = await checkouts.GetOpenForCurrentUserAsync(req.CheckoutId, ct);
    if (checkout is null) return Results.NotFound();

    var amount = RoundForPayPal(checkout.Total, checkout.Currency);         // round ONCE; send and store the same value
    var order = await client.CreateOrderAsync(new CreateOrderBody(
        Intent: "CAPTURE",
        PurchaseUnits: [new PurchaseUnit(
            ReferenceId: checkout.Id.ToString(),
            CustomId: checkout.Reference,                                   // cross-check only, never proof
            Amount: new Money(checkout.Currency, amount.ToString(CultureInfo.InvariantCulture)))]),
        requestId: $"create:{checkout.Id}", ct);                            // PayPal-Request-Id

    // idempotent upsert: a retried create returns the same order id
    await store.UpsertAsync(order.Id, checkout.Id, checkout.TenantId, amount, checkout.Currency, ct);
    return Results.Ok(new CreateOrderResponse(order.Id));
});

paypal.MapPost("/orders/{orderId}/capture", async (string orderId, IPayPalOrderStore store, IPayPalClient client,
                                                   IPaymentBooking booking, CancellationToken ct) =>
{
    var mapping = await store.FindForCurrentUserAsync(orderId, ct);         // reject foreign/unknown order ids
    if (mapping is null) return Results.NotFound();

    var capture = await client.CaptureOrderAsync(orderId, requestId: $"capture:{orderId}", ct);
    // ORDER_ALREADY_CAPTURED (webhook path won the race) → GET the order and use its capture — see orders-payments.md
    var outcome = await booking.BookAsync(mapping, capture, ct);             // same forward-only routine as the webhook processor
    return Results.Ok(new CaptureResponse(outcome.Status));                  // COMPLETED / PENDING / DECLINED → UI message
});

// PayPal amounts are decimal strings with the currency's decimals: "10.00" EUR, "1000" JPY.
// The result carries its scale, so ToString(InvariantCulture) yields "10.00" / "1000".
static decimal RoundForPayPal(decimal value, string currency)
{
    var digits = currency is "JPY" or "HUF" or "TWD" ? 0 : 2;
    var rounded = decimal.Round(value, digits, MidpointRounding.AwayFromZero);
    return digits == 0 ? decimal.Truncate(rounded) : rounded + 0.00m;
}
```

Request/response types are plain records (`CreateOrderBody`, `PurchaseUnit`, `Money`, …) registered in
your source-generated `JsonSerializerContext` with snake_case naming — no anonymous types, so the code
works with reflection-free JSON.

- The browser sends **only** a checkout id; the server prices it. The official samples do the same
  (SKU + quantity in, server-side catalogue prices). Freeze the checkout before creating the order —
  otherwise a buyer can pay the old total and then change the cart.
- The order mapping stores the **expected amount and currency**; booking compares the captured amount
  against it before marking anything paid (see [inbox-table.md](inbox-table.md)).
- These endpoints are called from your own page by a signed-in or session-bound user: keep your normal
  auth and antiforgery/CSRF protection on them (unlike the anonymous webhook endpoint).
- Check the capture result: `COMPLETED` = paid; `PENDING` = not yet paid (tell the buyer, wait for
  the webhook); declined/`INSTRUMENT_DECLINED` = let the buyer choose another payment method.
- Never return the raw PayPal response to the browser — map it to what the UI needs.
- Zero-decimal currencies: check PayPal's currency-codes list (https://developer.paypal.com/api/rest/reference/currency-codes/)
  for every currency you accept; the three above are the zero-decimal ones PayPal lists today.

## Card fields (Expanded / Advanced Checkout)

- v6: load `components: ["card-fields"]`, check `isEligible("advanced_cards")`,
  `sdk.createCardFieldsOneTimePaymentSession()`, add `createCardFieldsComponent({ type: "number" | "expiry" | "cvv" | "name" })`
  elements to the page, then `const { data, state } = await session.submit(orderId, { billingAddress })` —
  `state` is `succeeded` (`data.liabilityShift`), `canceled` (3DS window closed — let them retry) or `failed`.
  Fields are PayPal-hosted iframes.
- v5: `paypal.CardFields({ createOrder, onApprove })` + `.isEligible()` + `NameField`/`NumberField`/`ExpiryField`/`CVVField`.
- **3D Secure:** request it on the order — `payment_source.card.attributes.verification.method` =
  `SCA_WHEN_REQUIRED` (or `SCA_ALWAYS`). Before capturing, check
  `payment_source.card.authentication_result` on the server (the JS SDK only sees `liability_shift`):
  - `liability_shift = POSSIBLE` → capture.
  - `liability_shift = NO` with `three_d_secure.enrollment_status` `N`, `U` or `B` (card not enrolled,
    system unavailable, authentication bypassed) → capture — rejecting these turns away valid cards.
  - Enrollment `Y` without `POSSIBLE`, or `liability_shift = UNKNOWN` → don't capture; ask the
    cardholder to retry.
  Full matrix: https://developer.paypal.com/docs/checkout/advanced/customize/3d-secure/response-parameters/
- Availability depends on country/currency (https://developer.paypal.com/docs/checkout/advanced/); check
  eligibility at runtime instead of assuming.

## Content-Security-Policy

PayPal's CSP page (written for v5; no separate v6 page yet) lists:

| Directive | Allow |
|---|---|
| `script-src`, `style-src` | `*.paypal.com *.paypalobjects.com *.venmo.com` + a nonce |
| `connect-src`, `frame-src`, `child-src` | `*.paypal.com *.paypalobjects.com *.venmo.com` |
| `img-src` | same + `data:` |

Prefer a nonce over `'unsafe-inline'`: v5 uses `data-csp-nonce="…"` on the script tag. Test the CSP in
the browser console with the sandbox before going live.

**Popup and cookie settings that a hardened app gets wrong:**

- `Cross-Origin-Opener-Policy: same-origin` (a common hardening default) breaks the PayPal popup. Serve
  checkout pages with `same-origin-allow-popups` — what the official v6 sample does.
- `presentationMode: "redirect"` returns the buyer from paypal.com with a top-level cross-site
  navigation, which doesn't carry a `SameSite=Strict` session cookie — the buyer lands logged out. Use
  popup/modal modes, make the return page work without the session (it only needs the order id to call
  your server again after a same-site reload), or use `SameSite=Lax` for that cookie.

## v5 in one paragraph (existing integrations)

`<script src="https://www.paypal.com/sdk/js?client-id=…&currency=EUR&intent=capture&components=buttons">` —
`currency`, `intent` and `commit` must match the order you create on the server; `buyer-country` is
sandbox-only. `paypal.Buttons({ createOrder, onApprove, style }).render("#paypal-button-container")`;
`createOrder` returns the order id string from your server; in `onApprove`, if the capture response has
`details[0].issue === "INSTRUMENT_DECLINED"`, `return actions.restart()`. Don't self-host or bundle the
SDK file. Sample: https://github.com/paypal-examples/docs-examples/tree/main/standard-integration.

## Sandbox testing

- Sandbox app in the Developer Dashboard → sandbox client id + secret (v6 no longer accepts the generic
  test client id).
- Sandbox accounts: a business and a personal account are created automatically; add more buyers under
  Sandbox → Accounts (https://developer.paypal.com/tools/sandbox/accounts/).
- Cards: https://developer.paypal.com/tools/sandbox/card-testing/ (generator + static test cards; special
  cardholder names such as `CCREJECT-REFUSED` simulate declines). 3DS scenarios:
  https://developer.paypal.com/v5/expanded/3d-secure/test-scenarios.

## Common mistakes

| Mistake | Fix |
|---|---|
| Amount sent from the browser to `create order` | Send a checkout id; price on the server from a frozen snapshot |
| Capturing in the browser / trusting `onApprove` as "paid" | Capture on the server; the capture status decides |
| Capture endpoint accepts any order id | Check the order id belongs to the caller's cart/session |
| v6 `createOrder` returns the id string | Return `{ orderId }` |
| `await createOrder()` before `session.start()` | Pass the promise; awaiting first can get the popup blocked |
| Showing buttons without the eligibility check | `findEligibleMethods` → reveal only eligible buttons |
| Sandbox script + live client id (or vice versa) | One environment setting drives script host, client id, API base URL and webhook id |
| New code on v5 | Use v6 |
