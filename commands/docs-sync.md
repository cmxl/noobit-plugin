---
description: Sync docs/ with the current code changes (docs-maintainer agent)
argument-hint: [base-ref] (default: uncommitted changes + last commit)
---

Bring `docs/` in sync with recent code changes.

1. Determine scope. Base ref argument: "$1" — if that is blank, use uncommitted changes (or, with a clean working tree, the last commit); otherwise use `git diff <base>...HEAD` with that ref as `<base>`.
2. Dispatch the **docs-maintainer** agent with that scope.
3. Relay its report: files updated/created, diagrams touched, links repaired, anything flagged as possibly stale.
4. Show me a compact summary of what it changed: `git diff --stat docs/` plus `git status --short docs/` (for newly created docs).
