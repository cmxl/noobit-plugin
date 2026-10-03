---
name: trigger-sqlite
description: Should trigger the sqlite skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our .NET desktop app using Microsoft.Data.Sqlite randomly throws 'database is locked' when a background sync writes while the UI reads. How should SQLite be configured? Short answer.
