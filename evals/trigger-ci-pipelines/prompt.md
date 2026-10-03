---
name: trigger-ci-pipelines
description: Should trigger the ci-pipelines skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Set up an Azure DevOps YAML pipeline for our .NET 10 + Angular app: build, run tests including Testcontainers integration tests, build the Docker image and deploy to our docker compose server. Outline the stages and key steps only.
