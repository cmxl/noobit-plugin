# Review remediation (v1.11.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve every finding from the 2026-10-03 four-reviewer audit (Fable full-repo + Opus infra/backend/other-skills) and close the daily-work gaps, then re-review with Opus 5.5 + Fable until no BLOCKER/MAJOR remains.

**Architecture:** Plugin repo — markdown skills/agents/commands, pwsh hooks, manifests. "Tests" here are: Pester tests for every hook script, a frontmatter/manifest lint script, `claude plugin validate --strict`, `claude plugin eval` cases for skill triggering/behavior, and live probes (`claude -p --plugin-dir`). Work splits into disjoint file sets so independent agents can run in parallel.

**Tech Stack:** Claude Code plugin format (CLI 2.1.288), PowerShell 7 + Pester 6 + PSScriptAnalyzer, Node 24 (lint script), GitHub Actions.

**Spec:** the consolidated review findings in this conversation, summarized per task below (each task lists the exact findings it owns).

## Global Constraints

- Verified facts (probed live on 2026-10-03 with a scratch plugin): `$0` = first argument, `$1` = second; agent `skills:` accepts `noobit:<name>` (plugin-qualified) and bare names; Stop hooks support only `decision: "block"` + `reason` (no `additionalContext`); hooks support exec form (`command` + `args`), per-handler `if` (tool events only), `${CLAUDE_PLUGIN_DATA}`; plugin agents ignore `permissionMode`, `hooks`, `mcpServers`.
- Never commit the Azure DevOps org name (public repo) — use the `-AdoOrg` parameter.
- `setup/AGENT-SETUP.md` and `setup/setup-machine.ps1` change together.
- Skill descriptions: ≤ 500 chars, specific triggers, explicit negative scope where overlap exists.
- Code samples in skills must compile against the versions the skill states; every new API claim verified against official docs (microsoftdocs MCP / WebFetch) — no guessing.
- English; match the surrounding doc tone; no drive-by rewrites outside a task's findings.
- Version bump to 1.11.0 in `.claude-plugin/plugin.json` (single place).

## Review Focus

1. Hooks on a machine without dotnet / npx / git, or in a non-git dir → must exit 0 silently and fast.
2. Stop hook in a repo with pre-existing uncommitted work that this session never touched → must not block.
3. Format hook in a legacy repo without `.editorconfig` → must not rewrite the `.cs` file.
4. A skill rename/removal leaving a dangling `noobit:<name>` reference anywhere → lint must fail.
5. Command frontmatter that strict YAML rejects → lint must fail.

---

### Task 1: Repo lint + hook test harness (foundation, owner: main session)

**Files:** Create `tools/lint-plugin.mjs`, `tools/package.json`, `tests/hooks/*.Tests.ps1`, `.github/workflows/validate.yml`.

- [ ] `tools/lint-plugin.mjs` (dep: `yaml`): parse frontmatter of every `skills/*/SKILL.md`, `agents/*.md`, `commands/*.md` with strict YAML; fail on parse errors, missing `name`/`description` (skills/agents), description > 500 chars (skills), duplicate names across commands and skills, any `noobit:<x>` reference in any `.md` where `<x>` is not an existing skill/agent/command, any agent `skills:` entry that doesn't resolve, and positional `$1..$9` in commands.
- [ ] Run it against the current tree → expect failures (adr/rfc collision, unquoted argument-hint, `$1`, discord description length). This is the "failing test".
- [ ] Pester tests for hooks (Task 2 makes them pass).
- [ ] GitHub Actions: `npm ci --prefix tools && node tools/lint-plugin.mjs`, `npx @anthropic-ai/claude-code plugin validate --strict .`, `Invoke-Pester tests/hooks`, `Invoke-ScriptAnalyzer hooks -Severity Warning,Error` (fail on findings).

### Task 2: Hooks (owner: main session)

