---
name: grafana-trigger-provisioned-save
description: "Should trigger the grafana skill on a symptom"
tags: [trigger, grafana]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Pushing a dashboard JSON to our Grafana via the HTTP API returns 400 "Cannot save provisioned dashboard". What does that mean and what should we change? Short answer.
