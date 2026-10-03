# SessionStart hook (startup only): at most once a day, compare the installed noobit
# version with the published one and tell Claude to mention an available update.
# Plugins from third-party marketplaces don't auto-update unless the marketplace has
# autoUpdate enabled - a stale install silently runs old skills.
# Fail-soft: offline, slow, or malformed responses are ignored, and a failed check still
# counts as today's check (no 4-second penalty on every offline startup).
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/common.ps1')

function ConvertTo-Version([string]$text) {
    # 1.11.0, 1.11.0-beta.1, 1.11.0+build -> [version] of the numeric core
    if ($text -match '^\s*v?(\d+)\.(\d+)(?:\.(\d+))?') {
        return [version]::new([int]$Matches[1], [int]$Matches[2], [int]($Matches[3] ?? 0))
    }
    return $null
}

try {
    $null = Read-HookInput
    $manifest = Join-Path $PSScriptRoot '../.claude-plugin/plugin.json'
    $installedText = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version
    $installed = ConvertTo-Version $installedText
    if (-not $installed) { exit 0 }

    $stamp = Join-Path (Get-StateDir) 'update-check.json'
    $cache = $null
    try { if (Test-Path -LiteralPath $stamp) { $cache = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json } } catch { $cache = $null }   # corrupt stamp = no stamp
    if ($cache -and ([datetime]$cache.checkedAt) -gt (Get-Date).AddHours(-24)) { exit 0 }
    @{ checkedAt = (Get-Date).ToString('o'); latest = $null } | ConvertTo-Json -Compress | Set-Content -LiteralPath $stamp

    # NOOBIT_UPDATE_URL exists for tests; the default is the published manifest
    $url = if ($env:NOOBIT_UPDATE_URL) { $env:NOOBIT_UPDATE_URL } else { 'https://raw.githubusercontent.com/cmxl/noobit-plugin/main/.claude-plugin/plugin.json' }
    $latestText = [string](Invoke-RestMethod -Uri $url -TimeoutSec 4).version
    # the value ends up in model context: accept plain semver only, never free text
    if ($latestText -notmatch '^\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]{1,32})?$') { exit 0 }
    $latest = ConvertTo-Version $latestText
    @{ checkedAt = (Get-Date).ToString('o'); latest = $latestText } | ConvertTo-Json -Compress | Set-Content -LiteralPath $stamp
    if (-not $latest -or $latest -le $installed) { exit 0 }

    $msg = "The noobit plugin is outdated (installed $installedText, published $latestText). " +
        'Mention this once to the user at a natural point, with the update commands: ' +
        '`claude plugin marketplace update noobit` then `claude plugin update noobit@noobit`, then /reload-plugins.'
    @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $msg } } |
        ConvertTo-Json -Compress -Depth 3
} catch {}
exit 0
