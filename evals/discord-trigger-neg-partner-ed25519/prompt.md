---
name: discord-trigger-neg-partner-ed25519
description: "Must NOT trigger the discord skill (out of scope / other stack)"
tags: [trigger, discord]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Verify the Ed25519 signature on webhooks our partner sends to /hooks/partner. Short answer.
