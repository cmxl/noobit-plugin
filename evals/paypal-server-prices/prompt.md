---
name: paypal-server-prices
description: The browser must never set the amount; the server prices a frozen snapshot
tags: [paypal, security]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

I'm adding PayPal buttons (JS SDK) to our Angular checkout. In createOrder the component POSTs
{ cartId, amount: cart.total, currency: 'EUR' } to our ASP.NET Core endpoint, which forwards amount and
currency to POST /v2/checkout/orders. Is that OK? Answer briefly and sketch what the endpoint should do instead.
