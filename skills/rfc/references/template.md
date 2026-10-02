# <Title — the proposal as a short noun phrase>

- **Status** — Draft <YYYY-MM-DD>
- **Authors** — <names> · **Discussion** — <PR link>   (optional — delete if unused)

## Background & motivation
<The problem, why it matters, why now. What is actually true about the codebase/system today (verified
against the repo, not asserted from memory).>

## Goals
<What success looks like — the outcomes this design commits to.>

## Non-goals
<What this explicitly does NOT try to do. Naming these prevents scope creep and half the re-litigation.>

## Proposed design
<The architecture, data model, and API as relevant. Mermaid diagrams/tables where they earn their place.>

### Cross-cutting: testing · security · performance · observability
<Test strategy; security impact (auth/BFF, CSRF, secrets); performance & caching; logging/metrics/alerts;
how success is measured. "n/a — <why>" per item rather than dropping it.>

## Alternatives & trade-offs
<Each option seriously considered and its trade-offs: "Considered X; decided against because Y".>

## Migration & rollout
<How this ships without a freeze: sequencing, backward compatibility, feature flags/rings, cutover, backout.>

## Risks & mitigations
<What could go wrong and the mitigation for each. Be honest about the highest-risk step.>

## Open questions
<What is still undecided. Resolve these before Accepted, then this reads "None remaining" (optionally
noting what was resolved and how). On Rejected, leave them as they stood.>

## Decision
<Filled when Accepted/Rejected: the outcome and links to the resulting ADR(s) (`../adr/<file>.md`);
on Rejected, the reason — no ADRs. While in Draft/In Review, "TBD".>
