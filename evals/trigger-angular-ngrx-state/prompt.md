---
name: trigger-angular-ngrx-state
description: Should trigger the angular-ngrx-state skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

In my Angular app several components need the same list of todos plus a filter, and they keep fetching it separately. Where should this state live and how would you structure it? Short answer.
