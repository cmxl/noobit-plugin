---
name: paypal
description: Use when integrating PayPal — website checkout (JS SDK v6/v5 buttons or card fields, createOrder/onApprove), Orders v2 create/capture/refund, PayPal webhooks (registration, PAYPAL-TRANSMISSION-SIG verification, PAYMENT.CAPTURE.* events, inbox table), reconciliation, sandbox/simulator testing, or PayPalServerSDK. Also when a PayPal payment or webhook went missing, was booked twice, or failed verification. Not for other payment providers (Stripe, Adyen, Mollie).
---

# PayPal (REST APIs + webhooks)

## Overview

PayPal tells you about money through two channels: the **synchronous API response** (create order →
capture) and **asynchronous webhooks**. Neither is reliable alone — the client can vanish before you
capture, webhooks can be late, duplicated, out of order, or forged. A correct integration makes both
channels converge on **one idempotent booking**, persists every webhook **raw, before any logic**, and
reconciles against PayPal's API.

**Facts change. When anything here is uncertain or a detail is missing, read the official source
(see [references/docs-map.md](references/docs-map.md)) instead of guessing — and say which source you used.**
The facts in this skill were verified against official docs and PayPal's OpenAPI specs on 2026-10-02.

## Reference files — load the one you need

| File | Read when |
|---|---|
| [references/docs-map.md](references/docs-map.md) | You need a fact not in this skill — where to look, in which order, and known contradictions between official sources |
| [references/website-checkout.md](references/website-checkout.md) | Putting PayPal on a website: JS SDK v6 (v5 for existing code), Angular service, buttons, card fields + 3DS, the create/capture server endpoints, CSP, sandbox testing |
| [references/webhooks.md](references/webhooks.md) | Registering a webhook, choosing event types, receiving endpoint code, signature verification (postback + offline), simulator, resend |
| [references/inbox-table.md](references/inbox-table.md) | Designing the webhook inbox/staging table, claiming work, statuses, tenant resolution, retention |
| [references/orders-payments.md](references/orders-payments.md) | Orders v2 flow, capture/refund, `PayPal-Request-Id` idempotency, `custom_id`/`invoice_id`, OAuth token, typed `IPayPalClient` sketch, statuses, reconciliation, SDK |

## Core rules

1. **The browser never sets the amount and never captures.** It sends a checkout id to your server,
   which prices a frozen snapshot and creates the order; after approval your server captures and
   decides what "paid" means.
2. **Store first, think later.** The webhook endpoint reads the raw body, saves body + headers to an
   inbox table, returns `2xx`. No deserialization into typed models, no tenant lookup, no business
   logic before the row is committed. A rejected or unparseable delivery is a lost event.
3. **Keep the raw bytes.** Signature verification (both methods) needs the body *exactly* as received —
   re-serialized JSON fails. Never bind with `[FromBody]` before saving.
4. **Return `2xx` only after the insert committed; `5xx` if it failed.** PayPal retries non-2xx up to
   25 times over 3 days — that is your safety net, so don't swallow storage errors.
