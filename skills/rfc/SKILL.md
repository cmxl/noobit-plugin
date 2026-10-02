---
name: rfc
description: Use when a significant feature, system, or migration needs an up-front design document before code — weighing options, defining goals and non-goals, proposing architecture/data-model/API, and planning migration, rollout, and risks; when someone says "let's write an RFC / design doc / proposal", or a decision is too big or too expensive-to-reverse to just record as an ADR. For a durable, reviewed design of a cross-team or expensive-to-reverse change — not a per-feature implementation design from brainstorming (that stays in work/specs/). Not for a decision already settled (use noobit:adr).
---

# Request for Comments (design document)

## Overview

An RFC is the **forward-looking** artifact: the design thinking a tech lead does *before* significant code
on a feature, system, or migration. It weighs options in the open, names what is explicitly **out** of
scope, and plans the rollout and risks — so review happens on the design, not on the merged code. It is
authored and pressure-tested by a **tech lead**.

**Core principle:** explore before building · make non-goals explicit · plan the rollout · context checked
against the real repo, not asserted from memory.

**RFC vs ADR:** the RFC *explores*; the **ADR** (`noobit:adr`) *records the settled call*. An accepted RFC
spawns one or more ADRs that link back to it. Reach for an RFC when the decision is expensive-to-reverse or
needs a design; a small, cheap-to-reverse decision goes straight to an ADR.

**RFC vs working spec:** an RFC is a durable, reviewed design for a cross-team or expensive-to-reverse
change. Per-feature implementation designs from brainstorming stay in `work/specs/` (never indexed) —
promote one to an RFC only when it needs review or a durable record.

## The record format (use exactly — do not add or drop sections)

```markdown
# <Title — the proposal as a short noun phrase>

- **Status** — <Draft|In Review|Accepted|Rejected|Implemented|Superseded> <YYYY-MM-DD>   (superseded: add "by [title](file.md)")
- **Authors** — <names> · **Discussion** — <PR link>   (optional)

## Background & motivation
<The problem, why it matters, why now. What's true about the codebase/system today — verified.>

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
<What is still undecided. An honest RFC carries these while in Draft/In Review. Resolve them before
Accepted, then this reads "None remaining" (optionally noting what was resolved and how). On Rejected,
leave them as they stood.>

## Decision
<Filled when Accepted/Rejected: the outcome and links to the resulting ADR(s) (`../adr/<file>.md`);
on Rejected, the reason — no ADRs. While in Draft/In Review, "TBD".>
```

That is the whole file — these parts, in this order. The only optional element is the Authors/Discussion
line; the Cross-cutting subsection is required.

## Location & naming

- **Folder:** `docs/rfc/` in the consuming repo.
- **Filename:** `YYYY-MM-DD-kebab-title.md` — date prefix = the RFC's creation date (it sorts the file);
  `kebab-title` is the H1 title kebab-cased. No `RFC-001` numbering. An RFC and its resulting ADR on the same
  topic may share a basename across the two folders — that's fine; the `docs/rfc/` vs `docs/adr/` path
  disambiguates. Keep the filename stable after creation even if the title changes; the index uses the H1.
- One proposal = one file.

## Status lifecycle

`Draft` → `In Review` → `Accepted` | `Rejected` → (`Implemented` | `Superseded`). Update the status line
(and its date) as the RFC moves. `In Review` = an open PR on the RFC file. **Only a human moves In Review →
Accepted/Rejected**; the agent records that outcome only when the caller states it.

Unlike an Accepted ADR, an RFC's body may keep evolving **while in Draft or In Review**. Once `Accepted` or
`Rejected` it is frozen: changes of mind become new ADRs (or a superseding RFC), not silent edits. After
that, only the status line may change (`Implemented <date>`, or `Superseded <date> by [new title](new-file.md)`
with the new RFC linking back in its Background) — plus Decision links to ADRs written later.

