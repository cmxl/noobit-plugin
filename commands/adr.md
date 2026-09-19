---
description: Record a technical/architecture decision as a MADR-lite ADR (tech-lead agent)
argument-hint: [decision topic] (e.g. "adopt FusionCache as the only cache")
---

Record a decision as an architecture decision record.

1. Decision topic: "$ARGUMENTS" — if blank, ask what decision is being recorded (or whether an existing one
   is being superseded) before continuing.
2. Dispatch the **tech-lead** agent with that topic plus any context from this conversation. The agent
   verifies the context against the repo, stress-tests the consequences, writes the record to `docs/adr/`,
   and regenerates `docs/adr/index.md`.
3. Relay its report: the record path, whether the index was regenerated, anything superseded, and any
   context claims it could not verify.
4. Show me the result: `git status --short docs/adr/` and the contents of the new record.
