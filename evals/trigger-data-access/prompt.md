---
name: trigger-data-access
description: Should trigger the data-access skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our EF Core query that loads customers with their orders is slow and the log shows hundreds of SELECTs per request. What's likely going on and how do I fix it? Short answer.
