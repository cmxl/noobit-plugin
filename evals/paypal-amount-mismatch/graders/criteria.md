---
type: llm
weight: 2
---

PASS only if the answer:
- Says custom_id must not be used to resolve or book (anyone with the public client id can create an order
  with any custom_id and amount); the order must be resolved through the server's own mapping written at
  order creation (PayPal order id -> tenant/checkout/expected amount).
- Requires checking the captured amount AND currency against the expected values stored at order creation,
  AND that the payee (merchant id) is your own account.
- On a mismatch or missing mapping: do not book, mark the event Unmatched (or equivalent), alert, keep it
  for a human.
- Mentions verifying the webhook signature and re-fetching the capture from the API rather than trusting the
  payload status.
FAIL if it accepts custom_id as the lookup key or only checks the status.
