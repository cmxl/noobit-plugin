---
name: trigger-neg-angular-not-dotnet-testing
description: Angular e2e question must not load the .NET testing skill
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our Playwright e2e tests for the Angular app log in through the UI in every test and are slow. How do we log in once through our cookie BFF and reuse the session? Short answer.
