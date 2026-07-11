---
description: Run the stack-reviewer agent on the current diff (or a given ref range)
argument-hint: [base-ref] (default: uncommitted changes)
---

Run an automated stack review.

1. Determine the diff scope. Base ref argument: "$1" — if that is blank, review uncommitted work (`git diff`, `git diff --staged`, plus untracked source files); otherwise review `git diff <base>...HEAD` with that ref as `<base>`.
2. If the scope is empty, say so and stop.
3. Dispatch the **stack-reviewer** agent with the scope description and wait for its findings.
4. Relay the findings table and verdict to me verbatim (severity, file:line, fix).
5. If there are BLOCKER or MAJOR findings: fix them, run the affected tests, then dispatch stack-reviewer once more on the updated diff to confirm the fixes (one re-review round only — if findings remain after that, list them and stop for my input). MINOR findings: fix inline if trivial, otherwise list them for me.

Do not commit anything as part of this command.
