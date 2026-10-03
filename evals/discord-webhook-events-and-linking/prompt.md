---
name: discord-webhook-events-and-linking
description: "Webhook Events (installs, entitlements) into an EF Core inbox plus OAuth2 account linking behind the cookie BFF"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  Webhook Events endpoint: bounded raw body, Ed25519 verification at ingress (401), PING type 0 answered 204 with Content-Type, events stored raw in a scoped EF Core inbox (resolved from RequestServices) with a unique dedupe key and processed out of band; ENTITLEMENT_* noted as also on the gateway; OAuth2 linking behind the BFF as an external-login link: started by the signed-in user, local user bound in the OAuth state (the Strict session cookie is absent on the cross-site callback), provider identity in a temporary External cookie, link committed only by an antiforgery-validated POST, server-side code exchange that is not retried, identify scope, tokens never reach the browser; Discord is linked, not the login provider; tests.
---

We have an ASP.NET Core (.NET 10) SaaS behind nginx with a cookie-based BFF login. Our Discord app is now user-installable. We need two things: (1) know in our backend whenever someone installs or removes the app (guild or user install) and when they buy/cancel our premium SKU, and (2) a 'Connect Discord' button on the profile page so we can map a Discord user id to our account. We use EF Core with PostgreSQL. Implement it and make sure it builds.
