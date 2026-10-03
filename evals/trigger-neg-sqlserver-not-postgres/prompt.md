---
name: trigger-neg-sqlserver-not-postgres
description: A SQL Server tuning question must not load the Postgres or SQLite skills
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

A SQL Server stored procedure is fast for most customers but takes 40 seconds for one big customer; the plan was compiled for a small one. What is happening and how do I fix it? Short answer.
