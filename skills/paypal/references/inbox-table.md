# Webhook inbox — table design and processing

A **webhook inbox** (staging table) stores every delivery verbatim before any logic, acknowledges
PayPal, and lets a separate processor do verification, tenant resolution and booking with retries.
It is the standard pattern for payment webhooks: nothing is lost to a bug, a deploy, or an
unexpected payload shape, and every event can be replayed after a fix.

The table is written for PayPal (`provider = 1`) but nothing in it is PayPal-specific; another payment
provider's webhooks can share it with their own `provider` value and dedup rule.

## Where the table lives

Put it where **every** delivery can land before the tenant is known — the shared/system database in a
multi-tenant system, not a per-tenant database. `tenant_id` is **nullable** and filled by the processor.
If your ORM applies a global tenant query filter, exclude this table from it (or the processor and
support tools can't see unmatched rows).

## Schema (SQL Server)

```sql
CREATE TABLE dbo.webhook_inbox (
    id                BIGINT             IDENTITY (1, 1) NOT NULL,
    -- written at receipt: envelope only, no business logic
    provider          TINYINT            NOT NULL,  -- 1 = PayPal, 2 = …
    environment       VARCHAR (10)       NOT NULL,  -- sandbox | live
    dedup_key         VARCHAR (100)      NULL,      -- PayPal: event id (WH-…); NULL if body unparseable
    event_type        VARCHAR (100)      NULL,      -- PAYMENT.CAPTURE.COMPLETED, …
    resource_id       VARCHAR (64)       NULL,      -- capture / order / refund id, for lookups
    request_path      VARCHAR (400)      NOT NULL,  -- carries a tenant key when the URL is per tenant
    headers           NVARCHAR (MAX)     NOT NULL,  -- PAYPAL-TRANSMISSION-* etc. as JSON
    body              NVARCHAR (MAX)     NOT NULL,  -- raw payload, verbatim — deliberately NO ISJSON check
    received_at       DATETIMEOFFSET (7) NOT NULL,
    -- resolved by the processor
    tenant_id         INT                NULL,
    signature_status  TINYINT            NOT NULL CONSTRAINT df_webhook_inbox_sig      DEFAULT (0), -- 0 unverified, 1 valid, 2 invalid
    -- processing state
    status            TINYINT            NOT NULL CONSTRAINT df_webhook_inbox_status   DEFAULT (0),
    attempts          INT                NOT NULL CONSTRAINT df_webhook_inbox_attempts DEFAULT (0),
    next_attempt_at   DATETIMEOFFSET (7) NOT NULL,
    locked_until      DATETIMEOFFSET (7) NULL,
    processed_at      DATETIMEOFFSET (7) NULL,
    last_error        NVARCHAR (4000)    NULL,
    row_version       ROWVERSION         NOT NULL,
    CONSTRAINT pk_webhook_inbox PRIMARY KEY CLUSTERED (id)
);

-- idempotency: a PayPal retry carries the same event id
CREATE UNIQUE NONCLUSTERED INDEX ux_webhook_inbox_dedup
    ON dbo.webhook_inbox (provider, environment, dedup_key) WHERE dedup_key IS NOT NULL;

-- work queue: filtered, stays small because finished rows drop out
CREATE NONCLUSTERED INDEX ix_webhook_inbox_queue
    ON dbo.webhook_inbox (next_attempt_at) INCLUDE (status, locked_until)
    WHERE status IN (0, 1, 3);

-- support / processor lookups
CREATE NONCLUSTERED INDEX ix_webhook_inbox_resource
    ON dbo.webhook_inbox (resource_id) WHERE resource_id IS NOT NULL;
CREATE NONCLUSTERED INDEX ix_webhook_inbox_tenant
    ON dbo.webhook_inbox (tenant_id, received_at) WHERE tenant_id IS NOT NULL;
```

Filtered indexes require `SET QUOTED_IDENTIFIER ON` (the default for SSMS, sqlpackage/DACPAC and
ADO.NET; plain `sqlcmd` needs `-I`) — otherwise index creation and inserts fail with error 1934.

### Status values

| Value | Status | Meaning |
|---|---|---|
| 0 | Pending | Stored, not yet processed |
| 1 | Processing | Claimed by a worker until `locked_until` |
| 2 | Processed | Booked (or confirmed already booked) |
| 3 | Failed | Transient error; retry at `next_attempt_at` (exponential backoff) |
| 4 | DeadLetter | Max attempts reached — alert, human looks |
| 5 | Ignored | Event type you deliberately don't handle |
| 6 | Unmatched | No tenant/order found — alert, keep for a human; **never delete** |
| 7 | Rejected | Signature invalid — alert; never booked |

### Why these choices

| Choice | Reason |
|---|---|
| `BIGINT IDENTITY` clustered key | Append-only inserts, no page splits, long-lived table |
| Raw `body` without `ISJSON` / native `json` type | A malformed delivery is exactly the one you must keep; the native `json` type normalizes text and would break byte-exact signature verification |
| Nullable `dedup_key` + **filtered** unique index | Unparseable bodies are still stored; duplicates of parseable ones are rejected |
| Dedup on event id, not `PAYPAL-TRANSMISSION-ID` | The transmission id changes per delivery attempt; the event id doesn't |
| `environment` in the dedup key | Sandbox and live events must never collide or be confused |
| `request_path` | Per-tenant-app setups carry the tenant key in the URL; without it the row can't be matched |
| `locked_until` lease | A worker that crashes mid-processing doesn't strand its rows |
| Timestamps set by the application | One clock (`TimeProvider` or your clock abstraction), testable; no DB `DEFAULT SYSUTCDATETIME()` drift |

## PostgreSQL variant

Same columns with `bigint GENERATED ALWAYS AS IDENTITY`, `smallint` for the enums, `timestamptz`,
`text` for headers/body (or `bytea` for byte-exact), no `rowversion` (use `xmin` for optimistic
concurrency). Partial indexes use the same `WHERE` clauses.

## Receiving (insert)

Plain `INSERT`; catch the unique violation (SQL Server 2601/2627, PostgreSQL `23505`) and return `200`.
This is race-free under concurrent duplicate deliveries — a "check, then insert" isn't. Any other
error → `5xx` so PayPal retries. Endpoint code: [webhooks.md](webhooks.md#4-receiving-endpoint-aspnet-core-minimal-api).


**The envelope columns (`dedup_key`, `event_type`, `resource_id`) come from an unverified body.** They
exist for dedup and support lookups only; the processor re-reads everything from the verified body.

## Claiming work (many workers, crash-safe)

Constants: `@max_attempts` (e.g. 10); lease length longer than worst-case processing of one row —
e.g. 5 minutes when a row makes two PayPal calls with a 30 s total timeout each.

SQL Server — first park poison rows (a row whose worker crashed or hung on every attempt), then claim:

```sql
UPDATE dbo.webhook_inbox
SET    status = 4, locked_until = NULL, last_error = CONCAT(last_error, N' | lease expired after max attempts')
WHERE  status = 1 AND locked_until < @now AND attempts >= @max_attempts;

UPDATE TOP (@batch) i
SET    status = 1, locked_until = @lease_until, attempts += 1
OUTPUT inserted.id, inserted.provider, inserted.environment, inserted.request_path,
       inserted.headers, inserted.body, inserted.attempts, inserted.locked_until
FROM   dbo.webhook_inbox i WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE  ((status IN (0, 3) AND next_attempt_at <= @now)
    OR  (status = 1 AND locked_until < @now))        -- reclaim leases of crashed workers
  AND  attempts < @max_attempts;
```

`UPDATE TOP` claims rows in no particular order. That's fine because processing doesn't depend on
order (the processor re-fetches current state). If you want approximate FIFO, claim through a CTE:
`WITH c AS (SELECT TOP (@batch) * FROM dbo.webhook_inbox WITH (UPDLOCK, READPAST, ROWLOCK) WHERE … ORDER BY next_attempt_at) UPDATE c SET …`.

PostgreSQL (same poison-row statement first):

```sql
UPDATE webhook_inbox i
SET    status = 1, locked_until = @lease_until, attempts = attempts + 1
WHERE  i.id IN (SELECT id FROM webhook_inbox
                WHERE ((status IN (0, 3) AND next_attempt_at <= @now)
                    OR (status = 1 AND locked_until < @now))
                  AND attempts < @max_attempts
                ORDER BY next_attempt_at
                LIMIT @batch
                FOR UPDATE SKIP LOCKED)
RETURNING i.id, i.provider, i.environment, i.request_path, i.headers, i.body, i.attempts, i.locked_until;
```

**Completing a row is fenced by the lease.** A worker that overran its lease must not overwrite the
result of the worker that reclaimed the row:

```sql
UPDATE dbo.webhook_inbox
SET    status = @final_status,            -- 2, 3, 4, 5, 6 or 7
       locked_until = NULL,
       processed_at = CASE WHEN @final_status = 2 THEN @now END,
       next_attempt_at = @next_attempt_at, -- only meaningful for 3 (Failed)
       last_error = @error
WHERE  id = @id AND status = 1 AND locked_until = @my_lease;
-- 0 rows affected → the lease was lost; drop the result (the booking itself is idempotent)
```

Backoff for `Failed`: e.g. `next_attempt_at = now + min(2^attempts minutes, 1 hour)` plus jitter; on the
last attempt set `DeadLetter` instead.

Run the processor as a `BackgroundService` that polls every few seconds (new DI scope per batch). A queue
message after the insert can lower latency, but **the table stays the source of truth**; the poll
catches anything the queue loses.

## Processing one row

1. **Verify the signature** from raw `headers` + raw `body` — nothing in the body is trusted before this.
   Missing headers, body that isn't a JSON object, or a bad signature → `Rejected`.
   - *One app for everyone:* use the environment's `webhook_id`.
   - *One app per tenant:* resolve the tenant **only** from `request_path` (URL key) to pick its
     `webhook_id`; unknown key → `Rejected`.
2. **Parse** the verified body. Event types you don't handle → `Ignored`.
3. **Resolve the order** through your mapping table (below). Not found → `Unmatched`.
4. **Act on current PayPal state** (with that tenant's/environment's credentials):
   - `CHECKOUT.ORDER.APPROVED` → `GET` the order. `APPROVED` → capture it with
     `PayPal-Request-Id: capture:{orderId}` (the same key the website's capture endpoint uses).
     `ORDER_ALREADY_CAPTURED`, or the order is already `COMPLETED` → take the capture from the order.
     A "request with this id is still in progress"-type error → transient (`Failed`, retry).
   - `PAYMENT.CAPTURE.*` → `GET /v2/payments/captures/{id}`.
   - Refund events → `GET /v2/payments/refunds/{id}` (see [webhooks.md](webhooks.md) on refund resource shape).
5. **Book** through the shared booking routine (below) — the same one the synchronous capture path uses.
6. **Complete** with the fenced update: `Processed`, or `Failed` + backoff on a transient error.

**If the booking lives in a different database than the inbox** (e.g. per-tenant databases), steps 5
and 6 cannot share a transaction. A crash between them reprocesses the event — which is why booking
must be idempotent on the PayPal ids, not on the inbox row.

## The tables next to the inbox

The order mapping is written **before** the create-order response goes back to the browser; the
payment and refund tables are written by the booking routine. Put them where the business data lives.

```sql
CREATE TABLE dbo.paypal_order (
    paypal_order_id   VARCHAR (36)       NOT NULL CONSTRAINT pk_paypal_order PRIMARY KEY,
    environment       VARCHAR (10)       NOT NULL,
    tenant_id         INT                NOT NULL,
    checkout_ref      VARCHAR (100)      NOT NULL,  -- your frozen checkout/basket snapshot, not a mutable cart
    expected_amount   DECIMAL (19, 4)    NOT NULL,
    currency          CHAR (3)           NOT NULL,
    created_at        DATETIMEOFFSET (7) NOT NULL
);

CREATE TABLE dbo.paypal_capture (
    capture_id        VARCHAR (36)       NOT NULL CONSTRAINT pk_paypal_capture PRIMARY KEY,
    paypal_order_id   VARCHAR (36)       NOT NULL CONSTRAINT fk_paypal_capture_order REFERENCES dbo.paypal_order,
    amount            DECIMAL (19, 4)    NOT NULL,
    currency          CHAR (3)           NOT NULL,
    status            VARCHAR (20)       NOT NULL,  -- PENDING, COMPLETED, PARTIALLY_REFUNDED, REFUNDED, DECLINED, FAILED
    status_rank       TINYINT            NOT NULL,  -- forward-only ordering, see below
    reversed          BIT                NOT NULL CONSTRAINT df_paypal_capture_reversed DEFAULT (0),
    updated_at        DATETIMEOFFSET (7) NOT NULL
);

CREATE TABLE dbo.paypal_refund (
    refund_id         VARCHAR (36)       NOT NULL CONSTRAINT pk_paypal_refund PRIMARY KEY,
    capture_id        VARCHAR (36)       NOT NULL CONSTRAINT fk_paypal_refund_capture REFERENCES dbo.paypal_capture,
    amount            DECIMAL (19, 4)    NOT NULL,
    currency          CHAR (3)           NOT NULL,
    status            VARCHAR (20)       NOT NULL,  -- PENDING, COMPLETED, FAILED, CANCELLED
    updated_at        DATETIMEOFFSET (7) NOT NULL
);
```

The upsert in the order-creation endpoint must be idempotent too: a retried create with the same
`PayPal-Request-Id` returns the same order id.

## The booking routine — a forward-only state machine

"Duplicate key = success" is **not** enough: one capture goes through several states under the same
capture id (`PENDING` → `COMPLETED` → `PARTIALLY_REFUNDED` → `REFUNDED`). A second event for a known
capture is usually a real state change, not a duplicate.

| Rank | Capture status | Business effect when the row first *enters* this rank |
|---|---|---|
| 1 | `PENDING` | Show "payment pending"; nothing paid yet |
| 2 | `COMPLETED` | **Mark the checkout paid** (exactly once) |
| 3 | `PARTIALLY_REFUNDED` | Record refund(s) |
| 4 | `REFUNDED` | Record refund(s); reverse the paid state if your domain needs it |
| 9 | `DECLINED` / `FAILED` | Payment failed — only valid from no row or rank 1 |

Rules:

1. **Check the money before rank 2:** captured `amount.value` + `currency_code` must equal
   `paypal_order.expected_amount` + `currency`, and the order's payee (`purchase_units[].payee.merchant_id`)
   must be your merchant account. Mismatch → don't book; `Unmatched` + alert (someone paid a different
   amount, or the order isn't yours).
2. **Upsert forward-only**, in one transaction with the business effect:
   `UPDATE … SET status = @s, status_rank = @r … WHERE capture_id = @id AND status_rank < @r
   AND (@r <> 9 OR status_rank <= 1)` — the last condition keeps a late `DECLINED`/`FAILED` from
   overwriting a paid or refunded capture (insert if the row doesn't exist; a unique-key race on
   insert → re-run the update). 0 rows updated = same or
   older state = no-op. The business effect runs only in the transaction that moved the rank.
3. **Refunds** upsert into `paypal_refund` keyed on `refund_id`; derive `PARTIALLY_REFUNDED`/`REFUNDED`
   from the re-fetched capture.
4. **Reversals** (`PAYMENT.CAPTURE.REVERSED`, chargebacks) set `reversed = 1` on the capture and alert —
   money that was paid is gone; a human decides what happens to the purchase.

## Resolving the order and tenant

The **only** proof that an event belongs to you is your own mapping: the PayPal order id is in
`paypal_order`, written when *your server* created the order. Capture resources carry
`supplementary_data.related_ids.order_id`; order events carry the order `id`.

- **`custom_id`** (≤ 255 chars, present on capture resources) is a **cross-check only**. Never
  resolve or book from it: anyone holding your public client id can create an order with any
  `custom_id` and amount (e.g. client-side order creation in JS SDK v5).
- **The URL key** (`request_path`) selects the tenant's `webhook_id` in per-tenant-app setups; the order
  mapping still has to match.
- **Refunds** made in the PayPal dashboard arrive as webhooks too; go from the refund to its capture
  (`links` with `rel: up`) to your mapping.

## Operations

- **Retention:** bodies contain payer name and e-mail (personal data). Purge `Processed`/`Ignored` rows
  after a defined period. `Rejected` rows are mostly junk from anonymous senders — purge them after a
  short period (e.g. 30 days). Keep `DeadLetter`/`Unmatched` until a human resolves them.
- **Alerts:** each `Unmatched` and `DeadLetter` row; `Rejected` by **rate** (a spike = attack or wrong
  `webhook_id`), not per row; any `Pending` older than a few minutes (processor down).
- **Replay:** after a fix, set affected rows back to `Pending` with `next_attempt_at = now` and
  `attempts = 0`. The forward-only booking makes replays safe.
- **Reconciliation** still runs separately: webhooks are best-effort. See [orders-payments.md](orders-payments.md#reconciliation).
