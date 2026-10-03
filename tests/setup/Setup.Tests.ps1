#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# setup-machine.ps1 copies CLAUDE.md.example into ~/.claude/CLAUDE.md minus the note meant for
# readers of the example. The strip must work whatever line endings git checks out.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:StripLine = Get-Content (Join-Path $script:Root 'setup/setup-machine.ps1') |
        Where-Object { $_ -match 'setup:strip' } | Select-Object -First 1
}

Describe 'setup-machine.ps1 CLAUDE.md preamble strip' {
    It 'removes the preamble and its markers from a <Eol> example' -ForEach @(
        @{ Eol = 'LF'; Nl = "`n" }
        @{ Eol = 'CRLF'; Nl = "`r`n" }
    ) {
        $source = [IO.File]::ReadAllText((Join-Path $script:Root 'CLAUDE.md.example')) -replace '\r?\n', $Nl
        $example = Join-Path ([IO.Path]::GetTempPath()) ("noobit-example-" + [guid]::NewGuid().ToString('N') + '.md')
        [IO.File]::WriteAllText($example, $source)
        try {
            # the statement assigns $text from $example - run it exactly as the script does
            . ([scriptblock]::Create($script:StripLine))
            $text | Should -Not -Match 'setup:strip'
            $text | Should -Not -Match 'Copy this into'
            $text | Should -Match '^# Global conventions'
            $text | Should -Match '## Non-negotiable quality gates'
        } finally { Remove-Item -LiteralPath $example -Force }
    }

    It 'contains no raw carriage returns (git checks .ps1 out as CRLF)' {
        [IO.File]::ReadAllText((Join-Path $script:Root 'setup/setup-machine.ps1')) -match '\r(?!\n)' | Should -BeFalse
        $script:StripLine | Should -Match '\\r\?\\n'
    }
}
