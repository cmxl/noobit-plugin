# Stop hook: when uncommitted source changes exist, remind Claude ONCE per change-set
# to run the quality gates (build, tests, stack-reviewer, docs-sync) before finishing.
# Never loops: skips when stop_hook_active, and remembers the change-set it already flagged
# (including the state AFTER remediation work, so satisfied gates don't re-nag next turn).
$ErrorActionPreference = 'SilentlyContinue'
try {
    # stdin must be read as UTF-8 — [Console]::In uses the OEM codepage and garbles non-ASCII
    $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8).ReadToEnd()
    $data = $raw | ConvertFrom-Json

    & git rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 0 }

    # pathspec filtering instead of a regex: git quotes paths with spaces/non-ASCII
    # ("?? \"My File.cs\""), which an $-anchored extension regex silently misses
    $changes = @(& git status --porcelain -- '*.cs' '*.csproj' '*.razor' '*.ts' '*.js' '*.mjs' '*.html' '*.scss' '*.css' 2>$null) |
        Where-Object { $_ }
    if (-not $changes -or $changes.Count -eq 0) { exit 0 }

    $sessionId = if ($data.session_id) { $data.session_id } else { 'default' }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($changes -join "`n") + $sessionId)
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '')
    $tempDir = [IO.Path]::GetTempPath()   # cross-platform; $env:TEMP does not exist on Linux/macOS
    $stateFile = Join-Path $tempDir "claude-quality-gate-$sessionId.txt"

    # prune stale state files from old sessions
    Get-ChildItem -Path $tempDir -Filter 'claude-quality-gate-*.txt' 2>$null |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force 2>$null

    if ($data.stop_hook_active) {
        # this stop is the remediation turn triggered by our own block: record the
        # post-remediation change-set so the next stop doesn't re-nag for it
        Set-Content -Path $stateFile -Value $hash
        exit 0
    }
    if ((Test-Path $stateFile) -and ((Get-Content $stateFile -Raw).Trim() -eq $hash)) { exit 0 }
    Set-Content -Path $stateFile -Value $hash

    $fileList = ($changes | Select-Object -First 15) -join '; '
    $reason = "Quality-gate check (automatic): there are uncommitted source changes [$fileList]. " +
        "Before finishing, verify the CLAUDE.md gates for the changed code: (1) the solution builds, " +
        "(2) tests cover the changed behavior and pass (dispatch test-guardian if coverage is missing), " +
        "(3) the stack-reviewer agent has reviewed the diff and blockers are fixed, " +
        "(4) docs/ was updated if behavior, endpoints, config, or architecture changed. " +
        "If a gate was already satisfied this session, or the changes are trivial/non-behavioral, " +
        "briefly state which gates apply and why, then finish."
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
} catch {}
exit 0
