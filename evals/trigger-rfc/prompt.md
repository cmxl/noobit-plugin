---
name: trigger-rfc
description: Should trigger the rfc skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Before we start coding, I want a design document for migrating our monolith's order module to a separate service with its own database. What sections should that design doc have in our process? Short answer, no files.
