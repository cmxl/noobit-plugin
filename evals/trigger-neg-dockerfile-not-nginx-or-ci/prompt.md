---
name: trigger-neg-dockerfile-not-nginx-or-ci
description: A Dockerfile caching question must not load nginx-deploy or ci-pipelines
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our .NET 10 Dockerfile copies the whole src folder before dotnet restore, so every code change re-restores packages. How should the Dockerfile be ordered? Short answer.
