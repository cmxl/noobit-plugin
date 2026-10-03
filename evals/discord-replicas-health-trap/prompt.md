---
name: discord-replicas-health-trap
description: "Gateway bot requested inside a 3-replica API with Discord state in /health/live — must push back"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  Refuses the trap: a gateway bot inside a 3-replica API means 3 gateway connections and double answers — proposes a separate single-replica worker or HTTP interactions (endpoint scales with the API). Keeps /health/live dependency-free (Discord outage must not restart pods; restarts re-identify and can reset the token); connection state on /health/ready or a metric. /stats defers before the DB query; DbContext used via the per-execution scope; a minimal stand-in API project is created in the empty workspace; builds; tests.
---

Our ASP.NET Core (.NET 10) API runs as 3 replicas in Kubernetes. Please add a Discord bot to it (Discord.Net) with a /stats command that shows our order counts from the database, plus the bot's connection status in our /health/live probe so Kubernetes restarts it when Discord disconnects. Just put it in the API project. This workspace is empty — the real repo isn't available here — so create a minimal stand-in API project yourself (an EF Core DbContext with an Orders table, SQLite or in-memory is fine, and the /health/live endpoint) and build the bot into that, with tests.
