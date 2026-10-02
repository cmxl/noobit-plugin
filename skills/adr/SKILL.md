---
name: adr
description: Use when recording or revisiting a technical/architecture decision — capturing why a choice was made, the context, and the consequences being accepted; writing an ADR / decision record (Nygard- or MADR-style); when someone says "let's record this decision", "document this trade-off", or an existing decision needs superseding. Not for narrating how a bug was fixed.
---

# Architecture Decision Records (Nygard + Alternatives)

## Overview

An ADR captures **one** significant technical decision so the *why* lives next to the *what* and
survives staff turnover. This skill writes lightweight records — Nygard's format plus an *Alternatives
considered* section (MADR-inspired, but not MADR's sections or `NNNN-` naming) — **no numbering**,
date-named, listed in a generated `index.md` ordered by date — and every record is authored and
pressure-tested by a **tech lead** so its context is verified and its consequences are honest.

**Core principle:** one decision per file · recorded at decision time · context checked against the real
repo, not asserted from memory.

**ADR vs RFC:** an ADR records a *settled* decision. When a decision needs up-front exploration (options,
data model/API, migration, rollout, risks), that work goes in an **RFC** first (`noobit:rfc`); the accepted
RFC then spawns one or more ADRs that link back to it. Use the ADR alone for a decision that needs no design
doc; use RFC→ADR for one that does.

**When an ADR is warranted:** the decision is expensive to reverse, or it affects other teams/services or
more than one feature (the tech-lead's expensive-to-reverse test). A cheap, local, easily reverted choice
needs no record.

## The record format (use exactly — do not add or drop sections)

```markdown
# <Title — the decision as a short noun phrase>

- **Status** — <Proposed|Accepted|Rejected|Deprecated|Superseded> <YYYY-MM-DD>   (see Status lifecycle)

## Context
<The forces and constraints at the time: what problem, what pressures, what's true about the
codebase/system right now. Verified against the repo (workflow step 2). Link the originating RFC or
superseded record here; add "Related: <PR/commit>" once the implementing change exists — the one
allowed append after acceptance besides the Status line.>

## Decision
<What we chose, stated plainly and actively: "We will …".>

## Alternatives considered
<One bullet per real option NOT chosen: "**Option** — rejected because …". This is the section that
stops a settled decision being re-litigated. Keep it distilled; if a full RFC explored the options,
summarise here and link to it (`../rfc/<file>.md`). If there was genuinely no alternative, keep the
heading and write "None — <why>".>

## Consequences
<The trade-offs being accepted — good and bad, and the second-order effects. What gets easier, what
gets harder, what we can no longer do, how reversible this is.>
```

That is the whole file — these six parts, in this order. **No number prefix, no other sections**
(no separate review/assessment block; deep option analysis belongs in the linked RFC, not here).

## Location & naming

- **Folder:** `docs/adr/` in the consuming repo.
- **Filename:** `YYYY-MM-DD-kebab-title.md` — the date prefix is the record's **creation** date and never
  changes (renaming breaks links), so records sort chronologically; `kebab-title` is the H1 title
  kebab-cased. No `0001-` numbering. If that filename already exists, make the title more specific.
- One decision = one file.

## Status lifecycle

The Status line carries the **current** status and the date it was set (so `Accepted 2026-09-14` on a file
created `2026-09-02-…`).

| Status | Meaning | Who sets it |
|---|---|---|
| `Proposed <date>` | Under discussion. The body may be edited freely. | New record (default) |
| `Accepted <date>` | Settled; the body is frozen. | New record if the call is already made, or a Proposed one once agreed |
| `Rejected <date>` | Considered and turned down; kept so it isn't re-proposed. Body frozen. | A Proposed record |
| `Deprecated <date>` | No longer applies, with no replacement decision. | An Accepted record |
| `Superseded <date> by [new title](new-file.md)` | Replaced by a newer record. | An Accepted record |

**Never edit an Accepted record's body.** To change or reverse it, write a *new* record that links back in
its Context and set the old one to `Superseded … by …`; to retire it with no replacement, set it to
`Deprecated`. Either way only the old record's Status line changes (plus, at most, the "Related:" line
for the implementing change).

## The index (`docs/adr/index.md`)

A **generated** table of contents, created if absent and rewritten wholesale on every add or status
change — never hand-edited.

```markdown
# Decision Records

<!-- BEGIN GENERATED -->
| Date | Decision | Status |
|------|----------|--------|
| 2026-08-20 | [Use martinothamar/Mediator, never MediatR](2026-08-20-mediator-over-mediatr.md) | Accepted |
| 2026-08-02 | [Adopt FusionCache as the only cache abstraction](2026-08-02-fusioncache-only.md) | Accepted |
<!-- END GENERATED -->
```

Rules: **newest filename date first**, ties by title A→Z; one row per **date-named** record file
(`YYYY-MM-DD-*.md`) — ignore `index.md`, `README.md`, and any **numbered legacy ADRs**; Date comes from the filename prefix; Status is the
status word from the Status line (`Superseded` rows keep the "by [title](file.md)" link; `Rejected` and
`Deprecated` rows stay listed). The **Decision** cell is the record's H1 title, verbatim. Links are relative.
`docs/README.md` links `adr/index.md` (per `noobit:docs-maintenance`), not the individual records.

**Pre-existing numbered ADRs** keep their own index and are left untouched — this skill owns only
`index.md` and the date-named records it creates. When a legacy `README.md` index exists, the generated
block starts with one line linking it, so readers find both sets. Renaming the legacy set to date-named
files is a separate, explicit migration (it breaks every inbound link) — propose it, don't do it as a side
effect.

## Workflow

Authoring **and** evaluation are the job of the **`noobit:tech-lead`** agent.

- **If you are NOT the tech lead** (you're the main session or another agent): dispatch the
  `noobit:tech-lead` agent with the decision topic and any context you have. Do not draft the record yourself.
- **If you ARE the tech-lead agent** (dispatched, or explicitly told to act as tech lead): do the work —

  1. **Gather** the decision: what is being decided, and why now.
  2. **Verify the Context against the repo** (Rule 1) — `git log`, `grep`, read the actual files. Correct
     any claim that doesn't hold; if a premise is false, say so and stop rather than record a decision
     built on it.
  3. **Draft** the six-section record, including the real **Alternatives considered** (option + why-not).
  4. **Stress-test the Consequences** with the decision lens defined in the `noobit:tech-lead` agent —
     *expensive-to-reverse* (how costly is undoing this?), *80/20* (does it serve the common case?),
     *one-year hindsight* (what would we regret?): second-order effects, reversibility, what breaks, what
     you can no longer do, who else is affected. **Fold the findings back into Context, Alternatives, and Consequences** —
     the file keeps its six parts; the review does not become a separate section.
  5. **Write** `docs/adr/YYYY-MM-DD-kebab-title.md`.
  6. **Regenerate** `docs/adr/index.md` (scan the folder, rebuild the table between the markers).
  7. **Report**: the path written, the index updated, and any claim you could **not** verify (flagged, not
     invented).

## Common mistakes

| Mistake | Fix |
|---|---|
| Adds a `0001-` number | This convention is unnumbered — date-named only. |
| Adds a separate review/assessment section | Six parts only: Title, Status, Context, Decision, Alternatives considered, Consequences. |
| Leaves out real alternatives | Record each option not taken and why — that's what prevents re-litigation. |
| Skips `index.md` or hand-edits it | Regenerate it wholesale every time; it's generated. |
| Skips the tech-lead evaluation | Every record is tech-lead authored — context verified, consequences stress-tested. |
| Asserts context from memory | Context is checked against the live repo; unverifiable claims are flagged. |
| Edits an Accepted decision | Supersede (or deprecate) via a new record; only the old Status line changes. |
| Renames the file when the status changes | The filename date is the creation date and never changes. |
| Deletes a turned-down proposal | Mark it `Rejected` — it stops the idea being re-proposed. |
| Writes to a random folder | Records live in `docs/adr/`. |

## Template

Copy [references/template.md](references/template.md) for a blank record.
