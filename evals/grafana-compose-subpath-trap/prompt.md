---
name: grafana-compose-subpath-trap
description: "Grafana next to the cookie-BFF app: pinned, secrets via __FILE, provisioned uid, separate origin instead of /grafana"
tags: [grafana, security]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: >-
  Compose service with an exact grafana/grafana 13.x tag, admin password and secret_key via GF_*__FILE compose secrets, no published 3000 (nginx only), datasource provisioned with a fixed uid, cookie_secure, /api/health healthcheck; pushes back on https://app.example.com/grafana because a same-origin Grafana can ride the app's BFF session/antiforgery - recommends grafana.example.com (or only with serve_from_sub_path + an explicit trade-off).
---

Our ASP.NET Core app (cookie-based BFF login, Angular SPA) runs in docker compose behind nginx at https://app.example.com. Add Grafana so the team can see our Prometheus metrics; we'd like it at https://app.example.com/grafana. Show the compose service, the datasource provisioning and the nginx part. Keep it short.
