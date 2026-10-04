---
name: grafana-trigger-compose-setup
description: "Should trigger the grafana skill: self-hosting Grafana in compose"
tags: [trigger, grafana]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

We want Grafana next to our ASP.NET Core app in docker compose, with Prometheus as a provisioned datasource and the admin password not in the compose file. What does the service definition look like? Short answer.
