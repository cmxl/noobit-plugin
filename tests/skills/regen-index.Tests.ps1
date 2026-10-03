#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:AdrScript = Join-Path $repoRoot 'skills' 'adr' 'scripts' 'regen-index.ps1'
    $script:RfcScript = Join-Path $repoRoot 'skills' 'rfc' 'scripts' 'regen-index.ps1'

    function Write-Record([string]$Dir, [string]$Name, [string]$Title, [string]$Status) {
        $body = "# $Title`n`n- **Status** $([char]0x2014) $Status`n`n## Context`nText.`n"
        Set-Content -LiteralPath (Join-Path $Dir $Name) -Value $body -NoNewline -Encoding utf8
    }

    function Get-Index([string]$Dir) {
        Get-Content -LiteralPath (Join-Path $Dir 'index.md') -Raw -Encoding utf8
    }

    function Get-TableRow([string]$Dir) {
        @((Get-Index $Dir) -split "`n" | Where-Object { $_ -match '^\| \d{4}-' })
    }
}

Describe 'adr regen-index.ps1' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }

    It 'writes a header-only table for an empty folder' {
        & $script:AdrScript -Path $script:dir | Out-Null

        $index = Get-Index $script:dir
        $index | Should -Match '^# Decision Records\n'
        $index | Should -Match '<!-- BEGIN GENERATED -->\n\| Date \| Decision \| Status \|\n\|------\|----------\|--------\|\n<!-- END GENERATED -->'
        Get-TableRow $script:dir | Should -HaveCount 0
    }

    It 'lists records newest first, ties by title, and ignores non-record files' {
        Write-Record $script:dir '2026-08-02-fusioncache-only.md' 'Adopt FusionCache as the only cache abstraction' 'Accepted 2026-08-02'
        Write-Record $script:dir '2026-08-20-zeta.md' 'Zeta decision' 'Proposed 2026-08-20'
        Write-Record $script:dir '2026-08-20-alpha.md' 'Alpha decision' 'Rejected 2026-08-21'
        Write-Record $script:dir '0001-legacy-numbered.md' 'Legacy numbered' 'Accepted'
        Set-Content -LiteralPath (Join-Path $script:dir 'notes.md') -Value '# Notes' -Encoding utf8

        & $script:AdrScript -Path $script:dir | Out-Null

        $rows = Get-TableRow $script:dir
        $rows | Should -HaveCount 3
        $rows[0] | Should -Be '| 2026-08-20 | [Alpha decision](2026-08-20-alpha.md) | Rejected |'
        $rows[1] | Should -Be '| 2026-08-20 | [Zeta decision](2026-08-20-zeta.md) | Proposed |'
        $rows[2] | Should -Be '| 2026-08-02 | [Adopt FusionCache as the only cache abstraction](2026-08-02-fusioncache-only.md) | Accepted |'
    }

    It 'skips a file whose date prefix is not a real date, with a warning' {
        Write-Record $script:dir '2026-13-40-bad-date.md' 'Bad date' 'Accepted 2026-01-01'
        Write-Record $script:dir '2026-02-30-no-such-day.md' 'No such day' 'Accepted 2026-01-01'
        Write-Record $script:dir '2026-09-01-good.md' 'Good date' 'Accepted 2026-09-01'

        $warnings = @()
        & $script:AdrScript -Path $script:dir -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        $rows = @(Get-TableRow $script:dir)
        $rows | Should -HaveCount 1
        $rows[0] | Should -Be '| 2026-09-01 | [Good date](2026-09-01-good.md) | Accepted |'
        ($warnings | Where-Object { "$_" -match '2026-13-40-bad-date\.md' }) | Should -Not -BeNullOrEmpty
        ($warnings | Where-Object { "$_" -match '2026-02-30-no-such-day\.md' }) | Should -Not -BeNullOrEmpty
    }

    It 'breaks date ties by title ordinally (culture-independent, case-insensitive first)' {
        $umlautTitle = "$([char]0x00C4)pfel decision"   # A-umlaut: culture sorts it near A, ordinal after Z
        Write-Record $script:dir '2026-08-20-umlaut.md' $umlautTitle 'Accepted 2026-08-20'
        Write-Record $script:dir '2026-08-20-zeta.md' 'Zeta decision' 'Accepted 2026-08-20'
        Write-Record $script:dir '2026-08-20-beta.md' 'Beta decision' 'Accepted 2026-08-20'
        Write-Record $script:dir '2026-08-20-alpha.md' 'alpha decision' 'Accepted 2026-08-20'

        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            & $script:AdrScript -Path $script:dir | Out-Null
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }

        $rows = Get-TableRow $script:dir
        $rows | Should -HaveCount 4
        $rows[0] | Should -Match '\[alpha decision\]'
        $rows[1] | Should -Match '\[Beta decision\]'
        $rows[2] | Should -Match '\[Zeta decision\]'
        $rows[3] | Should -Match '2026-08-20-umlaut\.md'
    }

    It 'keeps the "by [title](file.md)" link on superseded records' {
        Write-Record $script:dir '2026-01-10-old.md' 'Old choice' 'Superseded 2026-09-01 by [New choice](2026-09-01-new.md)'
        Write-Record $script:dir '2026-09-01-new.md' 'New choice' 'Accepted 2026-09-01'

        & $script:AdrScript -Path $script:dir | Out-Null

        $rows = Get-TableRow $script:dir
        $rows[1] | Should -Be '| 2026-01-10 | [Old choice](2026-01-10-old.md) | Superseded by [New choice](2026-09-01-new.md) |'
    }

    It 'keeps the superseded link when its title has brackets (<Case>)' -ForEach @(
        @{ Case = 'escaped'; LinkText = 'Use \[v2\] cache' }
        @{ Case = 'balanced, unescaped'; LinkText = 'Use [v2] cache' }
    ) {
        Write-Record $script:dir '2026-01-10-old.md' 'Old choice' "Superseded 2026-09-01 by [$LinkText](2026-09-01-v2.md)"
        Write-Record $script:dir '2026-09-01-v2.md' 'Use [v2] cache' 'Accepted 2026-09-01'

        & $script:AdrScript -Path $script:dir | Out-Null

        $rows = Get-TableRow $script:dir
        $rows[0] | Should -Be '| 2026-09-01 | [Use \[v2\] cache](2026-09-01-v2.md) | Accepted |'
        $rows[1] | Should -Be '| 2026-01-10 | [Old choice](2026-01-10-old.md) | Superseded by [Use \[v2\] cache](2026-09-01-v2.md) |'
    }

    It 'escapes a pipe in the superseded link text so the table keeps three columns' {
        Write-Record $script:dir '2026-01-10-old.md' 'Old choice' 'Superseded 2026-09-01 by [Reads | writes split](2026-09-01-split.md)'

        & $script:AdrScript -Path $script:dir | Out-Null

        $row = @(Get-TableRow $script:dir)[0]
        $row | Should -Be '| 2026-01-10 | [Old choice](2026-01-10-old.md) | Superseded by [Reads \| writes split](2026-09-01-split.md) |'
        ([regex]::Matches($row, '(?<!\\)\|')).Count | Should -Be 4
    }

    It 'links a legacy README.md index once, at the top of the generated block' {
        Set-Content -LiteralPath (Join-Path $script:dir 'README.md') -Value '# Legacy ADRs' -Encoding utf8
        Write-Record $script:dir '2026-09-01-new.md' 'New choice' 'Accepted 2026-09-01'

        & $script:AdrScript -Path $script:dir | Out-Null

        $index = Get-Index $script:dir
        $index | Should -Match '<!-- BEGIN GENERATED -->\nEarlier, numbered records: \[legacy index\]\(README\.md\)\n\n\| Date'
        ([regex]::Matches($index, 'README\.md')).Count | Should -Be 1
    }

    It 'is idempotent and preserves text outside the markers' {
        Write-Record $script:dir '2026-09-01-new.md' 'New choice' 'Accepted 2026-09-01'
        & $script:AdrScript -Path $script:dir | Out-Null
        $indexPath = Join-Path $script:dir 'index.md'
        $withIntro = (Get-Index $script:dir) -replace '# Decision Records\n', "# Decision Records`n`nIntro kept.`n"
        [System.IO.File]::WriteAllText($indexPath, $withIntro)

        $first = & $script:AdrScript -Path $script:dir
        $afterFirst = Get-Index $script:dir
        $second = & $script:AdrScript -Path $script:dir
        $afterSecond = Get-Index $script:dir

        $afterFirst | Should -Match 'Intro kept\.'
        $afterSecond | Should -BeExactly $afterFirst
        $first | Should -Match 'unchanged'
        $second | Should -Match 'unchanged'
    }

    It 'fails for a missing folder' {
        { & $script:AdrScript -Path (Join-Path $TestDrive 'does-not-exist') } | Should -Throw '*Folder not found*'
    }
}

