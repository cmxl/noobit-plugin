---
name: trigger-postgres
description: Should trigger the postgres skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

A Postgres query on our events table (jsonb payload, 80M rows) takes 9 seconds; EXPLAIN ANALYZE shows a seq scan on payload->>'tenant'. What index should I add? Short answer.
