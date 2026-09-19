---
name: rfc
description: Use when a significant feature, system, or migration needs an up-front design document before code — weighing options, defining goals and non-goals, proposing architecture/data-model/API, and planning migration, rollout, and risks; when someone says "let's write an RFC / design doc / proposal", or a decision is too big or too expensive-to-reverse to just record as an ADR. Not for a decision already settled (use noobit:adr).
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

## The record format (use exactly — do not add or drop sections)

```markdown
# <Title — the proposal as a short noun phrase>

- **Status** — <Draft|In Review|Accepted|Rejected|Implemented|Superseded> <YYYY-MM-DD>

## Background & motivation
<The problem, why it matters, why now. What's true about the codebase/system today — verified.>

## Goals
<What success looks like — the outcomes this design commits to.>

## Non-goals
<What this explicitly does NOT try to do. Naming these prevents scope creep and half the re-litigation.>

## Proposed design
<The architecture, data model, and API as relevant. Diagrams/tables where they earn their place.>

## Alternatives & trade-offs
<Each option seriously considered and its trade-offs: "Considered X; decided against because Y".>

## Migration & rollout
<How this ships without a freeze: sequencing, backward compatibility, feature flags/rings, cutover, backout.>

## Risks & mitigations
<What could go wrong and the mitigation for each. Be honest about the highest-risk step.>

## Open questions
<What is still undecided. An honest RFC carries these while in Draft/In Review; empty them before Accepted.
Once Accepted this reads "None remaining" (optionally noting what was resolved and how).>

## Decision
<Filled when Accepted/Rejected: the outcome and links to the resulting ADR(s) (`../adr/<file>.md`).
While in Draft, "TBD".>
```

## Location & naming

- **Folder:** `docs/rfc/` in the consuming repo.
- **Filename:** `YYYY-MM-DD-kebab-title.md` — date prefix = the RFC's creation date (it sorts the file);
  `kebab-title` is the H1 title kebab-cased. No `RFC-001` numbering. An RFC and its resulting ADR on the same
  topic may share a basename across the two folders — that's fine; the `docs/rfc/` vs `docs/adr/` path
  disambiguates.
- One proposal = one file.

## Status lifecycle

`Draft` → `In Review` → `Accepted` | `Rejected` → (`Implemented` | `Superseded`). Update the status line
(and its date) as the RFC moves. Unlike an Accepted ADR, an RFC's body may keep evolving **while in Draft
or In Review**; once `Accepted`, freeze the design and record changes of mind as new ADRs (or a superseding
RFC), not silent edits.

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

Rules: **newest date first**; one row per **date-named** RFC file (`YYYY-MM-DD-*.md`) — ignore `index.md`
and `README.md`; Date + Status come from the filename prefix and Status line; the **RFC** cell is the H1
title, verbatim; links are relative.

## Workflow

Authoring **and** evaluation are the job of the **`noobit:tech-lead`** agent.

- **If you are NOT the tech lead**: dispatch the `tech-lead` agent with the RFC topic and any context. Do
  not draft it yourself.
- **If you ARE the tech-lead agent**:
  1. **Frame** the problem: what is being designed, and why now.
  2. **Verify Background against the repo** — `git log`, `grep`, read the files. If a load-bearing premise
     is false, stop and report rather than design on it.
  3. **Draft** all sections. **Force explicit Non-goals.** Propose the design concretely.
  4. **Pressure-test with the decision lens** (expensive-to-reverse / 80/20 / one-year hindsight): make
     the alternatives and their trade-offs real, plan migration & rollout so it ships without a freeze, and
     name risks with mitigations. List **honest Open questions** — do not paper over the undecided.
  5. **Write** `docs/rfc/YYYY-MM-DD-kebab-title.md` and **regenerate** `docs/rfc/index.md`.
  6. **On acceptance**: set `Status` to `Accepted`, empty Open questions, fill `Decision`, and **author the
     resulting ADR(s) yourself by following the `noobit:adr` skill** — you are already the tech lead, so
     produce them directly, do not dispatch another agent. Each ADR links back to this RFC (`../rfc/…`) and
     this RFC's Decision links forward to them (`../adr/…`).
  7. **Report**: the path written, index updated, ADRs spawned/cross-linked, and any unverifiable claim
     (flagged as an Open question, not invented).

## Common mistakes

| Mistake | Fix |
|---|---|
| No Non-goals | Always state them — they prevent scope creep and re-litigation. |
| Design with no alternatives | Record each option and why-not; a one-option RFC isn't a design doc. |
| No migration/rollout plan | An RFC that can't ship incrementally isn't done — plan the cutover and backout. |
| Hides the undecided | Open questions are honest, not a weakness; empty them before Accepted. |
| Adds an `RFC-001` number | Date-named only. |
| Silently rewrites an Accepted RFC | Freeze on Accept; change of mind → new ADR or superseding RFC. |
| Never produces ADRs | An accepted RFC's decisions become ADRs, cross-linked both ways. |

## Template

Copy [references/template.md](references/template.md) for a blank RFC.
