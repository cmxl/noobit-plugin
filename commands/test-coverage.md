---
description: Find untested changed behavior and write the missing tests (test-guardian agent)
argument-hint: [base-ref] (default: uncommitted changes + last commit)
---

Ensure changed behavior is covered by tests.

1. Determine scope. Base ref argument: "$1" — if that is blank, use uncommitted changes (or, with a clean working tree, the last commit); otherwise use `git diff <base>...HEAD` with that ref as `<base>`.
2. Dispatch the **test-guardian** agent with that scope.
3. Relay its report: coverage classification per change, tests it added, the test-run summary, and — prominently, first — any suspected implementation bugs it found.
4. If it reported implementation bugs, do not paper over them: surface them to me before anything else is done with that code.
