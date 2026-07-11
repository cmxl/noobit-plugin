# noobit — Claude Code plugin

Opinionated full-stack standards for **.NET 10+ / ASP.NET Core + Angular (latest LTS)** development, with automation that keeps quality high and manual intervention low.

## What's inside

| Component | Contents |
|---|---|
| **11 skills** | `aspnet-backend`, `fusioncache-redis`, `data-access` (EF Core/Dapper), `mssql` / `postgres` / `sqlite` (per-provider tuning, index design, query-rewrite equivalence verification), `rabbitmq-messaging`, `bff-security` (cookie BFF, no OIDC), `docker-nginx-deploy`, `dotnet-testing` (xUnit v3 + Testcontainers), `docs-maintenance` (docs-as-code, Mermaid) — each with a July-2026-verified `references/best-practices.md` |
| **3 agents** | `stack-reviewer` (stack-tuned code review, read-only), `docs-maintainer` (keeps `docs/` in sync), `test-guardian` (finds and writes missing tests) |
| **5 commands** | `/noobit:new-fullstack`, `/noobit:stack-review`, `/noobit:docs-sync`, `/noobit:test-coverage`, `/noobit:deploy-setup` |
| **2 hooks** | Auto-format on write (`dotnet format` / Prettier); quality-gate reminder on stop (build + tests + review + docs before finishing) |

## Requirements

- **PowerShell 7+** (`pwsh` on PATH) — the hook scripts are cross-platform PowerShell
- **.NET SDK 10+** (`dotnet` on PATH) — used by the format hook and everything else
- Node.js with project-local Prettier — the web format hook is a silent no-op without it
- Docker — for Testcontainers-based integration tests and deployments
- **External skills (recommended, not shipped here):** the Angular skills `angular-developer`, `angular-new-app`, `angular-ngrx-state` (frontend guidance used by `/noobit:new-fullstack`) and the `superpowers` plugin (process skills: brainstorming, TDD, debugging). Everything backend-side works without them.

## Install

```
/plugin marketplace add cmxl/noobit-plugin
/plugin install noobit@noobit
```

(Or from a local checkout: `/plugin marketplace add <path-to-this-repo>`.)

## After installing

1. Copy [`CLAUDE.md.example`](CLAUDE.md.example) into your `~/.claude/CLAUDE.md` (or your team repo's `CLAUDE.md`) — the always-on quality gates live there, since plugins can't inject global instructions.
2. If you previously copied these skills/agents/commands/hooks into `~/.claude/` manually, remove those copies — otherwise everything is loaded twice.
3. Optional but recommended: the skills and agents reference official framework docs (learn.microsoft.com, angular.dev, ngrx.io, rabbitmq.com, …) and are instructed to WebFetch them instead of guessing. Plugins cannot ship permission rules, so add `WebSearch` and `WebFetch(domain:...)` allow rules for those doc domains to your `~/.claude/settings.json` to avoid permission prompts.

## License

[MIT](LICENSE)

## Conventions encoded

- .NET solutions always use `global.json`, `Directory.Build.props`, `Directory.Packages.props` (central package management), and `Directory.Build.rsp` (`-maxcpucount -nologo -graph`).
- Cookie BFF security: tokens never reach the browser; `__Host-session` + XSRF cookie; explicit antiforgery validation on JSON endpoints.
- Every feature ships with tests (xUnit v3 + Testcontainers / Vitest); reviews run automatically before commits; `docs/` is updated in the same change.
