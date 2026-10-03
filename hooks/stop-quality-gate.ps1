# Stop hook: when THIS session changed source files (recorded by post-edit.ps1) and those
# changes are still uncommitted, remind Claude once per change-set to run the quality gates.
# - Pre-existing uncommitted work the session never touched never triggers it.
# - The change-set is identified by file content, so `git add` or a new turn with the same
#   content stays quiet, while further edits re-arm it.
# - Never loops: skips while stop_hook_active (and records the post-remediation state).
# - Only in .NET / Angular repos - the gates name stack-specific agents.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/common.ps1')

try {
    $data = Read-HookInput
    if (-not $data) { exit 0 }
    if ($data.cwd -and (Test-Path -LiteralPath $data.cwd)) { Set-Location -LiteralPath $data.cwd }

    $stateDir = Get-StateDir
    $key = Get-SessionKey $data
    $touchedFile = Join-Path $stateDir "$key.touched"
    $gateFile = Join-Path $stateDir "$key.gate"

    # prune state from sessions older than a week
    Get-ChildItem -LiteralPath $stateDir -File 2>$null |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force 2>$null

    if (-not (Test-Path -LiteralPath $touchedFile)) { exit 0 }
    $root = Get-RepoRoot (Get-Location).ProviderPath   # ProviderPath: UNC/WSL paths without the provider prefix
    if (-not $root) { exit 0 }

    $stack = @(& git -C $root ls-files --cached --others --exclude-standard -- '*.sln' '*.slnx' '*.csproj' 'angular.json' '**/angular.json' 2>$null)
    if ($stack.Count -eq 0) { exit 0 }

    $sep = [IO.Path]::DirectorySeparatorChar
    $inRepo = @(Get-Content -LiteralPath $touchedFile | Where-Object {
            $_ -and $_.StartsWith($root + $sep, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object -Unique)
    if ($inRepo.Count -eq 0) { exit 0 }

    # Which touched files still differ from HEAD (modified, added, untracked, or deleted)?
    # One unfiltered status, intersected in memory: passing the touched paths as pathspecs
    # breaks on the Windows command-line limit, on file_path casing that differs from disk,
    # and on glob characters in file names.
    $touched = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $inRepo) { [void]$touched.Add($p.Substring($root.Length + 1).Replace('\', '/')) }
    # -z: NUL-separated, paths unquoted; a rename/copy entry is followed by its source path
    $entries = ((& git -C $root status --porcelain=v1 -z --untracked-files=all 2>$null) -join '') -split "`0"
    $pending = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        if ($e.Length -lt 4) { continue }
        if ($touched.Contains($e.Substring(3))) { $pending.Add($e.Substring(3)) }   # git's casing
        if ($e[0] -in 'R', 'C' -or $e[1] -in 'R', 'C') { $i++ }
    }
    if ($pending.Count -eq 0) {
        Remove-Item -LiteralPath $gateFile -Force 2>$null   # all committed - the next change re-arms
        exit 0
    }
    $pending.Sort([StringComparer]::Ordinal)

    # identity = path + current content, never the status column (so staging doesn't re-nag);
    # one hash-object call for all existing files
    $existing = @($pending | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) })
    $blobs = @{}
    if ($existing.Count) {
        $hashes = @($existing | & git -C $root hash-object --stdin-paths 2>$null)
        for ($i = 0; $i -lt $existing.Count -and $i -lt $hashes.Count; $i++) { $blobs[$existing[$i]] = $hashes[$i] }
    }
    $identity = ($pending | ForEach-Object {
            $blob = if ($blobs.ContainsKey($_)) { $blobs[$_] } else { 'deleted' }
            "$_`t$blob"
        }) -join "`n"
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-', '')

    if ($data.stop_hook_active) {
        # the remediation turn our own block triggered: remember its result so the next
        # stop doesn't re-nag for the same content
        Set-Content -LiteralPath $gateFile -Value $hash
        exit 0
    }
    if ((Test-Path -LiteralPath $gateFile) -and ((Get-Content -LiteralPath $gateFile -Raw).Trim() -eq $hash)) { exit 0 }
    Set-Content -LiteralPath $gateFile -Value $hash

    $fileList = ($pending | Select-Object -First 15) -join ', '
    if ($pending.Count -gt 15) { $fileList += ", ... (+$($pending.Count - 15) more)" }
    $reason = "Quality-gate check (automatic): this session changed source files that are not committed yet [$fileList]. " +
        'Before finishing, verify the CLAUDE.md gates for those changes: (1) the solution builds, ' +
        '(2) tests cover the changed behavior and pass (test-guardian if coverage is missing), ' +
        '(3) the stack-reviewer agent reviewed the diff and BLOCKER/MAJOR findings are fixed, ' +
        '(4) docs/ is updated if behavior, endpoints, config, or architecture changed (/noobit:ship runs all of these). ' +
        'If a gate was already satisfied this session, or the changes are trivial/non-behavioral, ' +
        'state briefly which gates apply and why, then finish.'
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
} catch {}
exit 0
