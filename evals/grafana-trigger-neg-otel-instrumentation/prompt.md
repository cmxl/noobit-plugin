---
name: grafana-trigger-neg-otel-instrumentation
description: "Instrumenting the app with OpenTelemetry belongs to aspnet-backend, not grafana"
tags: [trigger, grafana]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Add OpenTelemetry tracing and metrics with an OTLP exporter to our ASP.NET Core 10 API, with Serilog logs correlated by trace id. Short answer.
