---
name: trigger-adr
description: Should trigger the adr skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

We decided this week to use FusionCache instead of plain IDistributedCache across all our services. What is the exact format and location our team uses to record a settled decision like that? Short answer, no files.
