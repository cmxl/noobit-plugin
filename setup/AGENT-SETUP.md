# Claude Code machine setup — full inventory

Snapshot of everything installed on the primary machine (2026-07-17).
To replicate on a new machine, clone this repo and run [`setup-machine.ps1`](setup-machine.ps1)
from the clone (PowerShell 7+ — enforced; the script reads `../CLAUDE.md.example`):

```powershell
pwsh setup/setup-machine.ps1 -AdoOrg <your-azure-devops-org>   # -AdoOrg optional
```

## 1. Claude Code plugin marketplaces

| Marketplace | Source | Notes |
|---|---|---|
| `claude-plugins-official` | github: `anthropics/claude-plugins-official` | Usually auto-installed by Claude Code |
| `noobit` | github: `cmxl/noobit-plugin` | Own stack plugin |
| `microsoft-agent-skills` | local clone of `MicrosoftDocs/Agent-Skills` at `~/.claude/local-marketplaces/Agent-Skills` | Azure per-service skills |
| `nx-claude-plugins` | github: `nrwl/nx-ai-agents-config` | Only needed for the `nx` plugin (project-scoped) |

## 2. Claude Code plugins (user scope)

| Plugin | Marketplace | What it provides |
|---|---|---|
| `noobit` | noobit | Own .NET/Angular/Docker/nginx stack skills, agents, commands |
| `superpowers` | claude-plugins-official | Process skills: brainstorming, TDD, systematic debugging, plans |
| `frontend-design` | claude-plugins-official | Visual design guidance |
| `code-review` | claude-plugins-official | `/code-review` command |
| `code-simplifier` | claude-plugins-official | Code simplification agent |
| `skill-creator` | claude-plugins-official | Skill authoring/eval tooling |
| `github` | claude-plugins-official | GitHub MCP tools |
| `azure` | claude-plugins-official | Azure MCP tools + skills |
| `claude-md-management` | claude-plugins-official | CLAUDE.md audit/improve |
| `azure-agent-skills` | microsoft-agent-skills | Per-service Azure skills (large set) |

Project-scoped (not installed globally):

| Plugin | Marketplace | Project |
|---|---|---|
| `nx` | nx-claude-plugins | `E:\Source\noobit.dev` — reinstall inside that project on machines that build it |

## 3. Global agent skills (skills.sh CLI, `~/.agents/skills`, symlinked into `~/.claude/skills`)

Managed with `npx skills` (check updates: `npx skills check`, update: `npx skills update`).

| Source repo | Skills |
|---|---|
| `angular/skills` (official Angular team) | `angular-developer`, `angular-new-app` |
| `analogjs/angular-skills` | `angular-component`, `angular-di`, `angular-directives`, `angular-forms`, `angular-http`, `angular-routing`, `angular-signals`, `angular-ssr`, `angular-testing`, `angular-tooling` |
| `samber/cc-skills-golang` | `golang-code-style`, `golang-concurrency`, `golang-context`, `golang-error-handling`, `golang-naming`, `golang-performance`, `golang-project-layout`, `golang-security`, `golang-structs-interfaces`, `golang-testing` — ~30 more available in the repo on demand |
| `currents-dev/playwright-best-practices-skill` | `playwright-best-practices` |
| `microsoft/playwright-cli` | `playwright-cli` |
| `antfu/skills` | `vitest` |
| `vercel-labs/skills` | `find-skills` |

## 4. MCP servers (user scope, `~/.claude.json`)

| Name | Transport | Config |
|---|---|---|
| `microsoftdocs` | http | `https://learn.microsoft.com/api/mcp` |
| `ado` | stdio | `npx -y @azure-devops/mcp <organization> --authentication azcli` (requires `az login`) — org passed via the script's `-AdoOrg` parameter; registration is skipped when omitted |

## 5. Global CLAUDE.md

`~/.claude/CLAUDE.md` = repo root `CLAUDE.md.example` plus a line preferring the
`microsoftdocs` MCP tools for MS docs, and — when `-AdoOrg` is given — a line
pointing Azure DevOps work at the `ado` MCP server. The setup script creates it
from the example if missing.

## Prerequisites on a new machine

- Claude Code CLI installed and logged in
- Node.js (for `npx skills` and the `ado` MCP server)
- git
- Azure CLI + `az login` (for the `ado` MCP server)
- Docker Desktop (Testcontainers, builds — per global conventions)
