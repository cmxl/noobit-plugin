---
name: discord-trigger-double-answers
description: "Should trigger the discord skill"
tags: [trigger, discord]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

My Discord.Net bot answers every slash command twice since yesterday's deploy, and sometimes says 'This interaction has already been acknowledged'. What's going on? Short answer.
