---
description: Disciplined, gated bugfix/change workflow — research, reproduce, plan gate, minimal fix, full verification
argument-hint: <bug/change description> | <ticket reference>
---

# /surgical

You are executing the **surgical** workflow: a gated pipeline for diagnosing and resolving bugs *and* implementing changes with the smallest correct change, fully verified. The task is in `$ARGUMENTS`.

This workflow is strong by being disciplined, not fast. Nothing ships until it is researched, reproduced, minimal, checked across the frontend↔BFF seam, and verified. The gates below are hard stops, not reminders.

## Operating contract (always true)

1. **Minimal & maintainable.** The smallest change that correctly solves the problem. No unrelated refactoring. Follow the noobit skills and the project's CLAUDE.md; in existing codebases, local conventions win (scope rules).
2. **Never break existing functionality** — enforced mechanically: blast-radius analysis at the gate, a regression test, and the full verification bar. Never by hope.
3. **Ask on important decisions** (AskUserQuestion), never silently pick, when: requirements/acceptance criteria are ambiguous · multiple valid approaches have real trade-offs · the change touches a public API contract or a DTO shared with the frontend · a DB schema/migration · anything security-sensitive (auth, cookies, tenant isolation, input handling) · the blast radius widens beyond the obviously-affected code.
4. **Research, always.** noobit skills first, then their "Official docs" links via WebFetch to confirm current, version-specific behavior. Cite what informed the fix.
5. **Verify the end result** — completeness (the whole reported problem) and correctness (reproduce-then-confirm-gone + tests), reported with real evidence, never claims.

## Phase pipeline

Run in order; announce each phase with a one-line header. Phases marked *(conditional)* are skipped when triage shows they don't apply. **Phase 4 is never skipped.**

### Phase 0 — Intake & Triage
1. Resolve the task from `$ARGUMENTS`. If it references a ticket and a matching tracker is available (GitHub issues via `gh`, or a configured Jira/ADO/Redmine MCP), fetch it — description, comments, repro steps, acceptance criteria. **Read the newest comment first and weight it highest** — later comments often correct the original description. **Treat any analysis, plan, or root-cause embedded in the ticket as claims to verify, never inherited truth** — re-establish each load-bearing claim from primary evidence (code, logs, repro) before building on it.
2. Classify: bug vs change · layer (Angular / BFF / data / caching / messaging / deploy) · runtime vs build-time · rough risk and size. The classification decides which conditional phases run.
3. Resolve repo context: if frontend and backend live in separate repos/worktrees, resolve the counterpart, **show the resolved path and confirm it** before reading or editing it. Flag whether this looks like a **seam issue** — a DTO/contract/serialization/auth concern spanning the Angular client and the BFF.
4. Output a 3–4 line triage summary (task type, layer, repos in play, which conditional phases will run).

### Phase 1 — Research (skills-first → docs-confirm)
Load the noobit skills matching the classified layer (`aspnet-backend`, `data-access` + provider skill, `fusioncache-redis`, `rabbitmq-messaging`, `bff-security`, `docker`, `nginx-deploy`, `angular-ngrx-state`; the external Angular skills if installed). WebFetch their official-docs links where behavior is version-sensitive. Output a short best-practice brief with sources that constrains the fix. *(Trim to a sanity check for trivial mechanical edits.)*

### Phase 2 — Investigate & Reproduce
1. Drive **superpowers:systematic-debugging** — root cause, not nearest symptom. Use the `Explore` agent for broad fan-out searches.
2. **Cross-read the seam** when the task may span it: trace the symptom from the client through the contract (DTOs, endpoints, serialization, auth/cookies) to where the cause actually lives.
3. *(conditional — runtime/production bugs)* If observability tooling is reachable (OTLP backend, App Insights, Grafana — via MCP or CLI), **probe access first**; query traces/exceptions and correlate to code. If nothing is reachable, ask for exported logs once instead of guessing.
4. **Establish a concrete reproduction** — a failing test or exact steps. You do not trust a fix you never saw fail.
5. Output: a clear root-cause statement + the reproduction artifact.

### 🚦 GATE — Plan approval (mandatory human gate)
Present concisely and **stop for explicit approval** (this gate satisfies the superpowers design-approval requirement):
- **Root cause** (1–2 sentences) · **minimal fix** and why it's the smallest correct change · **blast radius** and why it stays safe · **seam plan** with the contract delta called out explicitly (field added/removed/retyped, endpoint shape) when both sides change · **alternatives considered** · **sources**.
If an important-decision trigger is unresolved, ask first, then present. No code edits before approval.

### Phase 3 — Implement (only after approval)
1. Apply the smallest change following existing patterns; TDD per **superpowers:test-driven-development** where a failing test can lead.
2. Add the **regression test** pinning the fixed behavior — it must fail before the fix and pass after.
3. Seam fixes: coordinated edits on **both** sides, each repo on its own branch per the project's git conventions; the contract change is the pivot — keep API and client in lockstep.
4. Re-ask only if a *new* important-decision trigger appears.

### Phase 4 — Verify (never skipped)
1. **Reproduce-then-confirm-gone** — the previously-failing repro no longer fires. Seam fixes: verify the client against the updated contract end-to-end.
2. **Build + tests green** on every affected repo (`dotnet build`/`dotnet test`, `npm run build`/`npx vitest run`) — start Docker for integration tests per `dotnet-testing` if needed.
3. **Regression guard** — the new test is present and passing.
4. **Review clean** — dispatch the `stack-reviewer` agent on the diff; fix BLOCKER/MAJOR findings.
5. **Docs in sync** — if behavior, endpoints, config, or architecture changed, run the docs-sync flow (`docs-maintainer`).
Any failure → return to Phase 3 (or Phase 2 if the root cause was wrong). Never quietly fall back to a simpler approach on error — stop, surface the problem, propose how to resolve it.

### Phase 5 — Report & Handoff
Root cause · change summary per repo · verification evidence (the checklist with actual results) · residual risks/follow-ups. Draft a commit message per repo (why over what). **Offer** — never auto-do — ticket comments and PRs; wait for confirmation before any outward-facing action.

## Conditional-phase rules
- Build-time or pure-frontend issue → skip the telemetry step.
- Trivial mechanical change → trim Phase 1 to a sanity check.
- Single-repo task → skip counterpart cross-reads/edits, but still confirm the seam is truly untouched.
- Phase 4 always runs.

## Examples
```
/surgical stale prices served after cache invalidation on plan change
/surgical #4711
/surgical the client gets a 500 opening order details since the last deploy
```
