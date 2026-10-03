---
name: discord-webhook-alert
description: "Nightly-job failure alert via a channel webhook, no bot, off the critical path"
tags: [discord, build]
runs: 1
max_turns: 60
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
expected_outcome: >-
  Channel webhook via DiscordWebhookClient (no bot token, no gateway); webhook URL treated as a secret from config; failure enqueued and posted by a background service, not inline in the job; AllowedMentions.None; link button or link only (no interactive components on an unowned webhook); error text truncated to limits; tests.
---

Our ASP.NET Core app (.NET 10) runs a nightly import job. When it fails we want a message in our #alerts Discord channel with the job name, the error summary and a link to the job's log page in our admin UI. We really don't want to run or maintain a Discord bot for this. Implement it and make sure it builds.