## The index (`docs/rfc/index.md`)

A **generated** table of contents, created if absent and rewritten wholesale on every add or status change
— never hand-edited.

```markdown
# RFCs

<!-- BEGIN GENERATED -->
| Date | RFC | Status |
|------|-----|--------|
| 2026-07-14 | [Adopt the outbox pattern for cross-service events](2026-07-14-outbox-for-cross-service-events.md) | Accepted |
<!-- END GENERATED -->
```

Rules: **newest date first**; one row per **date-named** RFC file (`YYYY-MM-DD-*.md`) — ignore `index.md`,
`README.md`, and any **numbered legacy RFCs** (e.g. `RFC-001-*.md`); Date + Status come from the filename
prefix and Status line; the **RFC** cell is the H1 title, verbatim; links are relative. Pre-existing
numbered RFCs keep their own `README.md` index and are left untouched — this skill owns only `index.md` and
the date-named RFCs it creates; when a legacy `docs/rfc/README.md` exists, `index.md` links it once. `docs/README.md` links `rfc/index.md` once, never the individual RFCs.

## Workflow

Authoring **and** evaluation are the job of the **`noobit:tech-lead`** agent.

- **If you are NOT the tech lead**: dispatch the `tech-lead` agent with the RFC topic and any context. Do
  not draft it yourself.
- **If you ARE the tech-lead agent**:
  1. **Frame** the problem: what is being designed, and why now.
  2. **Verify Background against the repo** — `git log`, `grep`, read the files. If a load-bearing premise
     is false, stop and report rather than design on it.
  3. **Draft** all sections. **Force explicit Non-goals.** Propose the design concretely.
  4. **Pressure-test with the tech-lead decision lens** — expensive-to-reverse (how costly to undo?), 80/20
     (common case served, edge cases as documented workarounds?), one-year hindsight (what would you
     regret?): make the alternatives and their trade-offs real, fill the Cross-cutting subsection, plan
     migration & rollout so it ships without a freeze, and name risks with mitigations. List **honest Open questions** — do not paper over the undecided.
  5. **Write** `docs/rfc/YYYY-MM-DD-kebab-title.md`, **regenerate** `docs/rfc/index.md`, and ensure
     `docs/README.md` links `rfc/index.md` (add it once if missing).
  6. **On acceptance** — only when the caller states a human accepted it: set `Status` to `Accepted`,
     resolve Open questions, fill `Decision`, and **author the
     resulting ADR(s) yourself by following the `noobit:adr` skill** — you are already the tech lead, so
     produce them directly, do not dispatch another agent. Each ADR links back to this RFC (`../rfc/…`) and
     this RFC's Decision links forward to them (`../adr/…`). **On rejection** (same condition): set
     `Rejected`, leave Open questions as they stood, put the reason in `Decision` — no ADRs.
  7. **Report**: the path written, index updated, ADRs spawned/cross-linked, and any unverifiable claim
     (flagged as an Open question, not invented).

## Common mistakes

| Mistake | Fix |
|---|---|
| No Non-goals | Always state them — they prevent scope creep and re-litigation. |
| Design with no alternatives | Record each option and why-not; a one-option RFC isn't a design doc. |
| No migration/rollout plan | An RFC that can't ship incrementally isn't done — plan the cutover and backout. |
| Hides the undecided | Open questions are honest, not a weakness; resolve them before Accepted. |
| Agent marks its own RFC Accepted | Only a human accepts/rejects; record it only when the caller says so. |
| Adds an `RFC-001` number | Date-named only. |
| Silently rewrites an Accepted RFC | Freeze on Accept/Reject; only the status line (+ Decision ADR links) may change. |
| Writes a brainstorming spec as an RFC | Per-feature implementation designs stay in `work/specs/`. |
| Never produces ADRs | An accepted RFC's decisions become ADRs, cross-linked both ways. |

## Template

Copy [references/template.md](references/template.md) for a blank RFC.
