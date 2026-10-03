---
name: paypal-forged-first-dedupe
description: Forged event reusing a genuine event id must not swallow the real PayPal delivery
tags: [paypal, security]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our ASP.NET Core PayPal webhook endpoint stores each delivery in an inbox table with a unique index
on the PayPal event id and returns 200 on a duplicate-key error. A colleague says an attacker could
POST a junk event that reuses the `id` of a real event before PayPal delivers it, and then the genuine
delivery would be treated as a duplicate and dropped. Is that right? If so, explain briefly how the
endpoint and the processor should handle a duplicate event id. No full implementation needed.
