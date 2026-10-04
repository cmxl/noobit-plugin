---
name: grafana-trigger-push-dashboards
description: "Should trigger the grafana skill: dashboards as code to several instances"
tags: [trigger, grafana]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our Grafana dashboards live as JSON files in the repo. How should CI update them on our staging and production Grafana instances without clobbering anything? Short answer.
