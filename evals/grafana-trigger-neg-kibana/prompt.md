---
name: grafana-trigger-neg-kibana
description: "Kibana/Elasticsearch dashboards must not trigger the grafana skill"
tags: [trigger, grafana]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

How do I export our Kibana dashboards as saved objects and import them into another Kibana instance from CI? Short answer.
