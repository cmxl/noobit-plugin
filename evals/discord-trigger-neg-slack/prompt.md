---
name: discord-trigger-neg-slack
description: "Must NOT trigger the discord skill (out of scope / other stack)"
tags: [trigger, discord]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Build a Slack bot in .NET that answers /deploy commands and posts to a channel. Short answer.
