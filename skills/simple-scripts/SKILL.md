---
name: simple-scripts
description: Use when writing an ad-hoc / one-off PowerShell (pwsh), bash, or Azure CLI (az) command — a quick script, changing a setting, a one-off command — especially az appconfig kv set, az webapp/functionapp config appsettings set, or az keyvault secret set. Not for scripts that ship with a project (Docker entrypoints, certbot hooks, backup jobs).
---

# Simple scripts: one command per line

Default for ad-hoc scripts: **the plain command, one line per change.** No function, no module,
no `param()` block, no hashtable + `foreach`, no `Write-Host` banners, no try/catch wrappers,
no confirmation prompts. The reader should be able to change one value by editing one line.

A failed line in a pasted block does not stop the lines after it — scan the output, or put one
stop-on-error line at the top: `set -e` (bash) or
`$ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true` (pwsh 7.4+;
without the second variable a failing `az` exit code does not stop pwsh).

## Azure App Configuration

One setting → one line:

```powershell
az appconfig kv set --name my-appconfig --key "Api:TimeoutSeconds" --value "30" --label Production --yes
```

`--auth-mode` defaults to `key`, which fetches access keys and fails on stores with local auth
disabled. Use your `az login` identity: add `--auth-mode login` per line, or set it once with
`az configure --defaults appconfig_auth_mode=login` (the examples below assume that default).

Several settings → the same call repeated, line by line:

```powershell
az appconfig kv set --name my-appconfig --key "Api:TimeoutSeconds" --value "30"   --label Production --yes
az appconfig kv set --name my-appconfig --key "Api:RetryCount"     --value "3"    --label Production --yes
az appconfig kv set --name my-appconfig --key "Features:NewUi"     --value "true" --label Production --yes
```

Aligning the columns with spaces is fine and helps scanning. Don't do this:

```powershell
# WRONG — over-engineered for a settings change
$settings = @{ "Api:TimeoutSeconds" = "30"; "Api:RetryCount" = "3" }
foreach ($kv in $settings.GetEnumerator()) { az appconfig kv set --name $store --key $kv.Key --value $kv.Value --yes }
```

Same rule for other "set a value" CLIs: `az keyvault secret set`, `az appconfig feature enable`, etc.

**Exception — App Service / Functions app settings:** every change restarts the app, so one line per
setting means one restart per line. Use **one** call with all pairs (`--settings` takes
space-separated `KEY=VALUE` pairs, or `"@settings.json"` — quote the `@` in pwsh):

```powershell
az webapp config appsettings set -g my-rg -n my-app --settings `
    Api__TimeoutSeconds=30 `
    Api__RetryCount=3
```

**Secrets:** never put a secret literal on the command line (shell history, process list, committed
script). Use `az keyvault secret set --file <path>` or a value from an env var/prompt; in App Settings,
prefer a Key Vault reference over the raw secret.

Bash looks the same; values with spaces or `'`/`"` follow normal shell quoting:

```bash
az appconfig kv set --name my-appconfig --key "Api:TimeoutSeconds" --value "30" --label Production --yes
```

Quoting trap (pwsh on Windows): `az` is a `.cmd` wrapper, so `&`, `|` or JSON inside a value can be
re-parsed — wrap such a value as `'"a&b"'`, and pass JSON via `@file` instead of inline.

## Allowed without asking

- A single variable at the top for a value repeated on every line (pwsh `$store = "my-appconfig"`,
  bash `store=my-appconfig` — no spaces around `=`) — only when it genuinely repeats; literal values are fine too.
- A short comment line above a group of commands.
- Line continuation (`` ` `` in pwsh, `\` in bash) when a single command gets unreadably long. The
  continuation character must be the very last one on the line — trailing whitespace silently breaks it.

## When to go bigger

Only write functions, loops, parameters, error handling, or a `.ps1` module when the user asks for it,
or the task truly needs logic (iterating over dynamic data from a query, conditional branching,
reuse across many runs/environments). Many App Configuration keys at once are not a loop either: put
them in a file and run one `az appconfig kv import --name <store> --source file --path settings.json --format json --separator : --label Production --yes`.
If unsure, give the simple version and offer the bigger one in one sentence.
