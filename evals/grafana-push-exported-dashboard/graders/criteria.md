---
type: llm
weight: 3
---

PASS only if the answer:
- Says the "sharing externally" export is the wrong artifact for an API/CLI push (its `__inputs` / `${DS_…}` placeholders leave panels without a datasource) and fixes it by any of: re-exporting without the toggle, replacing the placeholders with the instance's real/provisioned datasource uids, or replacing the file with the live dashboard pulled from the instance (e.g. `gcx resources pull`), which has real uids and no placeholders.
- Does NOT blindly overwrite: it first gets the live dashboard (pull/get/diff, or a drift check such as the `updatedBy` annotation / version comparison) and merges the UI edit into the repo file, or explicitly stops and asks - an unconditional `overwrite: true` / `--force` / last-write-wins push is a FAIL.
- Pushes with gcx (`gcx resources push`, possibly via a wrapper script) or the `/apis/dashboard.grafana.app` API with a service-account token. Using only the legacy `/api/dashboards/db` is acceptable only if it says that API is deprecated in Grafana 13.
- Recommends a way to avoid this next time (git as source of truth, no UI edits on that instance / read-only for people, or a drift-guarded pipeline).
FAIL if any point is missing or contradicted.
