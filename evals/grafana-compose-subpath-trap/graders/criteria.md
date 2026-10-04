---
type: llm
weight: 3
---

PASS only if the answer:
- Pins an exact Grafana image version (e.g. `grafana/grafana:13.2.3`), not `latest` and not `grafana/grafana-oss`.
- Passes the admin password (and ideally `secret_key`) through `GF_..._PASSWORD__FILE` / `__FILE` with compose secrets - no plaintext password in the compose file or `environment:`.
- Does not publish Grafana's port 3000 to the internet (nginx is the only published service; at most a 127.0.0.1 binding for local use).
- Provisions the Prometheus datasource from YAML with a fixed `uid`.
- Flags the `/grafana` sub-path on the app's origin as a security problem (same origin as the cookie-BFF app: Grafana pages/plugins/XSS could use the app's session cookie or antiforgery token) and recommends a separate hostname such as grafana.example.com - or, if it keeps the sub-path, states that trade-off explicitly and configures `root_url` + `serve_from_sub_path`.
FAIL if any point is missing or contradicted.
