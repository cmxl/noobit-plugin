# PayPal — official sources and how to dig through them

Verified 2026-10-02. When a fact isn't in this skill, look it up here **in this order**, cite the URL
you used, and mark anything you could not confirm on an official source as **UNVERIFIED** instead of
filling the gap from memory.

## 1. OpenAPI specs — the most exact source

`https://github.com/paypal/paypal-rest-api-specifications/tree/main/openapi` — machine-readable specs
for every REST API: field names, max lengths, enums, required headers, endpoint descriptions.

| Spec | Covers |
|---|---|
| `checkout_orders_v2.json` | Orders: create/patch/confirm/authorize/capture, `purchase_units`, `PayPal-Request-Id`, `Prefer` |
| `payments_payment_v2.json` | Authorizations, captures, refunds — the resources inside `PAYMENT.*` webhooks, plus sample webhook events (as operation `callbacks`) |
| `notifications_webhooks_v1.json` | Webhook CRUD, event types, events list/show/resend, simulate, verify-webhook-signature |
| `reporting_transactions_v1.json` | Transaction Search, balances |

Fetch the raw file (`https://raw.githubusercontent.com/paypal/paypal-rest-api-specifications/main/openapi/<file>`)
and search it — e.g. for a field's `maxLength` or an enum — instead of relying on prose pages.

## 2. developer.paypal.com

| Page | URL |
|---|---|
| Developer resources hub | https://developer.paypal.com/developer-resources |
| REST API index | https://developer.paypal.com/api/rest/ |
| Request conventions (base URLs, headers, idempotency) | https://developer.paypal.com/api/rest/requests/ |
| Authentication (OAuth 2.0) | https://developer.paypal.com/api/rest/authentication/ |
| Orders v2 error issues (e.g. `ORDER_ALREADY_CAPTURED`, `INSTRUMENT_DECLINED`, `PREVIOUS_REQUEST_IN_PROGRESS`) | https://developer.paypal.com/api/rest/reference/orders/v2/errors/ |
| Handle funding failures (`INSTRUMENT_DECLINED` → restart) | https://developer.paypal.com/v5/checkout/handle-funding-failure |
| PayPal IP ranges (allow-listing "not recommended") | https://www.paypal.com/us/cshelp/article/what-are-the-ip-addresses-for-paypal-nvpsoap-servers-ts1056 |
| Webhooks overview (retries, limits) | https://developer.paypal.com/api/rest/webhooks/ |
| Webhook integration + signature verification | https://developer.paypal.com/api/rest/webhooks/rest/ |
| Webhook event names | https://developer.paypal.com/api/rest/webhooks/event-names/ |
| Webhook simulator | https://developer.paypal.com/api/rest/webhooks/simulator |
| Orders v2 reference | https://developer.paypal.com/docs/api/orders/v2/ |
| Payments v2 reference | https://developer.paypal.com/docs/api/payments/v2/ |
| Transaction Search reference | https://developer.paypal.com/docs/api/transaction-search/v1/ |
| Server SDKs | https://developer.paypal.com/serversdk |
| Sandbox testing | https://developer.paypal.com/tools/sandbox/ (hub: `/sandbox-testing/overview/`) |
| Negative testing (forced errors in sandbox) | https://developer.paypal.com/tools/sandbox/negative-testing/ (hub: `/negative-testing/overview/`) |
| Card number generator (sandbox) | https://developer.paypal.com/tools/sandbox/card-testing/ (hub: `/credit-card-number-generator/`) |
| Upgrade hub (legacy → REST migration) | https://developer.paypal.com/upgrade/ |
| LLM-oriented index | https://developer.paypal.com/llms.txt |
| AI tools / MCP server | https://developer.paypal.com/ai-tools/mcp-server |

Pages move; if a URL 404s, start from the hub or `llms.txt` and follow links.

## 3. Other official channels

- **GitHub org:** https://github.com/paypal — server SDKs (`PayPal-Dotnet-Server-SDK`, `PayPal-TypeScript-Server-SDK`, …), specs. Sample apps: https://github.com/paypal-examples
- **.NET SDK:** NuGet `PayPalServerSDK` — README lists exactly which APIs it covers (no webhooks).
- **Postman workspace:** https://www.postman.com/paypal
- **API status:** https://www.paypal-status.com/api/production/
- **MCP server:** remote `https://mcp.sandbox.paypal.com` / `https://mcp.paypal.com` (`/sse` or `/http`), local `npx -y @paypal/mcp --tools=all`. Useful for exploring a sandbox account interactively; it is not a substitute for reading the spec when writing code.

## Known contradictions between official sources (as of 2026-10-02)

Treat these as open questions and verify against your own sandbox when they matter:

| Topic | Source A | Source B | Safe stance |
|---|---|---|---|
| Declined capture event name | event-names page: `PAYMENT.CAPTURE.DECLINED` under Payments v2; `.DENIED` under Payments v1 (deprecated) and Marketplaces/platforms | webhooks spec (simulate-event) mentions `.DENIED` | Subscribe to `DECLINED` (the v2 event); handling `DENIED` too is harmless. Confirm with `GET /v1/notifications/webhooks-event-types` |
| `PayPal-Request-Id` retention | Orders spec: 6 h (72 h via account manager) | requests page: "up to 45 days" (generic, refund example) — possibly per-API | Assume 6 h for orders; don't rely on it for long-delayed retries — use your own unique constraints |
| Resource of `PAYMENT.CAPTURE.REFUNDED` / `.REVERSED` | event-names page links inconsistent schemas | `payments_payment_v2.json` sample `PAYMENT.CAPTURE.REFUNDED` event: `resource_type: "refund"`, `links[] rel: up` → capture; no `.REVERSED` sample | Route on `resource_type` per event; re-fetch via API |
| `PAYPAL-AUTH-ALGO` header | integration page ("Integrate webhooks"): its header list names only `paypal-transmission-id`, `-transmission-time`, `-cert-url`, `-transmission-sig`, but its postback sample sends `"auth_algo": "SHA256withRSA"` | spec: `auth_algo` "extract from the PAYPAL-AUTH-ALGO header" | Store it; the postback requires `auth_algo`. `SHA256withRSA` is the only documented value — a different or missing value fails verification (`Rejected`), and the rejection-rate alert surfaces it |

**Not documented anywhere official** (state as assumption if you rely on it): delivery timeout value,
ordering guarantees (assume none), event retention/search window, cert-URL domain rules.

**Documented and easy to miss:** PayPal delivers webhooks **only to HTTPS on port 443** (integration and
simulator pages) — a listener on another port never receives anything.
