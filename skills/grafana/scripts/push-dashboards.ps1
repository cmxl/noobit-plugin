#requires -Version 7.2
<#
.SYNOPSIS
    Validates dashboard/folder resource files and pushes them to one Grafana instance with gcx.
.DESCRIPTION
    Guard rails the gcx CLI does not have (verified against gcx 1.4.0 / Grafana 13.2):
    - gcx silently skips files that are not Grafana resources (a classic dashboard JSON) and still
      exits 0, so every *.json under -Path must be a dashboard.grafana.app Dashboard (any version) or a
      folder.grafana.app/v1 Folder, and the push must report exactly that many successes.
    - gcx push is last-write-wins: it overwrites dashboards edited in the UI. Unless -Force, the push
      is refused when a target dashboard's grafana.app/updatedBy annotation (createdBy if it was never
      saved again) is a human ("user:...") AND its spec/folder differs from the repo file - pipeline
      pushes record the service account, so that combination means a UI edit would be lost.
      Identical content is pushed (a no-op) with a WARN.
      After merging such an edit into the repo, -AcceptDrift <uid>@<resourceVersion> (printed in the
      drift message) pushes that one dashboard - only while it is still at that resourceVersion.
    - After a real push, a named `gcx resources get` confirms every repo dashboard exists.
    - Offline checks: file name = metadata.name, uid rules, folder annotation, no external-sharing
      leftovers (__inputs/__requires/__elements, ${DS_*}), no numeric spec.id, and (v1 dashboards)
      datasources referenced by uid or template variable, never by name (classic specs, below v2).
.PARAMETER Path
    Folder holding the resource files (searched recursively), e.g. grafana/resources.
.PARAMETER Context
    gcx context to target (gcx config contexts). Omit in CI to use GRAFANA_SERVER / GRAFANA_TOKEN /
    GRAFANA_ORG_ID from the environment.
.PARAMETER ValidateOnly
    Offline checks only; gcx is not called (PR builds).
.PARAMETER Force
    Skip the drift guard and overwrite dashboards last saved by a human.
.PARAMETER AcceptDrift
    <uid>@<resourceVersion> entries: push these dashboards despite a human edit, because exactly that
    version was pulled and merged. A newer save (different resourceVersion) is still refused.
.PARAMETER DryRun
    Passes --dry-run to gcx push (gcx still reports each resource as succeeded).
.PARAMETER Gcx
    gcx executable (default: gcx on PATH).
.EXAMPLE
    pwsh -NoProfile -File push-dashboards.ps1 -Path grafana/resources -Context staging
.EXAMPLE
    pwsh -NoProfile -File push-dashboards.ps1 -Path grafana/resources -Context prod -AcceptDrift orders@1791140827377994
#>
[CmdletBinding(PositionalBinding = $false)]   # a stray token must fail, not land in -Context
param(
    [Parameter(Mandatory)]
    [string]$Path,
    [string]$Context,
    [switch]$ValidateOnly,
    [switch]$Force,
    [string[]]$AcceptDrift = @(),
    [switch]$DryRun,
    [string]$Gcx = 'gcx'
)

$ErrorActionPreference = 'Stop'
# gcx exit codes are handled below (exit 4 = partial push); don't let an inherited caller setting
# turn them into exceptions first
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

