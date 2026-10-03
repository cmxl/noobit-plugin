---
name: trigger-mssql
description: Should trigger the mssql skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our SQL Server query that filters Orders by CustomerId and a date range got slow after the table hit 40M rows; the plan shows a clustered index scan. How do I find the right index? Short answer.
