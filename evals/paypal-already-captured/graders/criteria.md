---
type: llm
weight: 2
---

PASS only if the answer:
- Treats ORDER_ALREADY_CAPTURED (or an order already COMPLETED) as success: GET the order and take its
  capture, then run the normal booking.
- Has both paths call one shared, idempotent booking routine keyed on the capture id (forward-only status),
  so the browser path and the webhook path can't double-book.
- Uses the same PayPal-Request-Id (idempotency key, e.g. derived from the order id) on both capture calls.
FAIL if it only suggests dropping one of the two capture paths without idempotent booking, or treats
"row already exists" as "already done" without status handling.