# `pwsh -File` passes "a,b" as one string - split it so several tokens work from every caller
$AcceptDrift = @($AcceptDrift -split ',' | ForEach-Object Trim | Where-Object { $_ -and $_ -ne 'none' })
# tokens can arrive from a pipeline parameter: accept exactly <uid>@<resourceVersion>, nothing else
foreach ($token in $AcceptDrift) {
    if ($token -notmatch '^[A-Za-z0-9_-]{1,40}@\d+$') {
        [Console]::Error.WriteLine("ERROR AcceptDrift token `"$token`" is not <uid>@<resourceVersion>")
        exit 1
    }
}

$namePattern = '^[A-Za-z0-9_-]{1,40}$'
# kinds and API groups are case-sensitive in Grafana's resource API: ordinal keys, -cmatch below
$kinds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$kinds['Dashboard'] = '^dashboard\.grafana\.app/v\d\w*$'   # pull keeps the stored version (v0alpha1, v1, v2, ...)
$kinds['Folder'] = '^folder\.grafana\.app/v1$'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Folder not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath
# -Force: gcx also pushes dot-folders/dot-files (Unix) and Hidden-attribute files (Windows)
$files = @(Get-ChildItem -LiteralPath $root -File -Filter '*.json' -Recurse -Force | Sort-Object FullName)
# gcx push also reads YAML resources - they would go out unvalidated and outside the drift guard
$yaml = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Where-Object Extension -In '.yaml', '.yml' | Sort-Object FullName)

$problems = [System.Collections.Generic.List[string]]::new()
$dashboards = [System.Collections.Generic.List[string]]::new()
$seen = @{}

# Key-order-independent JSON of a parsed value: compares a repo file with the instance's copy.
function ConvertTo-CanonicalJson($Node) {
    function Get-SortedNode($n) {
        if ($n -is [System.Collections.IDictionary]) {
            $o = [ordered]@{}
            foreach ($k in ($n.Keys | Sort-Object -CaseSensitive { [string]$_ })) { $o[[string]$k] = Get-SortedNode $n[$k] }
            return $o
        }
        if ($n -is [System.Collections.IList]) { return , @(foreach ($i in $n) { Get-SortedNode $i }) }
        return $n
    }
    ConvertTo-Json -InputObject (Get-SortedNode $Node) -Depth 100 -Compress
}
$localContent = @{}   # dashboard name -> canonical {spec, folder}

function Add-Problem([System.IO.FileInfo]$File, [string]$Message) {
    $problems.Add("$([System.IO.Path]::GetRelativePath($root, $File.FullName)): $Message")
}

# Walks the spec once: ${DS_*} placeholders anywhere; for v1 dashboards also datasource references.
function Test-Node($Node, [System.IO.FileInfo]$File, [bool]$CheckDatasources) {
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $value = $Node[$key]
            if ($CheckDatasources -and $key -eq 'datasource' -and $null -ne $value) {
                if ($value -is [string]) {
                    if (-not $value.StartsWith('$')) { Add-Problem $File "datasource `"$value`" referenced by name - use {type, uid}" }
                }
                elseif ($value -is [System.Collections.IDictionary] -and -not $value['uid']) {
                    Add-Problem $File 'datasource without uid - pin the uid (or a ${datasource} variable)'
                }
            }
            Test-Node $value $File $CheckDatasources
        }
    }
    elseif ($Node -is [System.Collections.IList]) {
        foreach ($item in $Node) { Test-Node $item $File $CheckDatasources }
    }
    elseif ($Node -is [string] -and $Node.Contains('${DS_')) {
        Add-Problem $File "`"$Node`": `${DS_*} placeholder from an external-sharing export - use the real datasource uid"
    }
}

foreach ($file in $yaml) { Add-Problem $file 'YAML resource - gcx would push it unvalidated; keep resources as JSON (gcx resources pull -o json)' }

