# Shared helpers for the noobit hook scripts (dot-sourced).

# Native-command output (git) is decoded with the console encoding - the OEM codepage on
# Windows, which garbles non-ASCII paths; the JSON written back to Claude must be UTF-8 too.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Read-HookInput {
    # stdin must be read as UTF-8 - [Console]::In uses the OEM codepage (ibm850) and
    # garbles non-ASCII paths, which then silently fail Test-Path
    $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8).ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-StateDir {
    # ${CLAUDE_PLUGIN_DATA} survives plugin updates; temp is the fallback for --plugin-dir runs
    $base = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { Join-Path ([IO.Path]::GetTempPath()) 'noobit-plugin' }
    $dir = Join-Path $base 'sessions'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-RepoRoot([string]$dir) {
    # The worktree root as seen through $dir. `rev-parse --show-toplevel` would resolve
    # junctions/symlinks/subst drives (and /var -> /private/var on macOS) and then no longer
    # prefix-match the unresolved paths Claude reports; --show-cdup keeps the caller's view.
    if (-not $dir -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $cdup = & git -C $dir rev-parse --show-cdup 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $root = if ($cdup) { Join-Path $dir $cdup } else { $dir }
    return [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
}

function Get-SessionKey($data) {
    # session ids are UUIDs; strip anything that isn't safe in a file name
    $id = if ($data -and $data.session_id) { [string]$data.session_id } else { 'default' }
    return ($id -replace '[^A-Za-z0-9_-]', '_')
}
