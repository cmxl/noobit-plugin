---
name: trigger-fusioncache-redis
description: Should trigger the fusioncache-redis skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our product catalog endpoint in ASP.NET Core hits the database on every request. How should I add caching with Redis across our 3 API instances, including invalidation when a product changes? Brief plan.
