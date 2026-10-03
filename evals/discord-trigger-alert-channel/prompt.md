---
name: discord-trigger-alert-channel
description: "Should trigger the discord skill"
tags: [trigger, discord]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Post a message to our #alerts Discord channel from our .NET worker when the nightly import fails. Short answer.
