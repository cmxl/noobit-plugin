---
name: grafana-push-exported-dashboard
description: "External-sharing export + UI edit since: push safely with gcx, no clobbering, no ${DS_*}"
tags: [grafana]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: >-
  Rejects the external-sharing export (__inputs / ${DS_*} placeholders break panels) in favour of provisioned datasource uids; stores the dashboard as a Grafana resource file (or pulls it with gcx); detects the UI edit before overwriting (pull + merge, drift check on updatedBy, or refuse) instead of a blind overwrite; pushes with gcx / the /apis API using a service-account token; mentions keeping prod read-only for people.
---

I exported our "Orders" dashboard from our self-hosted Grafana 13 via Share > Export with "Export for sharing externally" turned on, and committed it as dashboards/orders.json. Now I changed one panel query locally and want to update the dashboard on https://grafana.example.com. Someone also edited that dashboard in the UI last week. How do I push my change safely? Short answer with the concrete commands.