Findings: Stop hook keyed on porcelain lines (re-nags on `git add`/new session, never re-nags after further edits, nags on pre-existing work and in foreign repos); format hook rewrites `.cs` without `.editorconfig`, mixed EOL, ~1 s wasted npx probe without prettier, 60 s timeout, no DOTNET env vars, shell form via Git Bash, pwsh started for every file type; `.razor` asymmetry; missing banned-package guard; commit gate; no update/prereq signal.

- [ ] `hooks.json`: exec form (`pwsh -NoProfile -NonInteractive -File …`), per-extension `if` filters on PostToolUse so pwsh only starts for formattable/trackable files, timeouts 20 s / 30 s.
- [ ] `format-file.ps1`: record touched source path to `${CLAUDE_PLUGIN_DATA}/sessions/<session_id>.touched` (fallback temp dir); `.cs` only formatted when an `.editorconfig` exists between file dir and git root; DOTNET_* env vars; prettier only when `node_modules/.bin/prettier(.cmd)` resolvable upward; comment `tool_response.filePath`.
- [ ] `stop-quality-gate.ps1`: `Set-Location $data.cwd`; consider only files this session touched (touched list ∩ changed in git); hash = path + content hash (no status codes, no session id); skip when nothing touched/changed; message names only those files; keep `stop_hook_active` loop guard.
- [ ] New `guard-packages.ps1` (PreToolUse, `if: Bash(dotnet add *)`): deny `Moq`, `MediatR`, `Newtonsoft.Json` with the sanctioned alternative.
- [ ] New `session-start.ps1` (SessionStart `startup`): at most once per 24 h, compare installed noobit version (`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`) with the remote `main` plugin.json (5 s timeout, fail-soft) and inject an update hint; cache result in plugin data.
- [ ] Commit gate: decided against a hard PreToolUse deny on `git commit` (the model can forge a marker, and it would block commits in non-stack repos); `/noobit:ship` + the touched-files Stop gate cover it. Recorded in README.
- [ ] Pester: each Review Focus item 1–3 + guard + gate behaviors; PSScriptAnalyzer clean.

### Task 3: Commands, agents, manifests (owner: main session)

Findings: adr/rfc command↔skill collision; `$1`; unquoted argument-hint; `disable-model-invocation` for new-fullstack/deploy-setup/surgical; new-fullstack commits before verify/review, needs `.gitattributes` + EOL editorconfig, "Angular latest LTS"; tech-lead PROACTIVELY too broad; agents lack `skills:`/`model`/`effort`, bare `/stack-review` names, no microsoftdocs tools, test-guardian runs whole suite; stack-review "findings table" wording; stack-reviewer `.dockerignore` patterns; plugin.json license/repository/keywords; missing `/noobit:ship` and `/noobit:ef-migration`.

- [ ] Rename `commands/adr.md`→`commands/new-adr.md`, `commands/rfc.md`→`commands/new-rfc.md`; update every reference.
- [ ] `$1`→`$ARGUMENTS`; quote all `argument-hint`s; `disable-model-invocation: true` on new-fullstack and deploy-setup. (Decided during execution: surgical stays model-invocable — it has a human approval gate and CLAUDE.md routes non-trivial fixes to it.)
- [ ] new-fullstack: verify → stack-reviewer → fix → commit; `.gitattributes` + `.editorconfig` EOL/charset; "Angular latest stable major".
- [ ] Agents: `skills:` preload, `model`/`effort`, `/noobit:` names, `mcp__microsoftdocs__*` tools, tech-lead trigger = explicit requests only + suggest otherwise, test-guardian scoped baseline, reviewer `.dockerignore` `**/` patterns.
- [ ] New `commands/ship.md` (build → tests → test-coverage → stack-review → docs-sync → drafted commit; commit/PR only on explicit go) and `commands/ef-migration.md` (add → idempotent script → destructive-op review → integration tests).
- [ ] plugin.json: version 1.11.0, license, repository, keywords.

### Task 4: Docs/setup (owner: main session, after 1–3, 5–8)

Findings: README counts/contents, Updating section, evals docs, hook behavior; CLAUDE.md.example (tech-lead/ADR/RFC, ship, commit conventions, formatter "modified since read", Angular latest stable, Angular tests row); setup script never updates, azure-agent-skills at user scope, autoUpdate, prereqs pwsh/.NET, stale snapshot date, ado bullet on re-run; work/ spec status line.

