# PostToolUse hook: auto-format the file Claude just wrote/edited.
# Fail-soft by design: never blocks the session, always exits 0.
$ErrorActionPreference = 'SilentlyContinue'
try {
    # read stdin explicitly as UTF-8 — [Console]::In uses the OEM codepage (ibm850) and
    # garbles non-ASCII paths, which then silently fail Test-Path
    $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8).ReadToEnd()
    $data = $raw | ConvertFrom-Json
    $f = $data.tool_input.file_path
    if (-not $f) { $f = $data.tool_response.filePath }
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { exit 0 }

    $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
    switch ($ext) {
        '.cs' {
            # whitespace-only formatting works without an MSBuild workspace and is fast
            $dir = [IO.Path]::GetDirectoryName($f)
            $name = [IO.Path]::GetFileName($f)
            # never call dotnet format with empty args: an empty workspace/--include would
            # make it format the ENTIRE current directory tree
            if ([string]::IsNullOrWhiteSpace($dir) -or [string]::IsNullOrWhiteSpace($name)) { exit 0 }
            & dotnet format whitespace $dir --folder --include $name 2>$null | Out-Null
        }
        { $_ -in '.ts', '.html', '.scss', '.css', '.js', '.mjs' } {
            # run from the file's directory: npx resolves node_modules upward from CWD,
            # and the project's package.json (e.g. web/) is rarely at the session root
            Push-Location ([IO.Path]::GetDirectoryName($f))
            try { & npx --no-install prettier --write $f 2>$null | Out-Null }
            finally { Pop-Location }
        }
    }
} catch {}
exit 0
