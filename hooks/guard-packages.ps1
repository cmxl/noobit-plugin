# PreToolUse hook: denies adding a banned NuGet package and names the sanctioned
# alternative. Covers shell commands (Bash/PowerShell `dotnet add ... package` /
# `dotnet package add`) and PackageReference/PackageVersion entries written straight into
# *.csproj / *.props / *.targets (Write/Edit). hooks.json filters which calls reach it.
# A package the repo already references is allowed - in an existing codebase, local
# conventions win. Fail-soft: any error lets the call through.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib/common.ps1')

$banned = [ordered]@{
    'Moq'                                     = 'NSubstitute is the standard mocking library (noobit:dotnet-testing).'
    'MediatR'                                 = 'Use plain handlers/services; if a mediator is genuinely warranted, martinothamar/Mediator (package "Mediator.SourceGenerator") - see noobit:aspnet-backend.'
    'Newtonsoft.Json'                         = 'System.Text.Json with a source-generated JsonSerializerContext is the standard (noobit:aspnet-backend).'
    'Microsoft.AspNetCore.Mvc.NewtonsoftJson' = 'ASP.NET Core uses System.Text.Json with a source-generated JsonSerializerContext (noobit:aspnet-backend).'
}

function Test-AlreadyReferenced([string]$pkg) {
    # exact id match in the repo's project files (Moq.AutoMock does not count as Moq)
    $root = Get-RepoRoot (Get-Location).ProviderPath   # ProviderPath: UNC/WSL paths without the provider prefix
    if (-not $root) { return $false }
    $files = @(& git -C $root ls-files -co --exclude-standard -- '*.csproj' '*.props' '*.targets' 2>$null)
    $pattern = '(?i)Include\s*=\s*["''](?:[^"'';]*;)*\s*' + [regex]::Escape($pkg) + '\s*[;"'']'
    foreach ($rel in $files) {
        if (Select-String -LiteralPath (Join-Path $root $rel) -Pattern $pattern -Quiet) { return $true }
    }
    return $false
}

function Write-Deny([string]$pkg) {
    @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = "noobit: '$pkg' is banned in this stack. $($banned[$pkg]) If the user explicitly wants it anyway, ask them to add it themselves."
        }
    } | ConvertTo-Json -Compress -Depth 3
}

try {
    $data = Read-HookInput
    if (-not $data) { exit 0 }
    if ($data.cwd -and (Test-Path -LiteralPath $data.cwd)) { Set-Location -LiteralPath $data.cwd }

    $text = $null
    $patternFor = $null
    switch ($data.tool_name) {
        { $_ -in 'Bash', 'PowerShell' } {
            # Claude Code on Windows runs shell commands through either tool
            # join PowerShell (`) and bash (\) line continuations into one line first
            $text = [string]$data.tool_input.command -replace '[`\\]\r?\n\s*', ' '
            # the id follows `dotnet add [<project>] package` / `dotnet package add`, optionally
            # after options (`--prerelease`, `-v 1.2.3`, `--version=1.2.3`); `Id@Version` is the
            # .NET 10 form; NuGet ids are case-insensitive; sub-packages (Moq.AutoMock) count too
            $patternFor = { param($id) '(?i)\bdotnet(?:\.exe)?\s+(?:add\b[^;&|]*?\bpackage|package\s+add)\s+(?:-{1,2}[\w-]+(?:[=:][^\s;&|]+|\s+(?!-)[^\s;&|]+)?\s+)*["'']?' + [regex]::Escape($id) + '(?=[\s.@,;&|"'']|$)' }
        }
        { $_ -in 'Write', 'Edit' } {
            if ([string]$data.tool_input.file_path -notmatch '\.(csproj|props|targets)$') { exit 0 }
            $text = if ($data.tool_name -eq 'Write') { [string]$data.tool_input.content } else { [string]$data.tool_input.new_string }
            # either quote style; Include may be an MSBuild item list ("A;B")
            $patternFor = { param($id) '(?i)<(?:Global)?Package(?:Reference|Version)\b[^>]*\bInclude\s*=\s*["''](?:[^"'';]*;)*\s*' + [regex]::Escape($id) + '(?:\.[^"'';]*)?\s*[;"'']' }
        }
        default { exit 0 }
    }
    if (-not $text) { exit 0 }

    foreach ($pkg in $banned.Keys) {
        if ($text -notmatch (& $patternFor $pkg)) { continue }
        if (Test-AlreadyReferenced $pkg) { continue }   # allowed here - still check the others
        Write-Deny $pkg
        exit 0
    }
} catch {}
exit 0
