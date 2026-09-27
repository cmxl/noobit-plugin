---
name: simple-scripts
description: Use when writing a PowerShell/pwsh, bash, or Azure CLI (az) snippet or script — especially az appconfig kv set / az webapp config / az keyvault secret set calls for changing settings. Keeps ad-hoc scripts as plain one-liners instead of functions, modules, parameter blocks, or loops.
---

# Simple scripts: one command per line

Default for ad-hoc scripts: **the plain command, one line per change.** No function, no module,
no `param()` block, no hashtable + `foreach`, no `Write-Host` banners, no try/catch wrappers,
no confirmation prompts. The reader should be able to change one value by editing one line.

## Azure App Configuration

One setting → one line:

```powershell
az appconfig kv set --name my-appconfig --key "Api:TimeoutSeconds" --value "30" --label Production --yes
```

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

Same rule for other "set a value" CLIs: `az webapp config appsettings set`, `az keyvault secret set`,
`az functionapp config appsettings set`, `az appconfig feature enable`, etc.

## Allowed without asking

- A single variable at the top for a value repeated on every line (e.g. `$store = "my-appconfig"`) —
  only when it genuinely repeats; literal values are fine too.
- A short comment line above a group of commands.
- Line continuation (`` ` `` in pwsh, `\` in bash) when a single command gets unreadably long.

## When to go bigger

Only write functions, loops, parameters, error handling, or a `.ps1` module when the user asks for it,
or the task truly needs logic (iterating over dynamic data from a query, conditional branching,
reuse across many runs/environments). If unsure, give the simple version and offer the bigger one
in one sentence.
