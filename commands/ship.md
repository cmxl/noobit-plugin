---
description: Run every quality gate on the current change and draft the commit — build, tests, coverage, stack review, docs sync
argument-hint: "[base-ref] (default: uncommitted changes)"
---

Take the current change through all quality gates from CLAUDE.md, in order, and stop at the first gate that cannot be made green.

Scope: base ref argument "$ARGUMENTS" — if blank, the uncommitted work (`git diff`, `git diff --staged`, untracked source files); otherwise `git diff <base>...HEAD`. If the scope is empty, say so and stop.

1. **Build** — `dotnet build` for every solution the scope touches (zero warnings), `npm run build` in each touched web app. Fix failures before continuing.
2. **Tests** — run the affected test projects (`dotnet test --project <path/to/Tests.csproj>` when `global.json` selects Microsoft.Testing.Platform, otherwise `dotnet test <path/to/Tests.csproj>`; Angular: `npx ng test --no-watch`). Integration tests need Docker — start it if needed (procedure in `noobit:dotnet-testing`); never skip silently.
3. **Coverage** — dispatch the **test-guardian** agent on the scope. If it reports a suspected implementation bug, stop and surface it to me before anything else.
4. **Review** — dispatch the **stack-reviewer** agent on the scope (now including any tests from step 3). Fix every BLOCKER and MAJOR, re-run the affected tests, and re-review once. Findings that remain after that round → list them and stop for my input.
5. **Docs** — if behavior, endpoints, config, events, or architecture changed, dispatch the **docs-maintainer** agent; a significant technical decision without a record → tell me which ADR is due (`/noobit:new-adr`).
6. **Commit message** — draft a Conventional Commits message (`type(scope): summary`, imperative, ≤ 72 chars; body explains *why*; reference the work item if one is known).

Then report a gate checklist with the real result of each step (pass / fixed / skipped + reason) and the drafted message. **Do not commit, push, or open a PR** unless I explicitly say so in my reply — then commit with that message, and for a PR use the repo's tracker (`gh` for GitHub, the `ado` MCP tools for Azure DevOps) with a description built from the checklist.
