---
name: adr
description: Use when recording or revisiting a technical/architecture decision — capturing why a choice was made, the context, and the consequences being accepted; writing an ADR / MADR / decision record; when someone says "let's record this decision", "document this trade-off", or an existing decision needs superseding. Not for narrating how a bug was fixed.
---

# Architecture Decision Records (MADR-lite)

## Overview

An ADR captures **one** significant technical decision so the *why* lives next to the *what* and
survives staff turnover. This skill writes lightweight MADR records — **no numbering**, date-named,
listed in a generated `index.md` ordered by decision date — and every record is authored and
pressure-tested by a **tech lead** so its context is verified and its consequences are honest.

**Core principle:** one decision per file · recorded at decision time · context checked against the real
repo, not asserted from memory.

## The record format (use exactly — do not add or drop sections)

```markdown
# <Title — the decision as a short noun phrase>

- **Status** — <Proposed|Accepted|Superseded> <YYYY-MM-DD>   (superseded: add "by [title](file.md)")

## Context
<The forces and constraints at the time: what problem, what pressures, what's true about the
codebase/system right now. Verified against the repo — see Rule 1.>

## Decision
<What we chose, stated plainly and actively: "We will …".>

## Consequences
<The trade-offs being accepted — good and bad, and the second-order effects. What gets easier, what
gets harder, what we can no longer do, how reversible this is.>
```

That is the whole file. **No `## Options`, no `## Alternatives`, no number prefix, no extra sections.**

## Location & naming

- **Folder:** `docs/adr/` in the consuming repo.
- **Filename:** `YYYY-MM-DD-kebab-title.md` — the date prefix **is** the decision date (that is why no
  separate date field is needed and why records sort chronologically). No `0001-` numbering.
- One decision = one file.

## Status & superseding

- New record → `Proposed <today>` (or `Accepted <today>` if the call is already made).
- **Never edit an Accepted record's Decision.** To reverse or change it, write a *new* record and set the
  old one's status to `Superseded <date> by [new title](new-file.md)`; the new record links back in its
  Context. Both edits are allowed on the old file (status line only) — everything else stays frozen.

## The index (`docs/adr/index.md`)

A **generated** table of contents, created if absent and rewritten wholesale on every add or status
change — never hand-edited.

```markdown
# Decision Records

<!-- BEGIN GENERATED -->
| Date | Decision | Status |
|------|----------|--------|
| 2026-09-19 | [DI-refactoring convergence via per-app production cutovers](2026-09-19-di-refactoring-convergence.md) | Accepted |
| 2026-08-02 | [Adopt FusionCache as the only cache abstraction](2026-08-02-fusioncache-only.md) | Accepted |
<!-- END GENERATED -->
```

Rules: **newest decision date first**; one row per **date-named** record file (`YYYY-MM-DD-*.md`) — ignore
`index.md`, `README.md`, and any **numbered legacy ADRs**; Date + Status come from the record's filename
prefix and Status line; the **Decision** cell is the record's H1 title, verbatim. Links are relative.
Pre-existing numbered ADRs keep their own `README.md` index and
are left untouched — this skill owns only `index.md` and the date-named records it creates.

## Workflow

Authoring **and** evaluation are the job of the **`noobit:tech-lead`** agent.

- **If you are NOT the tech lead** (you're the main session or another agent): dispatch the `tech-lead`
  agent with the decision topic and any context you have. Do not draft the record yourself.
- **If you ARE the tech-lead agent** (dispatched, or explicitly told to act as tech lead): do the work —

  1. **Gather** the decision: what is being decided, and why now.
  2. **Verify the Context against the repo** (Rule 1) — `git log`, `grep`, read the actual files. Correct
     any claim that doesn't hold; if a premise is false, say so and stop rather than record a decision
     built on it.
  3. **Draft** the five-section record.
  4. **Stress-test the Consequences**: second-order effects, reversibility, what breaks, what you can no
     longer do, who else is affected. **Fold the findings back into Context and Consequences** — the file
     stays pure MADR; the review does not become a separate section.
  5. **Write** `docs/adr/YYYY-MM-DD-kebab-title.md`.
  6. **Regenerate** `docs/adr/index.md` (scan the folder, rebuild the table between the markers).
  7. **Report**: the path written, the index updated, and any claim you could **not** verify (flagged, not
     invented).

## Common mistakes

| Mistake | Fix |
|---|---|
| Adds a `0001-` number | This convention is unnumbered — date-named only. |
| Invents `## Options` / `## Alternatives` / a review section | Exactly five parts: Title, Status, Context, Decision, Consequences. |
| Skips `index.md` or hand-edits it | Regenerate it wholesale every time; it's generated. |
| Skips the tech-lead evaluation | Every record is tech-lead authored — context verified, consequences stress-tested. |
| Asserts context from memory | Context is checked against the live repo; unverifiable claims are flagged. |
| Edits an Accepted decision | Supersede with a new record; only the old status line may change. |
| Writes to a random folder | Records live in `docs/adr/`. |

## Template

Copy [references/template.md](references/template.md) for a blank record.
