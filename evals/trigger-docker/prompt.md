---
name: trigger-docker
description: Should trigger the docker skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our .NET 10 Dockerfile re-downloads all NuGet packages on every build even when only a .cs file changed. Why, and how should the Dockerfile be structured? Short answer.
