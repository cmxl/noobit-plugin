#Requires -Version 7.0
# Replicates the Claude Code setup (plugins, skills, MCP servers, global CLAUDE.md)
# on a new machine. Safe to re-run: already-installed items produce "already exists"
# errors that can be ignored. Requires PowerShell 7+, Node.js, git, and a logged-in
# Claude Code CLI. Run from a clone of this repo (step 5 needs ../CLAUDE.md.example).
# See AGENT-SETUP.md for the full inventory.

param(
    # Azure DevOps organization for the 'ado' MCP server.
    # Omit to skip registering that server (everything else still installs).
    [string]$AdoOrg
)

$ErrorActionPreference = 'Continue'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

foreach ($tool in 'claude', 'git', 'node', 'npx') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Prerequisite missing: '$tool' not found on PATH. See AGENT-SETUP.md."
    }
}

# --- 1. Plugin marketplaces -------------------------------------------------

Step 'Adding plugin marketplaces'
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add cmxl/noobit-plugin

$msSkills = Join-Path $HOME '.claude/local-marketplaces/Agent-Skills'
if (-not (Test-Path $msSkills)) {
    git clone --depth 1 https://github.com/MicrosoftDocs/Agent-Skills.git $msSkills
} else {
    git -C $msSkills pull --ff-only
}
claude plugin marketplace add $msSkills

# --- 2. Plugins (user scope) ------------------------------------------------

Step 'Installing Claude Code plugins'
$plugins = @(
    'noobit@noobit'
    'superpowers@claude-plugins-official'
    'frontend-design@claude-plugins-official'
    'code-review@claude-plugins-official'
    'code-simplifier@claude-plugins-official'
    'skill-creator@claude-plugins-official'
    'github@claude-plugins-official'
    'azure@claude-plugins-official'
    'claude-md-management@claude-plugins-official'
    'azure-agent-skills@microsoft-agent-skills'
)
foreach ($p in $plugins) { claude plugin install $p }

# Project-scoped, not installed here: nx@nx-claude-plugins (used in noobit.dev).
# Inside that project run:
#   claude plugin marketplace add nrwl/nx-ai-agents-config
#   claude plugin install nx@nx-claude-plugins

# --- 3. Global agent skills (skills.sh CLI) ----------------------------------

Step 'Installing global agent skills (npx skills)'
$skills = @(
    'angular/skills@angular-developer'
    'angular/skills@angular-new-app'
    'analogjs/angular-skills@angular-component'
    'analogjs/angular-skills@angular-di'
    'analogjs/angular-skills@angular-directives'
    'analogjs/angular-skills@angular-forms'
    'analogjs/angular-skills@angular-http'
    'analogjs/angular-skills@angular-routing'
    'analogjs/angular-skills@angular-signals'
    'analogjs/angular-skills@angular-ssr'
    'analogjs/angular-skills@angular-testing'
    'analogjs/angular-skills@angular-tooling'
    'samber/cc-skills-golang@golang-code-style'
    'samber/cc-skills-golang@golang-concurrency'
    'samber/cc-skills-golang@golang-context'
    'samber/cc-skills-golang@golang-error-handling'
    'samber/cc-skills-golang@golang-naming'
    'samber/cc-skills-golang@golang-performance'
    'samber/cc-skills-golang@golang-project-layout'
    'samber/cc-skills-golang@golang-security'
    'samber/cc-skills-golang@golang-structs-interfaces'
    'samber/cc-skills-golang@golang-testing'
    'currents-dev/playwright-best-practices-skill@playwright-best-practices'
    'microsoft/playwright-cli@playwright-cli'
    'antfu/skills@vitest'
    'vercel-labs/skills@find-skills'
)
foreach ($s in $skills) { npx -y skills add $s -g -y -a claude-code }

# microsoft/playwright-cli also ships a repo-internal 'dev' skill; drop it if pulled in.
if (Test-Path (Join-Path $HOME '.agents/skills/dev')) { npx -y skills remove dev -g -y -a claude-code }

# --- 4. MCP servers (user scope) ----------------------------------------------

Step 'Registering MCP servers'
claude mcp add --transport http --scope user microsoftdocs https://learn.microsoft.com/api/mcp
if ($AdoOrg) {
    if ($IsWindows) {
        claude mcp add --scope user ado -- cmd /c npx -y '@azure-devops/mcp' $AdoOrg --authentication azcli
    } else {
        claude mcp add --scope user ado -- npx -y '@azure-devops/mcp' $AdoOrg --authentication azcli
    }
    Write-Host 'Note: the ado MCP server needs Azure CLI authentication — run: az login'
} else {
    Write-Host "Skipped the 'ado' MCP server — re-run with -AdoOrg <organization> to register it."
    Write-Host "(A later -AdoOrg re-run won't touch an existing ~/.claude/CLAUDE.md — add its ado bullet manually.)"
}

# --- 5. Global CLAUDE.md -------------------------------------------------------

Step 'Global CLAUDE.md'
$globalClaudeMd = Join-Path $HOME '.claude/CLAUDE.md'
$example = Join-Path $PSScriptRoot '../CLAUDE.md.example'
if (Test-Path $globalClaudeMd) {
    Write-Host "$globalClaudeMd already exists — left untouched"
} elseif (-not (Test-Path $example)) {
    Write-Error "CLAUDE.md.example not found at $example — run this script from a clone of the repo."
} else {
    Copy-Item $example $globalClaudeMd -ErrorAction Stop
    Add-Content $globalClaudeMd '- For Microsoft/Azure/.NET documentation, prefer the `microsoftdocs` MCP tools (Microsoft Learn search/fetch, returns clean Markdown) over WebFetch against learn.microsoft.com.'
    if ($AdoOrg) {
        Add-Content $globalClaudeMd ('- For Azure DevOps work (work items, PRs, pipelines, repos in the ' + $AdoOrg + ' org), use the `ado` MCP server''s tools; it authenticates via Azure CLI (`az login`).')
    }
    Write-Host "Created $globalClaudeMd from CLAUDE.md.example"
}

Step 'Done. Verify with: claude plugin list; npx skills ls -g; claude mcp list'
