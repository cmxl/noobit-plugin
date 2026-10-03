---
name: trigger-neg-docs-not-adr
description: Updating docs after a feature must not load the ADR skill
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

I added two new endpoints to our orders API. Which files in docs/ should I update and how should they cross-reference each other? Short answer.
