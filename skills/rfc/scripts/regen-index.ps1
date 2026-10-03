#requires -Version 7.0
<#
.SYNOPSIS
    Regenerates the RFC index (index.md) from the date-named RFCs in an RFC folder.
.DESCRIPTION
    Deterministic implementation of the index rules in the noobit:rfc skill:
    one row per YYYY-MM-DD-*.md record, newest date first, ties by title (ordinal, case-insensitive);
    RFC = the H1 title (only [ ] | backslash-escaped for the table); Status = the status word
    (Superseded keeps its "by [title](file.md)" link, its text escaped the same way).
    Files whose date prefix is not a real date are skipped with a warning.
    Only the block between the BEGIN/END GENERATED markers is rewritten; text outside it is kept.
    A legacy README.md index (numbered RFCs) gets one link line at the top of the block.
.PARAMETER Path
    The RFC folder, e.g. docs/rfc.
.EXAMPLE
    pwsh -NoProfile -File regen-index.ps1 -Path docs/rfc
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$heading = '# RFCs'
$columns = '| Date | RFC | Status |'
$separator = '|------|-----|--------|'
$legacyLine = 'Earlier, numbered RFCs: [legacy index](README.md)'
$statusPattern = '^(Draft|In Review|Accepted|Rejected|Implemented|Superseded)\b'
$begin = '<!-- BEGIN GENERATED -->'
$end = '<!-- END GENERATED -->'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
$dir = (Resolve-Path -LiteralPath $Path).ProviderPath

$records = Get-ChildItem -LiteralPath $dir -File -Filter '*.md' |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-.+\.md$' }

$rows = foreach ($file in $records) {
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($file.Name.Substring(0, 10), 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
        Write-Warning "$($file.Name): date prefix is not a real date - skipped"
        continue
    }

    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding utf8)

    $titleLine = $lines | Where-Object { $_ -match '^#\s+\S' } | Select-Object -First 1
    $title = if ($titleLine) { ($titleLine -replace '^#\s+', '').Trim() } else { $null }
    if (-not $title) {
        Write-Warning "$($file.Name): no H1 title - using the file name"
        $title = $file.BaseName
    }

    $status = $null
    $statusLine = $lines | Where-Object { $_ -match '^\s*-\s*\*\*Status\*\*' } | Select-Object -First 1
    if ($statusLine) {
        $value = ($statusLine -replace '^\s*-\s*\*\*Status\*\*\s*[\p{Pd}:]*\s*', '').Trim()
        if ($value -match $statusPattern) { $status = $Matches[1] }
        # Link text may hold backslash-escaped or balanced [brackets]; it is unescaped, then re-escaped
        # like the title cell ([ ] |) so neither the link nor the table row breaks.
        $byLink = 'by\s+\[(?<text>(?:\\.|[^\[\]\\]|\[(?:\\.|[^\[\]\\])*\])+)\]\((?<href>[^)\s]+)\)'
        if ($status -eq 'Superseded' -and $value -match $byLink) {
            $byText = ($Matches.text -replace '\\([\[\]|])', '$1') -replace '([\[\]|])', '\$1'
            $status = "Superseded by [$byText]($($Matches.href))"
        }
    }
    if (-not $status) {
        Write-Warning "$($file.Name): no recognizable Status line"
        $status = 'Unknown'
    }

    [pscustomobject]@{
        Date   = $file.Name.Substring(0, 10)
        Title  = $title
        File   = $file.Name
        Status = $status
    }
}

# Culture-independent order so the index does not churn between machines: newest date first, then
# title case-insensitive ordinal, then exact ordinal, then file name (a total order -> stable output).
$sorted = [System.Collections.Generic.List[object]]::new()
foreach ($row in $rows) { $sorted.Add($row) }
$sorted.Sort([System.Comparison[object]] {
        param($x, $y)
        $c = [string]::CompareOrdinal($y.Date, $x.Date)
        if ($c -eq 0) { $c = [string]::Compare($x.Title, $y.Title, [System.StringComparison]::OrdinalIgnoreCase) }
        if ($c -eq 0) { $c = [string]::CompareOrdinal($x.Title, $y.Title) }
        if ($c -eq 0) { $c = [string]::CompareOrdinal($x.File, $y.File) }
        $c
    })

$block = [System.Collections.Generic.List[string]]::new()
$block.Add($begin)
if (Test-Path -LiteralPath (Join-Path $dir 'README.md') -PathType Leaf) {
    $block.Add($legacyLine)
    $block.Add('')
}
$block.Add($columns)
$block.Add($separator)
foreach ($row in $sorted) {
    $linkText = $row.Title -replace '([\[\]|])', '\$1'
    $block.Add("| $($row.Date) | [$linkText]($($row.File)) | $($row.Status) |")
}
$block.Add($end)
$generated = $block -join "`n"

$indexPath = Join-Path $dir 'index.md'
$content = "$heading`n`n$generated`n"
$existing = $null
if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    $existing = (Get-Content -LiteralPath $indexPath -Raw -Encoding utf8) -replace "`r`n", "`n"
    $start = $existing.IndexOf($begin)
    $stop = $existing.IndexOf($end)
    if ($start -ge 0 -and $stop -gt $start) {
        $content = $existing.Substring(0, $start) + $generated + $existing.Substring($stop + $end.Length)
    }
    else {
        Write-Warning 'index.md has no GENERATED markers - rewriting it wholesale'
    }
}

if ($content -ceq $existing) {
    Write-Output "index.md unchanged ($($sorted.Count) record(s))"
}
else {
    [System.IO.File]::WriteAllText($indexPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Output "index.md written ($($sorted.Count) record(s))"
}