5. **Deduplicate on the event `id`** (`WH-…`) with a unique index (+ environment). The id comes from an
   unverified body, so a duplicate insert has three outcomes ([webhooks.md §4](references/webhooks.md#4-receiving-endpoint-aspnet-core-minimal-api)):
   stored copy verified → `2xx`; stored copy still unverified and in flight → `503` (PayPal retries);
   stored copy `Rejected` or parked unverified → replace it with this delivery and verify again.
6. **Verify every event** (postback API or offline RSA/CRC32) in the processor, not at ingress, and
   **before reading anything from its body** — tenant lookups included. Failed verification or missing
   signature headers → status `Rejected`, never booked.
7. **Don't trust the payload's status/amount.** Re-fetch the resource named by `resource_type`
   (`capture` → `/v2/payments/captures/{id}`, `refund` → `/v2/payments/refunds/{id}` — never route on the
   event-name prefix: `PAYMENT.CAPTURE.REFUNDED` carries a refund) and book what PayPal's API says now.
   This also neutralises out-of-order delivery.
8. **One booking routine, forward-only.** The synchronous capture response and the webhook both call
   it. It upserts by capture id and only moves a capture forward (`PENDING` → `COMPLETED` →
   `PARTIALLY_REFUNDED` → `REFUNDED`); "already exists" is **not** "already done". "Paid" fires when the
   rank *crosses* `COMPLETED` (a capture first seen as `PARTIALLY_REFUNDED` was paid too), after checking
   captured amount + currency + payee against the values stored at order creation.
9. **Your order mapping is the only proof of ownership.** The processor resolves an event through the
   `(environment, paypal_order_id) → tenant/checkout/expected amount/payee` row your server wrote at order creation.
   `custom_id` is a cross-check, never a key. Not found → `Unmatched`, alert, keep the row.
10. **Reconcile.** A scheduled job checks orders stuck in APPROVED/PENDING via the API and sweeps
   Transaction Search (data appears with up to 3 h delay) — webhooks are not guaranteed delivery.
11. **Environments are separate worlds.** Sandbox and live have different base URLs, credentials,
    webhook ids and merchant ids. Store `environment` on every inbox row, in the dedup key and in the order-mapping key.

## Quick reference

| Thing | Value |
|---|---|
| Website SDK | **v6** for new code: `https://www.paypal.com/web-sdk/v6/core` (sandbox: `www.sandbox.paypal.com`), `paypal.createInstance({ clientId })`; v5 (`/sdk/js?client-id=`) is labelled deprecated — existing code only |
| Base URLs | sandbox `https://api-m.sandbox.paypal.com` · live `https://api-m.paypal.com` |
| OAuth | `POST /v1/oauth2/token` `grant_type=client_credentials`; cache the token until `expires_in` (minus a margin) — FusionCache, L1 only |
| Create / capture | `POST /v2/checkout/orders` → buyer approves (`rel: approve` link) → `POST /v2/checkout/orders/{id}/capture` |
| Idempotency | `PayPal-Request-Id` header on create, capture, authorize, refund (keep ≤ 108 chars — the Orders API limit) |
| Register webhook | `POST /v1/notifications/webhooks` — max 10 webhook URLs per app; save the returned `id` per environment |
| Verify (postback) | `POST /v1/notifications/verify-webhook-signature` → `verification_status: SUCCESS` |
| Verify (offline) | SHA256withRSA over `transmission_id\|transmission_time\|webhook_id\|crc32(raw body, decimal)` |
| Resend an event | `POST /v1/notifications/webhooks-events/{id}/resend` |
| Simulate | `POST /v1/notifications/simulate-event` or the dashboard simulator — mock data, **not** postback-verifiable |
| Reconcile | `GET /v1/reporting/transactions` — ≤ 31-day window, 3 years back, up to 3 h lag |
| .NET SDK | NuGet `PayPalServerSDK` (Orders, Payments, Transaction Search, Vault, Subscriptions) — **no webhook support**; old `PayPal` / `PayPalCheckoutSdk` packages are deprecated |

## Common mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| `[FromBody] WebhookModel` on the endpoint | Unexpected shape → 400 → event lost; raw bytes gone | Read `Request.Body` raw, save, then parse tolerantly |
| `CHECK (ISJSON(body) = 1)` / `event_id NOT NULL` on the inbox | Malformed delivery can't be saved | No JSON check, nullable envelope columns, filtered unique index |
| Business logic or tenant lookup before insert | "Not found → skip" silently drops real payments | Insert first; processor resolves, `Unmatched` status |
| Postback with `JsonSerializer.Serialize(parsedEvent)` | `FAILURE` on genuine events | Splice the stored raw body into the request JSON verbatim |
| Trusting `resource.status == COMPLETED` | Forged/stale events book money | Verify signature **and** re-fetch the capture |
| Routing `PAYMENT.CAPTURE.*` events to the captures endpoint | `REFUNDED` carries a refund id → 404 → DeadLetter | Route on `resource_type` |
| Webhook and capture response book separately | Double booking | Shared routine keyed on capture id |
| "Duplicate capture id = already booked" | `PENDING` stored first, `COMPLETED` later ignored — paid order never marked paid | Forward-only status upsert (see inbox-table.md) |
| Resolving the order from `custom_id` / not checking the captured amount | Someone pays 0.01 for your checkout | Resolve via your order mapping; compare amount + currency before booking |
| Server-side capture after `CHECKOUT.ORDER.APPROVED` treats `ORDER_ALREADY_CAPTURED` as an error | Retries forever / DeadLetter for a paid order | Treat it as success: GET the order, book its capture |
| Dedup on `PAYPAL-TRANSMISSION-ID` | Retries not deduplicated | Dedup on event `id` |
| Only one webhook id configured for all environments | Every sandbox (or live) verification fails | One webhook id per environment/app |
| Testing verification with simulator events via postback | Always `FAILURE` | Use real sandbox transactions, or offline-verify with webhook id `WEBHOOK_ID` |
| No retention on the inbox | Payer PII (name, e-mail) kept forever | Purge processed rows after a defined period |
