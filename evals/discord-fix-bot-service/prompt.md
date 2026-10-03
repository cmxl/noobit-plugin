---
name: discord-fix-bot-service
description: "(run with --scaffold) Diagnose and fix a broken Discord.Net bot (duplicate commands, did not respond, token rotation, logging, /weather)"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  Identifies: handler subscribed inside Ready (duplicates after reconnect) + global re-registration on every Ready; no defer before slow I/O; forever-retry login and LoginAsync not validating token / reconnect loop; Trace-only log bridge without severity mapping; GatewayIntents.All needs privileged intents; no user-facing error reply; embed field limit 25; client disposed in StopAsync, overridden StartAsync without base; recommends InteractionService. Fixed code builds. Also flags /weather: raw user input interpolated into the query string (escape with Uri.EscapeDataString or a typed query builder) and HTTP I/O before responding without a defer.
---

Users of our Discord bot complain that commands sometimes run twice (they see the answer twice or an error), /report almost always says 'The application did not respond', and when we rotated the token last week the service just sat there spamming warnings instead of failing. Our ops people also say Discord errors never show up in our logs. The bot code is in DiscordBotService.cs in the current directory. Find the problems and give me a fixed version (keep Discord.Net), with a short explanation of each root cause.
