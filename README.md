# noobit — Claude Code plugin

Opinionated full-stack standards for **.NET 10+ / ASP.NET Core + Angular (latest stable major)** development, with automation that keeps quality high and manual intervention low.

## What's inside

| Component | Contents |
|---|---|
| **20 skills** | **Backend:** `aspnet-backend` (minimal APIs, DI, options, resilience, observability, background jobs, configuration/secrets), `data-access` (EF Core/Dapper, migrations in CI), `mssql` / `postgres` / `sqlite` (per-provider tuning, index design, query-rewrite equivalence checks), `fusioncache-redis`, `rabbitmq-messaging` (outbox/inbox), `bff-security` (cookie BFF, external login, authorization). **Frontend:** `angular-ngrx-state` (NgRx SignalStore), `frontend-testing` (Vitest + Playwright through the cookie BFF). **Testing/delivery:** `dotnet-testing` (xUnit v3 + Testcontainers), `docker` (cached multi-stage builds, hardened compose, backups), `nginx-deploy` (reverse proxy, TLS, Let's Encrypt), `ci-pipelines` (Azure DevOps YAML). **Docs & decisions:** `docs-maintenance` (docs-as-code, Mermaid), `adr` / `rfc` (decision records and design docs with generated indexes). **Integrations:** `paypal` (JS SDK v6, Orders v2, verified webhooks, inbox table), `discord` (Discord.Net gateway bots and HTTP interactions). **Scripts:** `simple-scripts` (ad-hoc pwsh/bash/az CLI stays one command per line). Versions in `references/` were verified in October 2026. |
| **4 agents** | `stack-reviewer` (stack-tuned review, read-only by instruction), `test-guardian` (finds and writes missing tests), `docs-maintainer` (keeps `docs/` in sync, runs on Sonnet), `tech-lead` (writes ADRs/RFCs on request) — test-guardian, docs-maintainer and tech-lead preload the skills they work from; stack-reviewer loads the ones the diff needs |
| **10 commands** | `/noobit:ship` (all quality gates → drafted commit), `/noobit:surgical` (gated bugfix/change workflow), `/noobit:stack-review`, `/noobit:test-coverage`, `/noobit:docs-sync`, `/noobit:ef-migration`, `/noobit:new-adr`, `/noobit:new-rfc`, `/noobit:new-fullstack`¹, `/noobit:deploy-setup`¹ |
| **4 hooks** | Auto-format edited files (`dotnet format` only in repos with an `.editorconfig`; project-local Prettier); quality-gate reminder on stop for files *this session* changed; block adding Moq / MediatR / Newtonsoft.Json (unless the repo already uses them); once-a-day check for a newer plugin version |

¹ Only you can start these (`disable-model-invocation`) — they scaffold a solution (including its first commit) or write deployment assets. `/noobit:surgical` stays model-invocable on purpose: it stops at a human approval gate before changing code, and `CLAUDE.md` tells Claude to use it.

Any skill can also be run directly as `/noobit:<skill>`.

## Requirements

- **PowerShell 7+** (`pwsh` on PATH) — the hook scripts are cross-platform PowerShell
- **.NET SDK 10+** (`dotnet` on PATH) — used by the format hook and everything else
- Node.js with project-local Prettier — the web format hook is a silent no-op without it
- Docker — for Testcontainers-based integration tests and deployments
- **External skills (recommended, not shipped here):** the official Angular Team skills `angular-developer` and `angular-new-app` (installed by [`setup/setup-machine.ps1`](setup/setup-machine.ps1)) plus the `superpowers` plugin (process skills: brainstorming, TDD, debugging). Everything backend-side works without them.

## Install

```
claude plugin marketplace add cmxl/noobit-plugin
claude plugin install noobit@noobit
```

(Or from a local checkout: `claude plugin marketplace add <path-to-this-repo>`.) To set up a whole machine — plugins, skills, MCP servers, global `CLAUDE.md` — run [`setup/setup-machine.ps1`](setup/setup-machine.ps1); see [`setup/AGENT-SETUP.md`](setup/AGENT-SETUP.md).

## Updating

Plugins from third-party marketplaces don't update on their own. Either update manually:

```
claude plugin marketplace update noobit
claude plugin update noobit@noobit
```

then `/reload-plugins` in a running session — or enable auto-update for the marketplace in `/plugin` → Marketplaces. The plugin's startup hook checks once a day and tells you when a newer version is published.

## After installing

1. Copy [`CLAUDE.md.example`](CLAUDE.md.example) into your `~/.claude/CLAUDE.md` (or your team repo's `CLAUDE.md`) — the always-on quality gates live there, since plugins can't inject global instructions.
2. If you previously copied these skills/agents/commands/hooks into `~/.claude/` manually, remove those copies — otherwise everything is loaded twice.
3. Optional but recommended: the skills and agents reference official framework docs (learn.microsoft.com, angular.dev, ngrx.io, rabbitmq.com, developer.paypal.com, docs.discord.com, …) and are instructed to fetch them instead of guessing. Plugins cannot ship permission rules, so add `WebSearch` and `WebFetch(domain:...)` allow rules for those doc domains to your `~/.claude/settings.json` to avoid permission prompts.
4. Keep the skill listing lean: Claude Code caps the combined skill descriptions it shows the model, and large skill packs (e.g. ~200 Azure skills) push other descriptions out. Install big packs per project, not at user scope.

## How the quality gates fit together

- `CLAUDE.md` states the gates (tests, review before commit, docs in sync).
- `/noobit:ship` runs them in order: build → tests → `test-guardian` → `stack-reviewer` → `docs-maintainer` → drafted Conventional Commit. It never commits without your go.
- The Stop hook is the safety net: when the session changed source files and they're still uncommitted, it asks Claude once per change-set to confirm the gates. It ignores work the session didn't touch, staging, and repos without a .NET or Angular project. It only sees files written with Write/Edit (`.cs`, `.csproj`, `.props`, `.razor`, `.cshtml`, `.ts`, `.html`, `.scss`, `.css`, `.js`, `.mjs`) in the session's working repo — changes made by shell commands (`dotnet ef migrations add`, `ng generate`, `sed`) or to config files are not tracked, nor are edits inside a submodule; `/noobit:ship` covers those. A session resumed after more than seven days starts with an empty touched list. The package guard has the same reach: its `Write`/`Edit` filters are anchored at the session's working folder, so project files in an `/add-dir` folder or a sibling repo aren't checked (`dotnet add package` commands are, wherever they run).
- There is deliberately no hard `git commit` block: a marker file the model could write itself is no real gate, and it would get in the way in repos outside this stack.

## Development

```
npm ci --prefix tools && node tools/lint-plugin.mjs        # frontmatter, names, references
claude plugin validate --strict . && claude plugin validate --strict .claude-plugin/plugin.json   # marketplace, then plugin
pwsh -c "Invoke-Pester tests"                             # hook + script tests (Pester 5.5+)
pwsh -c '"hooks","skills","tests" | % { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 }'
claude plugin eval                                        # skill trigger/behavior evals in evals/
```

CI runs all of these except the evals (they call the model) on every push and PR. Trigger and PayPal evals run anywhere; the Discord build cases (tag `build`) grant a shell, which `claude plugin eval` only allows inside an OS sandbox — run them on Linux/macOS: `claude plugin eval . --tag build --scaffold --allow-tools Bash Write Edit`. `work/` holds specs and plans for changes to this repo.

## Conventions encoded

- .NET solutions always use `global.json`, `Directory.Build.props`, `Directory.Packages.props` (central package management), and `Directory.Build.rsp` (`-maxcpucount -nologo -graph`).
- Cookie BFF security: tokens never reach the browser; `__Host-session` + XSRF cookie; explicit antiforgery validation on JSON endpoints; authenticated-by-default fallback policy.
- Every feature ships with tests (xUnit v3 + Testcontainers / Vitest + Playwright); reviews run before commits; `docs/` is updated in the same change.

## License

[MIT](LICENSE)
