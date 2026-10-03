---
name: paypal-amount-mismatch
description: Captured amount/currency/payee mismatch must not be booked; resolve via own order mapping, not custom_id
tags: [paypal, security]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

In our PayPal integration the webhook processor looks up the checkout by the capture's custom_id and
marks it paid when the capture status is COMPLETED. Is there a problem with that? What exactly should
be checked before we mark a checkout as paid, and what should happen if a check fails? Short answer please.
