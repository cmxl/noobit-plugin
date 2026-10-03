---
name: discord-gateway-status-and-deploy
description: "Gateway bot with a refreshable V2 status card plus a deploy endpoint that enqueues a channel post"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  Gateway bot hosted in the Generic Host with InteractionService, minimal intents, once-only event wiring and command registration, error handling via InteractionExecuted; Components V2 status card with a stateless refresh button (deferred update + edit); endpoint enqueues into a bounded channel and a background publisher posts via IDiscordClient with AllowedMentions.None; options for token/channel id; IHealthReporter defined by the model (interface + fake for tests) since the workspace is empty; tests; builds.
---

I have an ASP.NET Core (.NET 10) app for our internal tooling and want a Discord bot for our team server using Discord.Net. Two things: (1) a /status slash command that shows the health of our services (our real app has an IHealthReporter service that returns name + status + latency per service; it isn't in this empty workspace, so define that interface yourself plus a fake implementation for tests) as a nice-looking card with a Refresh button that updates the same message, and (2) whenever our deployment pipeline calls POST /api/deployments/{id}/finished on the app, the bot should post a 'deployment finished' message into our #deployments channel. Write the code as a small new solution I can drop in (create the projects — there is no existing code here) and make sure it builds.
