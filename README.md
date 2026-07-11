# noobit — Claude Code plugin

Opinionated full-stack standards for **.NET 10+ / ASP.NET Core + Angular (latest LTS)** development, with automation that keeps quality high and manual intervention low.

## What's inside

| Component | Contents |
|---|---|
| **8 skills** | `aspnet-backend`, `fusioncache-redis`, `data-access` (EF Core/Dapper, MSSQL/Postgres/SQLite), `rabbitmq-messaging`, `bff-security` (cookie BFF, no OIDC), `docker-nginx-deploy`, `dotnet-testing` (xUnit v3 + Testcontainers), `docs-maintenance` (docs-as-code, Mermaid) |
| **3 agents** | `stack-reviewer` (stack-tuned code review, read-only), `docs-maintainer` (keeps `docs/` in sync), `test-guardian` (finds and writes missing tests) |
| **5 commands** | `/noobit:new-fullstack`, `/noobit:stack-review`, `/noobit:docs-sync`, `/noobit:test-coverage`, `/noobit:deploy-setup` |
| **2 hooks** | Auto-format on write (`dotnet format` / Prettier); quality-gate reminder on stop (build + tests + review + docs before finishing) |

## Requirements

- **PowerShell 7+** (`pwsh` on PATH) — the hook scripts are cross-platform PowerShell
- **.NET SDK 10+** (`dotnet` on PATH) — used by the format hook and everything else
- Node.js with project-local Prettier — the web format hook is a silent no-op without it
- Docker — for Testcontainers-based integration tests and deployments

## Install

```
/plugin marketplace add <github-org>/noobit-plugin
/plugin install noobit@noobit
```

(Or from a local checkout: `/plugin marketplace add <path-to-this-repo>`.)

## After installing

1. Copy [`CLAUDE.md.example`](CLAUDE.md.example) into your `~/.claude/CLAUDE.md` (or your team repo's `CLAUDE.md`) — the always-on quality gates live there, since plugins can't inject global instructions.
2. If you previously copied these skills/agents/commands/hooks into `~/.claude/` manually, remove those copies — otherwise everything is loaded twice.

## Conventions encoded

- .NET solutions always use `global.json`, `Directory.Build.props`, `Directory.Packages.props` (central package management), and `Directory.Build.rsp` (`-maxcpucount -nologo -graph`).
- Cookie BFF security: tokens never reach the browser; `__Host-session` + XSRF cookie; explicit antiforgery validation on JSON endpoints.
- Every feature ships with tests (xUnit v3 + Testcontainers / Vitest); reviews run automatically before commits; `docs/` is updated in the same change.