foreach ($file in $files) {
    # -NoEnumerate: a top-level [ {...} ] must stay an array, not be unrolled into its single object
    try { $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate }
    catch { Add-Problem $file 'invalid JSON'; continue }

    $kind = if ($doc -is [System.Collections.IDictionary]) { [string]$doc['kind'] } else { '' }
    if ($kind -and $kind -notin 'Dashboard', 'Folder') {   # -notin is case-insensitive: 'dashboard' falls through
        Add-Problem $file "unsupported kind `"$kind`" - only Dashboard and Folder resources belong under -Path; move it out"
        continue
    }
    if (-not $kinds.ContainsKey($kind) -or [string]$doc['apiVersion'] -cnotmatch $kinds[$kind]) {
        Add-Problem $file 'not a Grafana resource (apiVersion dashboard.grafana.app/<version> or folder.grafana.app/v1, kind Dashboard|Folder - case-sensitive - + metadata + spec) - gcx would skip it silently; wrap a classic export first'
        continue
    }
    $meta = $doc['metadata']
    $spec = $doc['spec']
    if ($meta -isnot [System.Collections.IDictionary]) { Add-Problem $file 'metadata must be an object'; continue }
    if ($spec -isnot [System.Collections.IDictionary]) { Add-Problem $file 'spec must be an object' }
    $annotations = $meta['annotations'] ?? @{}
    if ($annotations -isnot [System.Collections.IDictionary]) { Add-Problem $file 'metadata.annotations must be an object'; continue }
    $name = [string]$meta['name']

    if ($name -notmatch $namePattern) { Add-Problem $file "metadata.name `"$name`" must be 1-40 chars of A-Z a-z 0-9 _ -"; continue }
    if ($file.BaseName -ne $name) { Add-Problem $file "file name must be $name.json (= metadata.name)" }
    if ($seen.ContainsKey("$kind/$name")) { Add-Problem $file "duplicate $kind `"$name`" (also $($seen["$kind/$name"]))" }
    $seen["$kind/$name"] = $file.Name

    if ($kind -ne 'Dashboard') { continue }
    $dashboards.Add($name)
    $localContent[$name] = ConvertTo-CanonicalJson @{ spec = $spec; folder = $annotations['grafana.app/folder'] }
    if ($spec -isnot [System.Collections.IDictionary]) { continue }

    if (-not $annotations['grafana.app/folder']) { Add-Problem $file 'missing metadata.annotations."grafana.app/folder" - dashboards belong in a folder, not General' }
    foreach ($key in '__inputs', '__requires', '__elements') {
        if ($spec.Contains($key)) { Add-Problem $file "spec.$key present - external-sharing export; re-export without `"share with another instance`"" }
    }
    if ($null -ne $spec['id']) { Add-Problem $file 'spec.id must not be set - the instance assigns it (remove it)' }
    if ($spec['uid'] -and $spec['uid'] -ne $name) { Add-Problem $file "spec.uid `"$($spec['uid'])`" differs from metadata.name `"$name`"" }

    Test-Node $spec $file ([string]$doc['apiVersion'] -notmatch '/v2')   # classic JSON spec below v2
}

if ($files.Count -eq 0) { $problems.Add("no *.json resource files under $Path") }
if ($problems.Count) {
    foreach ($p in $problems) { [Console]::Error.WriteLine("ERROR $p") }
    [Console]::Error.WriteLine("$($problems.Count) problem(s) - nothing pushed")
    exit 1
}
Write-Output "$($files.Count) resource file(s) valid ($($dashboards.Count) dashboard(s))"
if ($ValidateOnly) { exit 0 }

$gcxExe = $Gcx
$contextArgs = @()   # assigned, not `if/else @()` - that yields $null, which splats as an empty argument
if ($Context) { $contextArgs = @('--context', $Context) }

function Invoke-Gcx([string]$What, [string[]]$Arguments) {
    # stdout carries the JSON; stderr (hints, network errors) arrives as ErrorRecords under 2>&1
    $records = & $gcxExe @contextArgs @Arguments 2>&1
    $code = $LASTEXITCODE
    $out = ($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    # exit 4 = partial failure (gcx 1.4.0): the JSON summary still lists every failure - let the caller report it
    if ($code -ne 0 -and -not ($code -eq 4 -and $What -eq 'push')) {
        $err = ($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
        [Console]::Error.WriteLine("ERROR gcx resources $What failed (exit $code): $out $err".TrimEnd())
        exit 1
    }
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($out)) {
        try { $json = $out | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $json = $null }
    }
    if ($json -isnot [System.Collections.IDictionary]) {
        [Console]::Error.WriteLine("ERROR gcx resources $What returned no JSON: $out")
        exit 1
    }
    return $json
}

if (-not $Force -and $dashboards.Count) {
    # --limit 0: gcx get returns only the first 50 items per type by default (gcx 1.4.0)
    $remote = Invoke-Gcx 'get' @('resources', 'get', 'dashboards', '--limit', '0', '-o', 'json')
    $drifted = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($remote['items'] ?? @())) {
        $name = [string]$item['metadata']['name']
        $annotations = $item['metadata']['annotations'] ?? @{}
        # created in the UI and never saved again: only createdBy/creationTimestamp exist (verified)
        $by = [string]($annotations['grafana.app/updatedBy'] ?? $annotations['grafana.app/createdBy'])
        $at = $annotations['grafana.app/updatedTimestamp'] ?? $item['metadata']['creationTimestamp']
        if ($at -is [datetime]) { $at = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }   # ConvertFrom-Json parses ISO dates
        if (-not ($dashboards.Contains($name) -and $by.StartsWith('user:'))) { continue }
        # identical content: nothing to lose. Grafana treats the push as a no-op, so updatedBy stays
        # user:... - comparing content (not just the editor) keeps such dashboards from drifting forever.
        # In practice only a pulled file compares equal: the server adds defaults to hand-written specs.
        $remoteContent = ConvertTo-CanonicalJson @{ spec = $item['spec']; folder = $annotations['grafana.app/folder'] }
        if ($remoteContent -ceq $localContent[$name]) {
            # stdout warning, not stderr: the push still goes ahead
            Write-Output "WARN ${name}: identical to the repo but last saved by $by - the push is a no-op, so the next repo change will report DRIFT once. Give the adoption commit a real change (e.g. editable: false, a managed tag) so the pipeline's account writes it."
            continue
        }
        # resourceVersion changes on every save: accepting it pins the exact version that was merged
        $token = "$name@$($item['metadata']['resourceVersion'])"
        if ($AcceptDrift -contains $token) { Write-Output "accepted drift on $name ($token)"; continue }
        $drifted.Add("${name}: last saved by $by at $at - once merged: -AcceptDrift $token")
    }
    if ($drifted.Count) {
        foreach ($d in $drifted) { [Console]::Error.WriteLine("DRIFT $d") }
        [Console]::Error.WriteLine('Edited in the UI since the last push. Pull (gcx resources pull dashboards/<name>), merge into the repo file, commit, rerun with the -AcceptDrift token(s) above - or -Force to discard the UI edits.')
        exit 1
    }
}

# --omit-manager-fields: otherwise gcx stamps grafana.app/sourcePath (the runner's absolute file path)
# on every dashboard. The drift guard only needs updatedBy/createdBy, which Grafana sets itself.
$pushArgs = @('resources', 'push', '-p', $root, '--omit-manager-fields', '-o', 'json')
if ($DryRun) { $pushArgs += '--dry-run' }
$result = Invoke-Gcx 'push' $pushArgs
$summary = $result['summary'] ?? @{}
$succeeded = [int]($summary['succeeded'] ?? 0)
$failed = [int]($summary['failed'] ?? 0)
if ($failed -or $succeeded -ne $files.Count) {
    foreach ($f in @($result['failures'] ?? @())) { [Console]::Error.WriteLine("ERROR $($f | ConvertTo-Json -Compress -Depth 10)") }
    [Console]::Error.WriteLine("ERROR gcx pushed $succeeded of $($files.Count) resource file(s), $failed failed")
    exit 1
}
# Don't rely on gcx's counter alone: one review saw summary.succeeded include a dashboard that never
# reached the server (not reproduced). A named get proves each repo dashboard exists.
if (-not $DryRun -and $dashboards.Count) {
    $present = Invoke-Gcx 'verify' @('resources', 'get', "dashboards/$($dashboards -join ',')", '-o', 'json')
    # gcx 1.4.0 answers one name with the bare object, several with {"items": [...]}
    $objects = if ($present.Contains('items')) { @($present['items']) } else { @($present) }
    $found = @($objects | ForEach-Object { [string]($_['metadata'] ?? @{})['name'] })
    $missing = @($dashboards | Where-Object { $_ -notin $found })
    if ($missing.Count) {
        [Console]::Error.WriteLine("ERROR gcx reported success, but the post-push get did not return: $($missing -join ', ') (gcx 1.4.0 returns no items when any requested name is missing, so at least one of them is not on the instance)")
        exit 1
    }
}
Write-Output "pushed $succeeded resource(s)$(if ($DryRun) { ' (dry run)' })$(if ($Context) { " to context $Context" })"
