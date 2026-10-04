#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:Push = Join-Path $repoRoot 'skills' 'grafana' 'scripts' 'push-dashboards.ps1'

    # Stand-in for the gcx CLI: records its arguments, answers `resources get` with $env:FAKE_GCX_GET
    # and `resources push` with $env:FAKE_GCX_PUSH (both raw JSON), writes $env:FAKE_GCX_STDERR to the
    # error stream (what a native gcx's stderr becomes under 2>&1), exits with $env:FAKE_GCX_EXIT.
    $script:FakeGcx = Join-Path $TestDrive 'fake-gcx.ps1'
    Set-Content -LiteralPath $script:FakeGcx -Encoding utf8 -Value @'
$ErrorActionPreference = 'Continue'
Add-Content -LiteralPath $env:FAKE_GCX_LOG -Value ($args -join ' ')
if ($env:FAKE_GCX_STDERR) { Write-Error $env:FAKE_GCX_STDERR }
$named = @($args | Where-Object { $_ -like 'dashboards/*' })
if ($args -contains 'get' -and $named) {
    # post-push verification (`get dashboards/a,b`): echo every name except $env:FAKE_GCX_MISSING
    # like real gcx 1.4.0: one name -> the bare object, several -> {"items": [...]}, and if ANY requested
    # name is missing -> {"items": []} with exit 0 (verified by review)
    $names = @($named[0].Substring(11) -split ',')
    if ($names -contains $env:FAKE_GCX_MISSING) { '{"items":[]}' }
    elseif ($names.Count -eq 1) { @{ kind = 'Dashboard'; metadata = @{ name = $names[0] } } | ConvertTo-Json -Depth 5 }
    else { @{ items = @(foreach ($n in $names) { @{ kind = 'Dashboard'; metadata = @{ name = $n } } }) } | ConvertTo-Json -Depth 5 }
}
elseif ($args -contains 'get') { $env:FAKE_GCX_GET }
elseif ($args -contains 'push') { $env:FAKE_GCX_PUSH }
exit [int]$env:FAKE_GCX_EXIT
'@

    function Write-DashboardFile([string]$Dir, [string]$Name, [hashtable]$Spec = @{}, [string]$Folder = 'platform',
        [string]$ApiVersion = 'dashboard.grafana.app/v1', [string]$FileName = "$Name.json") {
        $body = [ordered]@{ title = $Name; schemaVersion = 42; panels = @() }
        foreach ($k in $Spec.Keys) { $body[$k] = $Spec[$k] }
        $meta = [ordered]@{ name = $Name }
        if ($Folder) { $meta.annotations = @{ 'grafana.app/folder' = $Folder } }
        $doc = [ordered]@{ apiVersion = $ApiVersion; kind = 'Dashboard'; metadata = $meta; spec = $body }
        Set-Content -LiteralPath (Join-Path $Dir $FileName) -Value ($doc | ConvertTo-Json -Depth 20) -Encoding utf8
    }

    function Write-FolderFile([string]$Dir, [string]$Name) {
        $doc = [ordered]@{ apiVersion = 'folder.grafana.app/v1'; kind = 'Folder'; metadata = @{ name = $Name }; spec = @{ title = $Name } }
        Set-Content -LiteralPath (Join-Path $Dir "$Name.json") -Value ($doc | ConvertTo-Json -Depth 5) -Encoding utf8
    }

    function Get-RemoteJson([hashtable]$UpdatedBy, [hashtable]$CreatedOnly = @{}) {
        $items = @(foreach ($name in $UpdatedBy.Keys) {
                @{ kind = 'Dashboard'; metadata = @{ name = $name; resourceVersion = '1791140827377994'; annotations = @{
                            'grafana.app/updatedBy' = $UpdatedBy[$name]; 'grafana.app/updatedTimestamp' = '2026-10-01T10:00:00Z' } } }
            }) + @(foreach ($name in $CreatedOnly.Keys) {
                # created in the UI and never saved again: Grafana sets only createdBy (verified)
                @{ kind = 'Dashboard'; metadata = @{ name = $name; resourceVersion = '1791140827377995'
                        creationTimestamp = '2026-10-01T09:00:00Z'; annotations = @{ 'grafana.app/createdBy' = $CreatedOnly[$name] } } }
            })
        @{ items = $items } | ConvertTo-Json -Depth 10
    }

    function Invoke-Push([string[]]$Extra = @()) {
        $params = @('-NoProfile', '-File', $script:Push, '-Path', $script:dir, '-Gcx', $script:FakeGcx) + $Extra
        $output = & pwsh @params 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $output }
    }

    function Get-GcxCall { if (Test-Path $env:FAKE_GCX_LOG) { @(Get-Content -LiteralPath $env:FAKE_GCX_LOG) } else { @() } }
}

