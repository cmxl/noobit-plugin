---
name: discord-http-ticket
description: "Three replicas, no websocket: HTTP interactions endpoint with modal, V2 ticket card and contended Claim button"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  HTTP interactions endpoint: raw body, Ed25519 verification with 401, PING, RunMode.Async + TaskCompletionSource callback, RestInteractionModuleBase<RestInteractionContext> modules, explicit ComponentsV2 flag, modal with Label-based inputs (IModal), stateless custom ids with ticket id, update-message on claim/close, logged-in rest client for follow-ups, root service provider, portal setup incl. Interactions Endpoint URL + public key; tests; builds.
---

Our web app runs as 3 replicas behind nginx (ASP.NET Core, .NET 10) and we don't want a long-running websocket bot. We want a /ticket slash command in Discord that opens a form (title, description, priority low/medium/high), and when submitted posts the ticket as a card in the channel with Claim and Close buttons that anyone on the team can press (claim should show who claimed it). Use Discord.Net. Give me the implementation, a short setup guide for the Discord developer portal, and make sure it compiles.
