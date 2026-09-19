---
description: Write a design document (RFC) for a feature/system/migration before coding (tech-lead agent)
argument-hint: [proposal topic] (e.g. "converge the di-refactoring branch back into develop")
---

Write an RFC (design document) for a proposal that needs up-front design before code.

1. Proposal topic: "$ARGUMENTS" — if blank, ask what is being designed before continuing.
2. Dispatch the **tech-lead** agent with that topic plus any context from this conversation. The agent
   verifies the background against the repo, forces explicit non-goals, weighs alternatives, plans
   migration/rollout and risks, lists honest open questions, writes the RFC to `docs/rfc/`, and
   regenerates `docs/rfc/index.md`.
3. If the RFC is being accepted now, have the agent also author the resulting ADR(s) itself by following
   `noobit:adr` (the same agent produces them — no separate dispatch) and cross-link them both ways.
4. Relay its report: the RFC path, whether the index was regenerated, any ADRs spawned, and any background
   claims it could not verify.
5. Show me the result: `git status --short docs/rfc/ docs/adr/` and the contents of the new RFC.
