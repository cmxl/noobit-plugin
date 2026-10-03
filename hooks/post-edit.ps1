# PostToolUse hook (Write/Edit on source files - hooks.json filters by extension):
#   1. records the path as touched by this session, so the Stop gate only ever looks at
#      changes this session made;
#   2. auto-formats the file - C# only in repos that opted in with an .editorconfig,
#      web files only when the project has Prettier installed.
# Fail-soft by design: never blocks the session, always exits 0.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/common.ps1')

function Find-Upward([string]$startDir, [string[]]$relativePaths, [string]$stopAt) {
    $dir = $startDir
    while ($dir) {
        foreach ($rel in $relativePaths) {
            $candidate = Join-Path $dir $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        if ($stopAt -and $dir.TrimEnd('\', '/') -ieq $stopAt.TrimEnd('\', '/')) { break }
        $dir = [IO.Path]::GetDirectoryName($dir)
    }
    return $null
}

try {
    $data = Read-HookInput
    if (-not $data) { exit 0 }
    $f = $data.tool_input.file_path
    if (-not $f) { $f = $data.tool_response.filePath }   # Write's tool_response carries the path as filePath
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { exit 0 }
    $f = [IO.Path]::GetFullPath($f)

    $touched = Join-Path (Get-StateDir) "$(Get-SessionKey $data).touched"
    $known = if (Test-Path -LiteralPath $touched) { @(Get-Content -LiteralPath $touched) } else { @() }
    if ($known -notcontains $f) {
        # parallel tool calls append concurrently: take an exclusive lock and retry on a sharing
        # violation instead of silently losing the entry. FileShare.None matters on Unix, where
        # anything weaker is a shared flock and concurrent appenders overwrite each other's lines.
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            try {
                $stream = [IO.FileStream]::new($touched, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($f + [Environment]::NewLine)
                    $stream.Write($bytes, 0, $bytes.Length)
                } finally { $stream.Dispose() }
                break
            } catch [IO.IOException] { Start-Sleep -Milliseconds (10 + 10 * $attempt) }
        }
    }

    $dir = [IO.Path]::GetDirectoryName($f)
    $name = [IO.Path]::GetFileName($f)
    if ([string]::IsNullOrWhiteSpace($dir) -or [string]::IsNullOrWhiteSpace($name)) { exit 0 }
    $repoRoot = Get-RepoRoot $dir

    switch ([IO.Path]::GetExtension($f).ToLowerInvariant()) {
        '.cs' {
            # without an .editorconfig, dotnet format applies its built-in defaults (CRLF on
            # Windows, its own spacing) and churns legacy files - only format opted-in repos
            # outside a repo, look only in the file's own folder - a ~/.editorconfig must not opt
            # every loose folder into formatting
            if (-not (Find-Upward $dir @('.editorconfig') ($repoRoot ?? $dir))) { exit 0 }
            if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { exit 0 }
            $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
            $env:DOTNET_NOLOGO = '1'
            $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
            # whitespace-only formatting works without an MSBuild workspace and is fast;
            # never pass empty args - an empty --include formats the whole directory tree
            & dotnet format whitespace $dir --folder --include $name 2>$null | Out-Null
        }
        { $_ -in '.ts', '.html', '.scss', '.css', '.js', '.mjs' } {
            # Resolve the project's own Prettier (probing via npx costs ~1 s when it's absent) and
            # run its JS entry point with node directly: the node_modules/.bin/prettier.cmd shim
            # would pass the file name through cmd.exe, where & | % ^ in a name inject commands.
            $prettier = Find-Upward $dir @('node_modules/prettier/bin/prettier.cjs', 'node_modules/prettier/bin-prettier.js') ($repoRoot ?? $dir)
            if (-not $prettier -or -not (Get-Command node -ErrorAction SilentlyContinue)) { exit 0 }
            # run from the package root (the folder holding that node_modules): Prettier reads
            # .prettierignore/.gitignore from its cwd, and the session cwd is often the repo root
            $pkgRoot = [IO.Path]::GetDirectoryName($prettier)
            while ($pkgRoot -and [IO.Path]::GetFileName($pkgRoot) -ne 'node_modules') { $pkgRoot = [IO.Path]::GetDirectoryName($pkgRoot) }
            if ($pkgRoot) { $pkgRoot = [IO.Path]::GetDirectoryName($pkgRoot) } else { $pkgRoot = $dir }
            Push-Location -LiteralPath $pkgRoot
            try { & node $prettier --write $f 2>$null | Out-Null }
            finally { Pop-Location }
        }
    }
} catch {}
exit 0
