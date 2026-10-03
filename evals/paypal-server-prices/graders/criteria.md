---
type: llm
weight: 2
---

PASS only if the answer:
- Says the browser must not send (or the server must ignore) the amount/currency: the server computes the
  price from its own data - a frozen checkout/basket snapshot - and creates the order with that amount.
- Has the server store the mapping (PayPal order id -> checkout, expected amount + currency) before returning
  the order id to the browser, so the capture/webhook can be checked against it.
- Keeps capture on the server as well (the browser sends ids only).
FAIL if it accepts the client amount with only a sanity/range check, or validates "amount > 0" as the fix.
