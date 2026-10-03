---
name: paypal-already-captured
description: ORDER_ALREADY_CAPTURED during server-side capture is success, not an error
tags: [paypal]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

We capture PayPal orders in two places: the browser calls our /capture endpoint after onApprove, and our
webhook processor captures server-side when it gets CHECKOUT.ORDER.APPROVED (in case the browser never
came back). Sometimes the processor's capture call fails with 422 ORDER_ALREADY_CAPTURED and the event
retries until it is dead-lettered. How should we handle this race so the payment is booked exactly once?
Brief answer.
