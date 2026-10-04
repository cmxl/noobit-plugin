# Dashboard design — panels that answer questions

Metric names, labels and queries below were run against a .NET 10 app (OpenTelemetry .NET 1.19,
`AddAspNetCoreInstrumentation()` + `System.Runtime` meter, OTLP → Prometheus/Loki/Tempo) through
Grafana 13.2.3, October 2026. Principles follow Grafana's dashboard best-practices page.

## Contents

1. [Principles](#1-principles)
2. [.NET metric names and labels](#2-net-metric-names-and-labels)
3. [PromQL patterns](#3-promql-patterns)
4. [Variables](#4-variables)
5. [Panels: units, thresholds, layout](#5-panels-units-thresholds-layout)
6. [Logs and traces](#6-logs-and-traces)
7. [Review checklist](#7-review-checklist)

## 1. Principles

- **Every dashboard answers one question for one audience.** "Is the orders API healthy?" is a
  dashboard; "everything about orders" is sprawl.
- **Method per layer:**
  - **RED** (Rate, Errors, Duration) for request-driven services. That's the starter template.
  - **USE** (Utilization, Saturation, Errors) for resources: CPU, memory, pools, queues.
  - The Four Golden Signals add saturation to RED.
- **Hierarchy:**
  - overview (one row per service);
  - service RED + runtime (the template);
  - deep dives (DB, cache, queue);
  - link them with dashboard links (tags) and data links instead of cramming.
- **Top-left is the verdict:** stat panels for the headline numbers, time series below for "since
  when", breakdowns last.
- **Maturity target** (Grafana's model, high end): version-controlled JSON, no editing in the browser
  on shared instances, a dev instance for changes, consistent naming and tags, and dashboards
  reviewed like code.
- Fewer, better dashboards. Delete what nobody opened in 90 days (usage insights are Enterprise-only, so ask the team).

## 2. .NET metric names and labels

How OpenTelemetry names arrive in Prometheus (OTLP translation: dots → underscores, unit suffix,
`_total` on counters):

| OTel instrument | Prometheus series | Use |
|---|---|---|
| `http.server.request.duration` (histogram, s) | `http_server_request_duration_seconds_bucket` / `_count` / `_sum` | Rate (`_count`), errors (status label), latency (`_bucket`) |
| `http.server.active_requests` | `http_server_active_requests` | In-flight requests (gauge-like) |
| `kestrel.active_connections`, `kestrel.queued_connections` | same with `_` | Connection saturation |
| `aspnetcore.routing.match_attempts` | `aspnetcore_routing_match_attempts_total` | Unmatched routes (404 noise) |
| `dotnet.process.cpu.time` (s) / `dotnet.process.cpu.count` | `dotnet_process_cpu_time_seconds_total` / `dotnet_process_cpu_count` | CPU usage per core |
| `dotnet.process.memory.working_set` | `dotnet_process_memory_working_set_bytes` | Memory |
| `dotnet.gc.pause.time`, `dotnet.gc.collections` | `dotnet_gc_pause_time_seconds_total`, `dotnet_gc_collections_total` | GC pressure |
| `dotnet.gc.last_collection.heap.size` | `dotnet_gc_last_collection_heap_size_bytes` | Heap after GC |
| `http.client.request.duration` (with `AddHttpClientInstrumentation`) | `http_client_request_duration_seconds_*` | Outbound dependency latency/errors |

Labels on the HTTP series:

- `job` = `service.name` (with `service.namespace`, if set, as prefix: `shop/orders-api`). Logs and
  traces key on the bare `service_name`, so the §6 queries using `$job` assume no namespace. With
  one, add a `service` variable (`label_values(target_info{job="$job"}, service_name)`) for them;
- `instance` = `service.instance.id`, a random GUID **per process start**. It's fine for "per
  instance" panels, but never put it in a variable or alert;
- `http_route` (the template, `/orders/{id:int}`), `http_request_method`, `http_response_status_code`;
- `url_scheme`, `network_protocol_version`; `error_type` appears only when an exception escaped the pipeline (a returned 500 has just the status code, verified).

Thread-pool series (`dotnet_thread_pool_*_total`) come out with ambiguous `_total` suffixes. Check
their type in Explore before graphing them.

**Scraped instead of OTLP?** With Prometheus scraping a `/metrics` endpoint (OpenTelemetry's
Prometheus exporter), `job` and `instance` come from the scrape config (`job_name`, the target
address), not from `service.name`. Set `job_name` to the service name so the template's `job`
variable still means "service". Set the datasource `timeInterval` to the `scrape_interval`. Metric
names stay the same. A different library (e.g. prometheus-net) uses different names, so adapt the
queries and check them in Explore first.

## 3. PromQL patterns

```promql
# Request rate (req/s)
sum(rate(http_server_request_duration_seconds_count{job="$job", http_route=~"$route"}[$__rate_interval]))

# 5xx error ratio (0..1, unit percentunit) — 4xx are the client's problem, chart them separately.
# `or vector(0)`: without a single 5xx there is no 5xx series, and the ratio would be "No data"
# exactly when the service is healthy (verified)
(sum(rate(http_server_request_duration_seconds_count{job="$job", http_route=~"$route", http_response_status_code=~"5.."}[$__rate_interval])) or vector(0))
/
sum(rate(http_server_request_duration_seconds_count{job="$job", http_route=~"$route"}[$__rate_interval]))

# p95 latency — aggregate buckets by le FIRST, then quantile; never average percentiles
histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{job="$job", http_route=~"$route"}[$__rate_interval])))

# p95 per route (keep le + the breakdown label)
histogram_quantile(0.95, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket{job="$job"}[$__rate_interval])))

# CPU per core, per instance
sum by (instance) (rate(dotnet_process_cpu_time_seconds_total{job="$job"}[$__rate_interval]))
  / on (instance) max by (instance) (dotnet_process_cpu_count{job="$job"})
```

Rules:

- **`$__rate_interval`, never a hard-coded `[1m]`.** It is at least 4 × the datasource's
  `timeInterval`. Set that to the OTLP export interval (.NET default 60 s; `OTEL_METRIC_EXPORT_INTERVAL`
  in ms) or the scrape interval. Otherwise `rate()` windows hold fewer than two samples and graphs
  break into gaps.
- **Aggregate before you divide or take quantiles** (`sum by (...)`), and keep only the labels the panel
  shows. `rate()` first, `sum` second, never the reverse.
- **Stat panels:** `rate` with *Calculation: Last (not null)*, or `increase(...[$__range])` for "how many
  today".
- **Top-N breakdowns:** `topk(10, ...)` with *Instant* off and a legend table sorted by max.
- **Recording rules** for expensive queries shared by many dashboards or alerts. They're defined
  next to the alert rules, not in the dashboard.

## 4. Variables

| Variable | Definition | Notes |
|---|---|---|
| `datasource` | type `datasource`, query `prometheus`, current `prometheus` | Panels use `{"type":"prometheus","uid":"${datasource}"}`; lets one dashboard switch backends |
| `job` | `label_values(http_server_request_duration_seconds_count, job)` | Single value; refresh on time range change (`refresh: 2`) |
| `route` | `label_values(http_server_request_duration_seconds_count{job="$job"}, http_route)` | Multi + Include All with `allValue: ".*"`, used as `http_route=~"$route"` |

- Chain variables (`route` depends on `job`) instead of listing everything.
- Never use variables over high-cardinality labels (`instance` GUIDs, user ids, raw paths).
- Ad-hoc filters are fine for exploration, but a managed dashboard should state its filters as
  variables.

## 5. Panels: units, thresholds, layout

- **Time series** for anything over time (the old `graph` panel was auto-migrated in 12, so don't
  author it), **stat** for headline numbers, **table** for breakdowns. Keep bar gauge, gauge and pie
  to a minimum.
- **Every panel has:**
  - a title that names the quantity (not "Panel 3");
  - a **description** saying what it measures and where from;
  - a **unit** (`reqps`, `s`, `percentunit`, `bytes`, `short`);
  - `min: 0` where negative values are impossible.
- **Thresholds carry meaning, not decoration:** green / orange / red at the SLO-ish levels
  (error ratio 1 % / 5 %, p95 0.5 s / 1 s in the template), with color mode "thresholds" on stat panels.
- **Consistent colors:** errors red, 4xx orange, the same series the same color across panels
  (overrides by regex, as in the template).
- **Layout:** 24-column grid; a stat row (h 4), then time series in pairs (w 12, h 8), with collapsible
  rows for secondary sections (runtime, dependencies). Shared crosshair (`graphTooltip: 1`).
- **Time/refresh:** default `now-6h`, refresh `1m`, or none for analysis dashboards. A refresh faster
  than the data's interval only adds load (`min_refresh_interval` clamps it).
- Library panels are folder-scoped and change everywhere at once. Use them for a panel truly shared by
  many dashboards, never as a copy-paste shortcut.

## 6. Logs and traces

With the datasources from self-hosting.md §4:

- **Logs panel (Loki):** `{service_name="$job"} | detected_level=~"error|warn"`. OTLP logs arrive with
  `service_name` as a label and `trace_id` / `span_id` / `severity_text` as structured metadata. The
  provisioned derived field turns `trace_id` into a "View trace" link.
- **Log volume:** `sum by (detected_level) (count_over_time({service_name="$job"}[$__auto]))`.
- **Traces table (Tempo, TraceQL):**
  `{ resource.service.name = "$job" && span.http.response.status_code >= 500 }`. Rows link to the
  trace, and the trace links back to its logs (`tracesToLogsV2`).
- **Exemplars** (latency dots that open the trace) need exemplar storage in Prometheus plus exemplars
  enabled in the .NET SDK. Optional, and check the docs for your Prometheus version (not verified here).

## 7. Review checklist

Run it on every dashboard PR (the stack reviewer can use it too):

- [ ] Resource file, `metadata.name` = file name = stable uid, folder annotation, `editable: false`
- [ ] Target folder is managed: humans View only, Edit for the deploy service account (the default *Editor role → Edit* removed)
- [ ] 5xx ratios use `or vector(0)` so a healthy service shows 0, not "No data"
- [ ] Datasources only as provisioned uids or `${datasource}`. No `${DS_*}`, no names, no `id`
- [ ] Every panel: title, description, unit; thresholds where there is a target
- [ ] Rates use `$__rate_interval`; quantiles via `histogram_quantile(..., sum by (le) ...)`
- [ ] Grouping by `http_route`, never raw path or `instance` in variables
- [ ] No panel duplicates another dashboard's job; links to the deeper dashboards exist
- [ ] Renders without errors on the dev instance with real data (`push -Context dev`, open it)
- [ ] `push-dashboards.ps1 -ValidateOnly` passes