- [ ] README regenerated from the tree; CLAUDE.md.example; AGENT-SETUP.md + setup-machine.ps1 together; `work/specs/2026-07-12-…` status → implemented.

### Task 5: Backend skills (owner: subagent B)

Owns `skills/{aspnet-backend,data-access,mssql,postgres,sqlite,fusioncache-redis,rabbitmq-messaging,dotnet-testing,bff-security}/**`. All backend findings: https test client (BLOCKER); redirect contradiction; fallback authorization policy; canonical DbContext registration; UUIDv7 per provider; external OAuth login reference; output caching vs XSRF mint; inbox unique-constraint + DDL; Npgsql health check via data source; UseExceptionHandler placement; MapStaticAssets comment; rate-limit key prefix + health exemption; FusionCache projection + name drift; aspnet description triggers; xUnit naming; all NITs; Fable reference nits (EOL date, IMemoryPoolFactory, Respawn 7 adapters, FusionCache changelog collapse + unverified claims, mssql memory-grant qualifier, RabbitMQ 4.3/4.4 clause, Serilog OTel sink claim, seam sample dedupe); gaps as new references: authorization (policies, resource-based, tenant filters), observability (OTel + Serilog), background/scheduled jobs across replicas, configuration & secrets, migrations in CI, outbox dispatcher + inbox DDL.

### Task 6: Infra/frontend/decision skills (owner: subagent C)

Owns `skills/{docker,nginx-deploy,angular-ngrx-state,docs-maintenance,adr,rfc,simple-scripts}/**`. `.dockerignore` `**/`; edge/backend networks + KnownNetwork; cross-arch wording; KnownNetwork crash-safe; compose hardening + secrets in skeleton; NgRx default sentence; "scheduled for removal in v23"; signal-store imports; pnpm variant; nginx `app-ssl.conf` staging, TLSRef attribution, proxy_read_timeout consistency, certbot profile consistency; Mermaid Node floor; adr Nygard/MADR wording; `/noobit:` names; adr/rfc index regeneration via shipped `scripts/regen-index.ps1` + Pester test; shorten rfc/ngrx descriptions; volume backup/restore section; reference new command names `new-adr`/`new-rfc`.

### Task 7: Discord (owner: subagent D)

Owns `skills/discord/**`. Trim references to ≈2,000 lines with zero rule loss (dedupe repeated rules, drop demo suites/showcase/sharded service/opcode internals/verification log), version-less csproj under CPM, options validation via `[OptionsValidator]` or declared deviation, description ≤ 500 chars, mark unverified claims; convert evals to `evals/discord-*/` `claude plugin eval` cases.

### Task 8: PayPal + evals + new skills (owner: subagent E)

Owns `skills/paypal/**`, new `skills/frontend-testing/**`, new `skills/ci-pipelines/**`, `evals/**` (except discord-*). PayPal: environment in PKs or stated, docs-map stale line, webhooks/orders duplication, rate-limiter ordering vs bff-security, description ≤ 500; PayPal eval cases; trigger evals (one per core skill); new `frontend-testing` (Vitest + Playwright via cookie BFF, storageState, XSRF, compose e2e, zoneless TestBed); new `ci-pipelines` (Azure DevOps YAML: build/test with Testcontainers on hosted agents, BuildKit registry cache, EF bundle/idempotent script + pending-changes gate, deploy to compose host) — no org names.

### Task 9: Verify + review loop (owner: main session)

- [ ] Lint, Pester, PSScriptAnalyzer, `claude plugin validate --strict .`, `claude plugin eval` (sample), live probes for commands/agents.
- [ ] Re-review: Fable + Opus 5.5 in parallel on the full branch; fix every BLOCKER/MAJOR (and cheap MINORs); repeat until both report no BLOCKER/MAJOR.
- [ ] stack-reviewer pass on the diff, commit, update the installed plugin from this checkout.