Describe 'grafana push-dashboards.ps1' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        $env:FAKE_GCX_LOG = Join-Path $script:dir '..' "$([guid]::NewGuid().ToString('N')).log"
        $env:FAKE_GCX_GET = '{"items":[]}'
        $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":0,"failed":0},"failures":[]}'
        $env:FAKE_GCX_EXIT = '0'
        $env:FAKE_GCX_STDERR = ''
        $env:FAKE_GCX_MISSING = ''
    }

    Context 'offline validation (-ValidateOnly)' {
        It 'accepts well-formed dashboards and folders without calling gcx' {
            Write-FolderFile $script:dir 'platform'
            Write-DashboardFile $script:dir 'api-overview' -Spec @{ panels = @(@{ id = 1; type = 'timeseries'
                        datasource = @{ type = 'prometheus'; uid = 'prometheus' } }) }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '2 resource file\(s\) valid'
            Get-GcxCall | Should -HaveCount 0
        }

        It 'searches subfolders' {
            $sub = Join-Path $script:dir 'checkout'
            New-Item -ItemType Directory -Path $sub | Out-Null
            Write-DashboardFile $sub 'checkout-funnel'

            (Invoke-Push '-ValidateOnly').Output | Should -Match '1 resource file\(s\) valid'
        }

        It 'rejects a classic (unwrapped) dashboard JSON, which gcx would skip silently' {
            Set-Content -LiteralPath (Join-Path $script:dir 'classic.json') -Value '{"uid":"classic","title":"x","panels":[]}'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'classic\.json: not a Grafana resource'
        }

        It 'rejects invalid JSON' {
            Set-Content -LiteralPath (Join-Path $script:dir 'broken.json') -Value '{"apiVersion": '

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'broken\.json: invalid JSON'
        }

        It 'rejects external-sharing exports (__inputs / ${DS_*} placeholders)' {
            Write-DashboardFile $script:dir 'shared' -Spec @{ __inputs = @(@{ name = 'DS_PROMETHEUS' })
                panels = @(@{ id = 1; datasource = @{ type = 'prometheus'; uid = '${DS_PROMETHEUS}' } }) }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match '__inputs'
            $r.Output | Should -Match '\$\{DS_'
        }

        It 'rejects a numeric id, a uid that differs from metadata.name, and a file name that differs from it' {
            Write-DashboardFile $script:dir 'orders' -Spec @{ id = 42; uid = 'other' } -FileName 'orders-dash.json'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'spec\.id'
            $r.Output | Should -Match 'spec\.uid "other"'
            $r.Output | Should -Match 'file name must be orders\.json'
        }

        It 'rejects invalid and duplicate names' {
            Write-DashboardFile $script:dir 'bad name!' -FileName 'bad.json'
            Write-DashboardFile $script:dir 'twin' -FileName 'twin.json'
            $sub = Join-Path $script:dir 'copy'
            New-Item -ItemType Directory -Path $sub | Out-Null
            Write-DashboardFile $sub 'twin'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'metadata\.name "bad name!"'
            $r.Output | Should -Match 'duplicate Dashboard "twin"'
        }

        It 'requires a folder annotation on dashboards' {
            Write-DashboardFile $script:dir 'rootless' -Folder ''

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'grafana\.app/folder'
        }

        It 'rejects datasource references by name or without uid in v1 dashboards, allows template variables' {
            Write-DashboardFile $script:dir 'by-name' -Spec @{ panels = @(
                    @{ id = 1; datasource = 'Prometheus' },
                    @{ id = 2; datasource = @{ type = 'prometheus' } },
                    @{ id = 3; datasource = @{ type = 'prometheus'; uid = '${datasource}' } },
                    @{ id = 4; datasource = '$datasource' }) }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'datasource "Prometheus" referenced by name'
            $r.Output | Should -Match 'datasource without uid'
            ([regex]::Matches($r.Output, 'by-name\.json:')).Count | Should -Be 2
        }

        It 'accepts v2 dashboards (datasource rules are v1-only)' {
            Write-DashboardFile $script:dir 'dyn' -ApiVersion 'dashboard.grafana.app/v2' -Spec @{
                elements = @{ 'panel-1' = @{ kind = 'Panel'; spec = @{ data = @{ spec = @{ queries = @(
                                        @{ spec = @{ query = @{ datasource = @{ name = 'prometheus' } } } }) } } } } } }

            (Invoke-Push '-ValidateOnly').Exit | Should -Be 0
        }

        It 'accepts any stored dashboard API version gcx pulls (v0alpha1 for API-created dashboards), with classic checks' {
            Write-DashboardFile $script:dir 'legacy' -ApiVersion 'dashboard.grafana.app/v0alpha1'
            Write-DashboardFile $script:dir 'legacy-by-name' -ApiVersion 'dashboard.grafana.app/v1beta1' -Spec @{ panels = @(@{ id = 1; datasource = 'Prometheus' }) }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Not -Match 'legacy\.json'
            $r.Output | Should -Match 'legacy-by-name\.json: datasource "Prometheus"'
        }

        It 'validates files in dot-folders and hidden files, which gcx pushes too' {
            $hidden = Join-Path $script:dir '.hidden'
            New-Item -ItemType Directory -Path $hidden | Out-Null
            Write-DashboardFile $hidden 'sneaky' -Folder ''
            Write-DashboardFile $script:dir 'shy' -Folder ''
            # Get-ChildItem skips dot-entries on Unix and Hidden-attribute files on Windows unless -Force
            if ($IsWindows) { (Get-Item -LiteralPath (Join-Path $script:dir 'shy.json')).Attributes += 'Hidden' }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'sneaky\.json: missing metadata\.annotations'
            $r.Output | Should -Match 'shy\.json: missing metadata\.annotations'
        }

        It 'rejects YAML files, which gcx would push unvalidated' {
            Write-DashboardFile $script:dir 'api-overview'
            Set-Content -LiteralPath (Join-Path $script:dir 'orders.yaml') -Value "apiVersion: dashboard.grafana.app/v1`nkind: Dashboard"
            Set-Content -LiteralPath (Join-Path $script:dir 'other.yml') -Value 'kind: Folder'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'orders\.yaml: .*JSON'
            $r.Output | Should -Match 'other\.yml: .*JSON'
        }

        It 'names the file when metadata, annotations or spec have the wrong shape, and requires spec' {
            Set-Content -LiteralPath (Join-Path $script:dir 'meta.json') -Value '{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":"x","spec":{}}'
            Set-Content -LiteralPath (Join-Path $script:dir 'ann.json') -Value '{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":{"name":"ann","annotations":"f"},"spec":{}}'
            Set-Content -LiteralPath (Join-Path $script:dir 'arr.json') -Value '{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":{"name":"arr","annotations":{"grafana.app/folder":"p"}},"spec":[]}'
            Set-Content -LiteralPath (Join-Path $script:dir 'nospec.json') -Value '{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":{"name":"nospec","annotations":{"grafana.app/folder":"p"}}}'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'meta\.json: metadata must be an object'
            $r.Output | Should -Match 'ann\.json: metadata\.annotations must be an object'
            $r.Output | Should -Match 'arr\.json: spec must be an object'
            $r.Output | Should -Match 'nospec\.json: spec must be an object'
            $r.Output | Should -Not -Match 'Cannot convert'
        }

        It 'fails when the folder contains no resource files' {
            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'no \*\.json'
        }

        It 'fails before calling gcx when -Path is not an existing folder' {
            $script:dir = Join-Path $TestDrive 'does-not-exist'

            $r = Invoke-Push

            $r.Exit | Should -Not -Be 0
            $r.Output | Should -Match 'Folder not found'
            Get-GcxCall | Should -HaveCount 0
        }

        It 'names an unsupported resource kind instead of suggesting a classic-export wrap' {
            # e.g. a LibraryPanel or DataSource from a broad `gcx resources pull`
            Set-Content -LiteralPath (Join-Path $script:dir 'x.json') -Value '{"apiVersion":"dashboard.grafana.app/v1","kind":"LibraryPanel","metadata":{"name":"x"},"spec":{}}'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'x\.json: unsupported kind "LibraryPanel"'
            $r.Output | Should -Not -Match 'wrap a classic export'
        }

        It 'rejects <Case>, which gcx would not push as a dashboard or folder' -ForEach @(
            @{ Case = 'a Folder with an unsupported apiVersion'; Json = '{"apiVersion":"folder.grafana.app/v2","kind":"Folder","metadata":{"name":"x"},"spec":{}}' }
            @{ Case = 'a Dashboard under the folder API group'; Json = '{"apiVersion":"folder.grafana.app/v1","kind":"Dashboard","metadata":{"name":"x"},"spec":{}}' }
            # ConvertFrom-Json unrolls a one-element array into its object unless told not to
            @{ Case = 'a JSON array holding one resource'; Json = '[{"apiVersion":"dashboard.grafana.app/v1","kind":"Dashboard","metadata":{"name":"x","annotations":{"grafana.app/folder":"p"}},"spec":{"title":"x"}}]' }
            # kinds and API groups are case-sensitive in Grafana's resource API
            @{ Case = 'a lower-case kind'; Json = '{"apiVersion":"dashboard.grafana.app/v1","kind":"dashboard","metadata":{"name":"x","annotations":{"grafana.app/folder":"p"}},"spec":{"title":"x"}}' }
            @{ Case = 'a mixed-case apiVersion'; Json = '{"apiVersion":"Dashboard.Grafana.App/V1","kind":"Dashboard","metadata":{"name":"x","annotations":{"grafana.app/folder":"p"}},"spec":{"title":"x"}}' }
            @{ Case = 'a lower-case Folder kind'; Json = '{"apiVersion":"folder.grafana.app/v1","kind":"folder","metadata":{"name":"x"},"spec":{"title":"x"}}' }
        ) {
            Set-Content -LiteralPath (Join-Path $script:dir 'x.json') -Value $Json

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'x\.json: not a Grafana resource'
            $r.Output | Should -Not -Match 'Cannot index|Exception'
        }

        It 'rejects each external-sharing leftover (<Key>) on its own' -ForEach @(
            @{ Key = '__requires' }
            @{ Key = '__elements' }
        ) {
            Write-DashboardFile $script:dir 'shared' -Spec @{ $Key = @() }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match "shared\.json: spec\.$Key present"
        }

        It 'rejects ${DS_*} placeholders in v2 dashboards too' {
            Write-DashboardFile $script:dir 'dyn' -ApiVersion 'dashboard.grafana.app/v2' -Spec @{
                elements = @{ 'panel-1' = @{ kind = 'Panel'; spec = @{ data = @{ spec = @{ queries = @(
                                        @{ spec = @{ query = @{ datasource = @{ name = '${DS_PROMETHEUS}' } } } }) } } } } } }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'dyn\.json: "\$\{DS_PROMETHEUS\}"'
        }

        It 'accepts a spec.uid equal to metadata.name and a null datasource (panel default)' {
            Write-DashboardFile $script:dir 'orders' -Spec @{ uid = 'orders'; panels = @(@{ id = 1; datasource = $null }) }

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 0 -Because $r.Output
        }

        It 'allows a folder and a dashboard to share a name (names are unique per kind)' {
            Write-FolderFile $script:dir 'platform'
            $sub = Join-Path $script:dir 'dashboards'
            New-Item -ItemType Directory -Path $sub | Out-Null
            Write-DashboardFile $sub 'platform'

            $r = Invoke-Push '-ValidateOnly'

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '2 resource file\(s\) valid \(1 dashboard\(s\)\)'
        }

        It 'reports every problem with a total and pushes nothing' {
            Write-DashboardFile $script:dir 'rootless' -Folder '' -Spec @{ id = 7 }

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match '2 problem\(s\) - nothing pushed'
            Get-GcxCall | Should -HaveCount 0
        }
    }

    Context 'drift guard and push' {
        BeforeEach {
            Write-FolderFile $script:dir 'platform'
            Write-DashboardFile $script:dir 'api-overview'
            Write-DashboardFile $script:dir 'orders'
        }

        It 'pushes when no dashboard was edited by a human since the last push, passing the context' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'api-overview' = 'service-account:ci'; 'unrelated' = 'user:abc' }
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push @('-Context', 'staging')

            $r.Exit | Should -Be 0 -Because $r.Output
            $calls = @(Get-GcxCall)
            # gcx get pages at 50 items by default - without --limit 0 the guard misses dashboards 51+
            $calls[0] | Should -Match '^--context staging resources get dashboards --limit 0 -o json$'
            # --omit-manager-fields: no grafana.app/sourcePath = absolute runner path on every dashboard
            $calls[1] | Should -Match "^--context staging resources push -p .+ --omit-manager-fields -o json$"
            $r.Output | Should -Match 'pushed 3 resource\(s\)'
        }

        It 'omits --context when none is given (CI: GRAFANA_SERVER / GRAFANA_TOKEN)' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            (Invoke-Push).Exit | Should -Be 0
            (Get-GcxCall)[0] | Should -Match '^resources get dashboards'
        }

        It 'refuses to overwrite a dashboard last saved by a human' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7'; 'api-overview' = 'service-account:ci' }

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'orders: last saved by user:ag08ln7'
            Get-GcxCall | Should -HaveCount 1
        }

        It 'names the -AcceptDrift token and an ISO timestamp in the drift message' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7' }

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match '-AcceptDrift orders@1791140827377994'
            $r.Output | Should -Match 'at 2026-10-01T10:00:00'
        }

        It 'pushes when the human-saved remote content equals the repo file (merged as-is or adopted)' {
            # a push of identical content is a no-op in Grafana, so updatedBy would stay user:... forever -
            # equal content means nothing can be lost (verified live by the round-3 review)
            $local = Get-Content -LiteralPath (Join-Path $script:dir 'orders.json') -Raw | ConvertFrom-Json -AsHashtable
            $remoteSpec = [ordered]@{}
            foreach ($k in ($local.spec.Keys | Sort-Object -Descending)) { $remoteSpec[$k] = $local.spec[$k] }   # key order differs
            $env:FAKE_GCX_GET = @{ items = @(@{ kind = 'Dashboard'; spec = $remoteSpec; metadata = @{ name = 'orders'; resourceVersion = '9'
                            annotations = @{ 'grafana.app/updatedBy' = 'user:a'; 'grafana.app/folder' = 'platform' } } }) } | ConvertTo-Json -Depth 20
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'DRIFT orders:'
            # the push is a no-op, so the human stays the last editor: the next repo change would report DRIFT
            $r.Output | Should -Match 'WARN orders: identical to the repo but last saved by user:a'
        }

        It 'still reports drift when the human-saved remote differs only in its folder' {
            $local = Get-Content -LiteralPath (Join-Path $script:dir 'orders.json') -Raw | ConvertFrom-Json -AsHashtable
            $env:FAKE_GCX_GET = @{ items = @(@{ kind = 'Dashboard'; spec = $local.spec; metadata = @{ name = 'orders'; resourceVersion = '9'
                            annotations = @{ 'grafana.app/updatedBy' = 'user:a'; 'grafana.app/folder' = 'moved-in-ui' } } }) } | ConvertTo-Json -Depth 20

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'DRIFT orders'
        }

        It 'treats a dashboard created by a human and never saved again as drift' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'api-overview' = 'service-account:ci' } -CreatedOnly @{ 'orders' = 'user:ag08ln7' }

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'DRIFT orders: last saved by user:ag08ln7'
            $r.Output | Should -Match '-AcceptDrift orders@1791140827377995'
        }

        It 'accepts several comma-separated -AcceptDrift tokens through pwsh -File' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:a'; 'api-overview' = 'user:b' }
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push @('-AcceptDrift', 'orders@1791140827377994,api-overview@1791140827377994')

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'accepted drift on orders'
            $r.Output | Should -Match 'accepted drift on api-overview'
        }

        It 'rejects malformed -AcceptDrift tokens before calling gcx' {
            $r = Invoke-Push @('-AcceptDrift', 'orders@123,orders; Remove-Item x')

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'AcceptDrift token "orders; Remove-Item x"'
            Get-GcxCall | Should -HaveCount 0
        }

        It 'treats -AcceptDrift none as no tokens (pipeline parameter default)' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            (Invoke-Push @('-AcceptDrift', 'none')).Exit | Should -Be 0
        }

        It 'does not bind a stray second token to -Context (no positional parameters)' {
            $r = Invoke-Push @('-AcceptDrift', 'orders@1', 'api-overview@2')

            $r.Exit | Should -Not -Be 0
            Get-GcxCall | Should -HaveCount 0
        }

        It 'pushes a merged UI edit when -AcceptDrift names the current resourceVersion' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7'; 'api-overview' = 'service-account:ci' }
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push @('-AcceptDrift', 'orders@1791140827377994')

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'accepted drift on orders'
        }

        It 'refuses when the dashboard changed again after the accepted resourceVersion' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7' }

            $r = Invoke-Push @('-AcceptDrift', 'orders@1791140000000000')

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'DRIFT orders'
            Get-GcxCall | Should -HaveCount 1
        }

        It 'does not let -AcceptDrift for one dashboard cover another' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7'; 'api-overview' = 'user:zz' }

            $r = Invoke-Push @('-AcceptDrift', 'orders@1791140827377994')

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'DRIFT api-overview'
            $r.Output | Should -Not -Match 'DRIFT orders'
        }

        It 'pushes over human edits with -Force' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7' }
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push '-Force'

            $r.Exit | Should -Be 0 -Because $r.Output
            # no drift lookup (the named post-push verification still runs)
            (Get-GcxCall | Where-Object { $_ -match ' get dashboards --limit' }) | Should -HaveCount 0
        }

        It 'fails when gcx pushes fewer resources than the folder holds' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":0,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'pushed 0 of 3'
        }

        It 'fails and shows each gcx failure on a partial push (gcx exits 4)' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":2,"failed":1},"failures":[{"target":{"name":"orders"},"error":"403 Forbidden"}]}'
            $env:FAKE_GCX_STDERR = 'warn: 1 resource(s) failed to push'
            $env:FAKE_GCX_EXIT = '4'
            $env:FAKE_GCX_GET = '{"items":[]}'

            $r = Invoke-Push '-Force'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'ERROR \{.*403 Forbidden'
            $r.Output | Should -Match 'pushed 2 of 3'
        }

        It 'confirms after the push that every repo dashboard exists on the instance' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'
            $env:FAKE_GCX_MISSING = 'orders'   # gcx counted it as pushed, but it never landed

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            # gcx returns no items at all once one name is missing, so every name is listed
            $r.Output | Should -Match 'post-push get did not return: api-overview, orders'
            $r.Output | Should -Match 'no items when any requested name is missing'
            @(Get-GcxCall)[-1] | Should -Match 'resources get dashboards/(api-overview,orders|orders,api-overview) -o json$'
        }

        It 'accepts the bare-object answer gcx gives when a single dashboard is verified' {
            Remove-Item -LiteralPath (Join-Path $script:dir 'orders.json')
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":2,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 0 -Because $r.Output
            @(Get-GcxCall)[-1] | Should -Match 'resources get dashboards/api-overview -o json$'
        }

        It 'skips the post-push check on a dry run' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[],"dry_run":true}'
            $env:FAKE_GCX_MISSING = 'orders'

            (Invoke-Push '-DryRun').Exit | Should -Be 0
            @(Get-GcxCall) | Should -HaveCount 2
        }

        It 'reports empty gcx output as an error instead of crashing' {
            $env:FAKE_GCX_GET = ''

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'gcx resources get returned no JSON'
            $r.Output | Should -Not -Match 'null array'
        }

        It 'fails when gcx itself fails' {
            $env:FAKE_GCX_EXIT = '1'

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'gcx resources get failed'
        }

        It 'keeps its own gcx error reporting when the caller set $PSNativeCommandUseErrorActionPreference' {
            # in-process call (as in an Azure DevOps `pwsh:` step) with the preference noobit:simple-scripts
            # recommends; `pwsh` stands in for a native gcx that exits non-zero (64: unknown arguments)
            $cmd = "`$PSNativeCommandUseErrorActionPreference = `$true; & '$($script:Push)' -Path '$($script:dir)' -Gcx pwsh"
            $output = & pwsh -NoProfile -Command $cmd 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 1
            $output | Should -Match 'ERROR gcx resources get failed \(exit \d+\)'
            $output | Should -Not -Match 'NativeCommandExitException'
        }

        It 'shows what gcx wrote to stderr when it fails' {
            $env:FAKE_GCX_EXIT = '1'
            $env:FAKE_GCX_STDERR = 'Get https://grafana.example.com/api: no such host'

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'no such host'
        }

        It 'ignores stderr noise when gcx succeeds' {
            $env:FAKE_GCX_STDERR = 'hint: use --json'
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            (Invoke-Push).Exit | Should -Be 0
        }

        It 'passes --dry-run through' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[],"dry_run":true}'

            (Invoke-Push '-DryRun').Exit | Should -Be 0
            (Get-GcxCall)[1] | Should -Match '--dry-run'
        }

        It 'says dry run and names the context in the success line' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push @('-DryRun', '-Context', 'staging')

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'pushed 3 resource\(s\) \(dry run\) to context staging'
        }

        It 'prints an ISO timestamp for a dashboard created by a human and never saved again' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{} -CreatedOnly @{ 'orders' = 'user:ag08ln7' }

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'orders: last saved by user:ag08ln7 at 2026-10-01T09:00:00Z'
        }

        It 'pushes when a human created the dashboard but the pipeline saved it since' {
            $env:FAKE_GCX_GET = @{ items = @(@{ kind = 'Dashboard'; metadata = @{ name = 'orders'; resourceVersion = '5'; annotations = @{
                                'grafana.app/createdBy' = 'user:ag08ln7'; 'grafana.app/updatedBy' = 'service-account:ci' } } }) } | ConvertTo-Json -Depth 10
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Not -Match 'DRIFT'
        }

        It 'pushes when remote dashboards carry no annotations or gcx lists no items' -ForEach @(
            @{ Get = '{"items":[{"kind":"Dashboard","metadata":{"name":"orders","resourceVersion":"5"}}]}' }
            @{ Get = '{}' }
        ) {
            $env:FAKE_GCX_GET = $Get
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 0 -Because $r.Output
        }

        It 'trims whitespace and ignores empty entries in -AcceptDrift' {
            $env:FAKE_GCX_GET = Get-RemoteJson @{ 'orders' = 'user:ag08ln7' }
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'

            $r = Invoke-Push @('-AcceptDrift', ' orders@1791140827377994 , ,')

            $r.Exit | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match 'accepted drift on orders'
        }

        It 'rejects the -AcceptDrift token "<Token>" before calling gcx' -ForEach @(
            @{ Token = 'orders' }
            @{ Token = 'orders@' }
            @{ Token = 'orders@v12' }
            @{ Token = '@123' }
            @{ Token = "$('a' * 41)@123" }
        ) {
            $r = Invoke-Push @('-AcceptDrift', $Token)

            $r.Exit | Should -Be 1
            $r.Output | Should -Match ([regex]::Escape("AcceptDrift token `"$Token`""))
            Get-GcxCall | Should -HaveCount 0
        }

        It 'fails when gcx push itself fails' {
            $env:FAKE_GCX_GET = '{"items":[]}'
            $env:FAKE_GCX_EXIT = '1'
            $env:FAKE_GCX_STDERR = 'push: 401 Unauthorized'

            $r = Invoke-Push '-Force'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'gcx resources push failed \(exit 1\).*401 Unauthorized'
        }

        It 'treats exit 4 from gcx get as a failure (partial success is only tolerated for push)' {
            $env:FAKE_GCX_EXIT = '4'

            $r = Invoke-Push

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'gcx resources get failed \(exit 4\)'
            Get-GcxCall | Should -HaveCount 1
        }

        It 'reports non-object push output (<Case>) as an error' -ForEach @(
            @{ Case = 'plain text'; Push = 'pushed everything' }
            @{ Case = 'a JSON array'; Push = '[1,2,3]' }
        ) {
            $env:FAKE_GCX_PUSH = $Push

            $r = Invoke-Push '-Force'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match 'gcx resources push returned no JSON'
        }

        It 'fails when the push summary does not add up (<Case>)' -ForEach @(
            @{ Case = 'more successes than files'; Push = '{"summary":{"succeeded":4,"failed":0},"failures":[]}'; Expect = 'pushed 4 of 3' }
            @{ Case = 'all succeeded but failures reported'; Push = '{"summary":{"succeeded":3,"failed":1},"failures":[]}'; Expect = 'pushed 3 of 3 resource file\(s\), 1 failed' }
            @{ Case = 'no summary'; Push = '{"failures":[]}'; Expect = 'pushed 0 of 3' }
        ) {
            $env:FAKE_GCX_PUSH = $Push

            $r = Invoke-Push '-Force'

            $r.Exit | Should -Be 1
            $r.Output | Should -Match $Expect
        }

        It 'resolves a relative -Path to an absolute folder for gcx push' {
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":3,"failed":0},"failures":[]}'
            $leaf = Split-Path $script:dir -Leaf
            Push-Location (Split-Path $script:dir -Parent)
            try {
                $output = & pwsh -NoProfile -File $script:Push -Path $leaf -Gcx $script:FakeGcx -Force 2>&1 | Out-String
                $exit = $LASTEXITCODE
            }
            finally { Pop-Location }

            $exit | Should -Be 0 -Because $output
            @(Get-GcxCall)[0] | Should -BeLike "resources push -p $script:dir *"
        }
    }

    Context 'folders only' {
        It 'skips the drift guard when there are no dashboards to protect' {
            Write-FolderFile $script:dir 'platform'
            $env:FAKE_GCX_PUSH = '{"summary":{"succeeded":1,"failed":0},"failures":[]}'

            $r = Invoke-Push

            $r.Exit | Should -Be 0 -Because $r.Output
            $calls = @(Get-GcxCall)
            $calls | Should -HaveCount 1
            $calls[0] | Should -Match '^resources push '
        }
    }
}
