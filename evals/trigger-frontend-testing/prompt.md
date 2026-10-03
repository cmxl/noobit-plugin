---
name: trigger-frontend-testing
description: Should trigger the frontend-testing skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

How do I write Playwright e2e tests for our Angular app whose login is a cookie session from our ASP.NET Core backend with antiforgery tokens? I don't want to log in through the UI in every test. Short plan.
