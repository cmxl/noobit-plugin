---
type: llm
weight: 2
---

PASS only if the answer:
- Explains that a PAYMENT.CAPTURE.REFUNDED event carries a refund resource (resource_type "refund"), so
  resource.id is the refund id and the captures endpoint returns 404.
- Says to route on the envelope's resource_type instead of the event-name prefix:
  refund -> GET /v2/payments/refunds/{id}, then find the capture via the links entry with rel "up";
  capture -> GET /v2/payments/captures/{id}.
- Says to act on the re-fetched current state (not the payload) and not to guess an endpoint for unknown
  resource types (dead-letter/alert).
FAIL if it suggests parsing the capture id out of the event name, or keeps routing on the prefix.