Describe 'rfc regen-index.ps1' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }

    It 'uses the RFC heading and columns for an empty folder' {
        & $script:RfcScript -Path $script:dir | Out-Null

        $index = Get-Index $script:dir
        $index | Should -Match '^# RFCs\n'
        $index | Should -Match '\| Date \| RFC \| Status \|\n\|------\|-----\|--------\|\n<!-- END GENERATED -->'
    }

    It 'parses multi-word and superseded statuses and sorts newest first' {
        Write-Record $script:dir '2026-07-14-outbox.md' 'Adopt the outbox pattern' 'Superseded 2026-09-30 by [Event bus v2](2026-09-30-event-bus-v2.md)'
        Write-Record $script:dir '2026-09-30-event-bus-v2.md' 'Event bus v2' 'In Review 2026-10-01'
        Set-Content -LiteralPath (Join-Path $script:dir 'README.md') -Value '# Legacy RFCs' -Encoding utf8

        & $script:RfcScript -Path $script:dir | Out-Null

        $rows = Get-TableRow $script:dir
        $rows[0] | Should -Be '| 2026-09-30 | [Event bus v2](2026-09-30-event-bus-v2.md) | In Review |'
        $rows[1] | Should -Be '| 2026-07-14 | [Adopt the outbox pattern](2026-07-14-outbox.md) | Superseded by [Event bus v2](2026-09-30-event-bus-v2.md) |'
        Get-Index $script:dir | Should -Match 'Earlier, numbered RFCs: \[legacy index\]\(README\.md\)'
    }

    It 'keeps a superseded link whose title has brackets and a pipe' {
        Write-Record $script:dir '2026-07-14-outbox.md' 'Adopt the outbox pattern' 'Superseded 2026-09-30 by [Event bus \[v2\] | relay](2026-09-30-event-bus-v2.md)'

        & $script:RfcScript -Path $script:dir | Out-Null

        $row = @(Get-TableRow $script:dir)[0]
        $row | Should -Be '| 2026-07-14 | [Adopt the outbox pattern](2026-07-14-outbox.md) | Superseded by [Event bus \[v2\] \| relay](2026-09-30-event-bus-v2.md) |'
        ([regex]::Matches($row, '(?<!\\)\|')).Count | Should -Be 4
    }
}
