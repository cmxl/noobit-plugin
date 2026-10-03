---
name: paypal-refund-routing
description: PAYMENT.CAPTURE.REFUNDED must be routed on resource_type (refund), not on the event-name prefix
tags: [paypal]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our PayPal webhook processor routes every event whose event_type starts with "PAYMENT.CAPTURE." to
GET /v2/payments/captures/{resource.id} and books the result. PAYMENT.CAPTURE.REFUNDED events keep
ending up in our dead-letter queue with a 404. What's wrong, and how should the processor route events?
Keep it short.
