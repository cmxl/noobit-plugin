# Dashboards as code — git → gcx → Grafana

Verified live (October 2026) with gcx 1.4.0 against Grafana 13.2.3, on Windows and in a Linux CI-like
container. That covers pull/push round-trips, contexts, CI env vars, folder-scoped tokens, drift from
a real browser save, and file provisioning.

## Contents

1. [The loop](#1-the-loop)
2. [Repo layout and resource format](#2-repo-layout-and-resource-format)
3. [gcx setup](#3-gcx-setup)
4. [Authoring a dashboard](#4-authoring-a-dashboard)
5. [Pushing: push-dashboards.ps1](#5-pushing-push-dashboardsps1)
6. [CI (Azure DevOps)](#6-ci-azure-devops)
7. [File provisioning instead of push](#7-file-provisioning-instead-of-push)
8. [Drift, deleting, renaming](#8-drift-deleting-renaming)
9. [Alternatives and the legacy API](#9-alternatives-and-the-legacy-api)

## 1. The loop

```
dev Grafana (local compose, same datasource uids)
   │  edit in the UI, or edit JSON
   ▼
gcx resources pull dashboards/<uid> -p grafana/resources     ← writes the resource file
   │  git diff → review → PR (CI: push-dashboards.ps1 -ValidateOnly)
   ▼
main → CI: push-dashboards.ps1 -> staging → (approval) → prod
           validate · drift guard · gcx push · count check
```

Staging and prod are never edited in the browser. An urgent fix happens in dev or in the JSON and goes
through the same pipeline. `"editable": false` is only a UI hint ("Make editable" is one click away);
what actually stops edits is **folder permissions**. Grafana's default on a new folder is
*Viewer role → View, Editor role → Edit*, plus Admin for the creator (verified). So, on every managed
folder in staging/prod:
- remove the *Editor role → Edit* entry, or keep people at org role Viewer;
- grant teams **View**;
- keep **Edit/Admin** only for the deploy service account and the instance admins.

Do it in *Dashboards → folder → Permissions* once per instance, as part of instance setup.

## 2. Repo layout and resource format

```
grafana/
  provisioning/…                                   # self-hosting.md
  resources/                                       # what CI pushes — exactly what gcx pull writes
    folders.v1.folder.grafana.app/
      platform.json
    dashboards.v1.dashboard.grafana.app/
      aspnetcore-red.json
      orders-overview.json
tools/grafana/push-dashboards.ps1                  # copied from this skill's scripts/
```

Keep gcx's own `<resource>.<version>.<group>/` folders: `gcx resources pull -p grafana/resources`
then updates files in place, and content round-trips unchanged. The push script searches the tree
recursively and requires each file name to equal `metadata.name`. **A push writes a new version
whenever the file differs from the stored spec**, and hand-written files lacking the server's
defaults always differ (verified; a freshly pulled file doesn't). So push on change (path-filtered
trigger), never on a timer, or the version history (20 kept by default) fills with no-ops. Pulling
once after the first push makes files stable.

A dashboard file:

```json
{
  "apiVersion": "dashboard.grafana.app/v1",
  "kind": "Dashboard",
  "metadata": {
    "name": "orders-overview",
    "annotations": { "grafana.app/folder": "platform" }
  },
  "spec": {
    "title": "Orders overview",
    "editable": false,
    "schemaVersion": 42,
    "tags": ["orders", "managed"],
    "templating": { "list": [] },
    "panels": []
  }
}
```

- `metadata.name` **is** the dashboard uid (URL `/d/<uid>`). Choose it once, ≤ 40 chars
  `[A-Za-z0-9_-]`, readable (`orders-overview`), never reused.
- `grafana.app/folder` holds the **folder uid**. The folder is its own file:
  `{"apiVersion":"folder.grafana.app/v1","kind":"Folder","metadata":{"name":"platform"},"spec":{"title":"Platform"}}`.
  Nested folders get a `grafana.app/folder` annotation pointing at their parent.
- `metadata.namespace` (written by pull) is ignored on push. The target context decides (`default`,
  `org-<id>`, `stacks-<id>`).
- `spec` is the classic dashboard JSON **without** `id` and `version` (the instance owns those).
- **API version = what the instance stores.** Pull doesn't convert, and all versions push fine. What
  decides the stored version (verified on 13.2):
  - A dashboard **created in the 13.x UI** is stored as **v2** (the server prefers v2, i.e. dynamic
    dashboards), with an `elements`/`layout` spec. Adopting one by pull yields a v2 file, and the
    script's classic datasource checks don't apply to it.
  - A **UI save of an existing dashboard keeps** its stored version (a v1 dashboard stays v1).
  - A save through the **legacy `/api`** (old scripts, curl) stores it as **`v0alpha1`**, and later
    v1 pushes don't change it back. The next pull then lands in another version folder next to the
    old file. Delete the stale twin; the script's duplicate check catches it.

  Author new dashboards as `v1` (classic JSON) unless you need v2 layouts (tabs, auto-grid). Classic
  format is what ≤ 12.4 instances and grafana.com accept, and the docs warn that a dashboard
  migrated to v2 can't be reverted in the UI.

### Getting a dashboard into the repo

Pick the first case that applies:

1. **It exists on an instance → pull it.** Run
   `gcx resources pull dashboards/<uid> -p grafana/resources --context <env>`. The pulled file *is*
   the repo file: clean metadata, folder annotation, the live content including every UI edit. When
   adopting a dashboard that people edited, this is the base. Apply your change on top of it, never
   on top of an older export. **Adopt with at least one real spec change**, normally
   `"editable": false` (managed dashboards ship read-only) or a `managed` tag. That first push needs
   `-AcceptDrift` (§8), and afterwards the pipeline's account is the last editor. Committed byte-for-byte
   unchanged, the push is a no-op: it passes, because the guard only fires when a human saved last
   **and** the content differs. But the human stays the last editor, so the next ordinary repo change
   reports DRIFT once (the script warns about this, verified).
2. **Only a UI export is at hand.** Grafana 13's *Export → Export as code* offers the models
   **Classic** and **V2 Resource** (JSON/YAML), plus the "Share dashboard with another instance"
   toggle; there's no v1 resource. Keep the toggle **off**.
   - *V2 Resource*: shrink `metadata` to `name` plus
     `annotations: { "grafana.app/folder": "<folder uid>" }`. The export carries server fields
     (`uid`, `resourceVersion`, `generation`, `createdBy`…) and **no folder annotation**. A stale
     `resourceVersion` does not protect anything: gcx overwrites anyway (verified).
   - *Classic*: wrap it with the snippet below.
3. **An old "shared externally" file is in the repo** (`__inputs`, `${DS_PROMETHEUS}`): wrap it with
   the snippet below and map each placeholder to the provisioned uid.

```powershell
# classic dashboard JSON → resource file; maps ${DS_*} placeholders to provisioned datasource uids
$map = @{ DS_PROMETHEUS = 'prometheus'; DS_LOKI = 'loki' }      # placeholder name → uid
$folder = 'platform'                                            # folder uid (see below)
$json = Get-Content dashboards/orders.json -Raw
foreach ($k in $map.Keys) { $json = $json.Replace("`${$k}", $map[$k]) }
if ($json -match '\$\{DS_[A-Z0-9_]+\}') { throw "unmapped placeholder $($Matches[0])" }
$d = $json | ConvertFrom-Json -AsHashtable -Depth 100
foreach ($k in 'id', 'version', '__inputs', '__requires', '__elements') { $d.Remove($k) }
$d.editable = $false
$doc = [ordered]@{
    apiVersion = 'dashboard.grafana.app/v1'; kind = 'Dashboard'
    metadata   = [ordered]@{ name = $d.uid; annotations = @{ 'grafana.app/folder' = $folder } }
    spec       = $d
}
$doc | ConvertTo-Json -Depth 100 | Set-Content "grafana/resources/dashboards.v1.dashboard.grafana.app/$($d.uid).json"
```

**Finding uids:**
- Folders: `gcx resources get folders --context <env>` (`metadata.name` is the uid) or the folder URL
  `/dashboards/f/<uid>/`.
- Datasources: `gcx resources get datasources --context <env>` or the edit URL
  `/connections/datasources/edit/<uid>`.

Provisioned uids are the same everywhere (self-hosting.md §4). Run `push-dashboards.ps1 -ValidateOnly`
after converting.

## 3. gcx setup

gcx is Grafana's official CLI (replaces grafanactl). It talks to the `/apis` endpoints and keeps
tokens in the OS keychain. Agent mode (JSON output) switches on automatically when Claude Code runs
it. It's built for Grafana 13+. Its README calls 12.x "not actively supported" (most features work,
security patches only), and it doesn't work for ≤ 11 (legacy API below).

Install a pinned version and verify the checksum. Release assets:
`gcx_<v>_{linux,darwin}_{amd64,arm64}.tar.gz` and `gcx_<v>_windows_{amd64,arm64}.zip`, with the binary
`gcx` at the archive root, plus `gcx_<v>_checksums.txt`.

```powershell
$v = '1.4.0'; $base = "https://github.com/grafana/gcx/releases/download/v$v"
Invoke-WebRequest "$base/gcx_${v}_windows_amd64.zip" -OutFile gcx.zip
Invoke-WebRequest "$base/gcx_${v}_checksums.txt" -OutFile checksums.txt
$expected = ((Get-Content checksums.txt) -match " gcx_${v}_windows_amd64.zip$" -split '\s+')[0]
if ((Get-FileHash gcx.zip -Algorithm SHA256).Hash -ne $expected) { throw 'gcx checksum mismatch' }
Expand-Archive gcx.zip -DestinationPath "$env:LOCALAPPDATA\Programs\gcx" -Force   # then add that folder to PATH
```

```bash
v=1.4.0
curl -fsSLO "https://github.com/grafana/gcx/releases/download/v${v}/gcx_${v}_linux_amd64.tar.gz"
curl -fsSLO "https://github.com/grafana/gcx/releases/download/v${v}/gcx_${v}_checksums.txt"
grep " gcx_${v}_linux_amd64.tar.gz\$" "gcx_${v}_checksums.txt" | sha256sum -c -
tar -xzf "gcx_${v}_linux_amd64.tar.gz" -C ~/.local/bin gcx
```

One **stack + context per instance**; the token goes to the keychain, the file keeps only a reference:

```bash
gcx config set stacks.staging.grafana.server https://grafana-staging.example.com
gcx config set stacks.staging.grafana.org-id 1
read -rs GCX_TOKEN && gcx config set stacks.staging.grafana.token "$GCX_TOKEN"; unset GCX_TOKEN   # stored as keychain:gcx:…
gcx config set contexts.staging.stack staging
gcx config check --context staging      # connectivity + version; non-zero exit = broken
```

(Same for `prod` and `dev`.) Don't commit a `.gcx.yaml` with tokens. A repo-level `.gcx.yaml` may
hold servers only. In CI there is no config file: `GRAFANA_SERVER`, `GRAFANA_TOKEN` and
`GRAFANA_ORG_ID` are enough (verified).

**Service account per instance:** *Administration → Users and access → Service accounts*, role
**Editor**. Least privilege, verified: role **None** plus **Edit** permission on each managed folder.
It can create/update dashboards there and gets 403 elsewhere. It also gets 403 creating a new
top-level folder (verified), so an admin pre-creates the folders, or that folder's file is pushed once
with an Editor token. Create a token with an expiry. Basic auth is off (self-hosting.md), so
tokens are the only API credential. Staging/prod **write** tokens live in the pipeline's variable
groups, not in developers' keychains. Developers get dev tokens plus, if needed, a read-only (Viewer)
token per environment for pulling. A drift acceptance runs through the pipeline (§8).

## 4. Authoring a dashboard

1. Run the dev Grafana (self-hosting.md §10) with the same datasource uids as production.
2. Start from [../templates/aspnetcore-red.json](../templates/aspnetcore-red.json) or an existing file.
   Push it to dev: `pwsh tools/grafana/push-dashboards.ps1 -Path grafana/resources -Context dev -Force`
   (`-Force` because in dev you *do* edit in the UI).
3. Edit in the UI ("Make editable", since managed dashboards ship with `editable: false`) and save.
4. Pull it back:
   `gcx resources pull dashboards/orders-overview -p grafana/resources --context dev`.
5. Review the diff. Put `"editable": false` back if the UI flipped it, and check that the datasource
   uids are still the provisioned ones (not a dev-only uid). Apply the review checklist in
   dashboard-design.md.
6. Commit and open a PR. CI runs `-ValidateOnly`; after merge it pushes to staging, then prod.

Small edits (a query, a threshold) can go straight into the JSON. To see the result, push it to dev.

## 5. Pushing: push-dashboards.ps1

Copy [../scripts/push-dashboards.ps1](../scripts/push-dashboards.ps1) to `tools/grafana/` (pwsh 7.2+,
gcx on PATH):

```bash
pwsh -NoProfile -File tools/grafana/push-dashboards.ps1 -Path grafana/resources -ValidateOnly        # PR check, offline
pwsh -NoProfile -File tools/grafana/push-dashboards.ps1 -Path grafana/resources -Context staging     # local, keychain token
pwsh -NoProfile -File tools/grafana/push-dashboards.ps1 -Path grafana/resources                      # CI: GRAFANA_* env vars
pwsh -NoProfile -File tools/grafana/push-dashboards.ps1 -Path grafana/resources -Context dev -Force  # overwrite UI edits deliberately
```

What it guarantees (each one is a real gcx/Grafana behaviour that bit during verification):

| Check | Why |
|---|---|
| Every `*.json` is a Dashboard (any `dashboard.grafana.app` version) or Folder resource | gcx skips anything else **silently and exits 0** |
| File name = `metadata.name`, valid uid, no duplicates | A pull into a new version folder leaves a stale twin; uid rules |
| `grafana.app/folder` on dashboards | No dashboards in General; folder permissions only work on folders |
| No `__inputs`/`__requires`/`__elements`, no `${DS_*}` | External-sharing exports produce panels without a datasource |
| No `spec.id`; `spec.uid` = `metadata.name` | The legacy save path rejects a foreign id (400) |
| Classic specs: datasources as `{type, uid}` or `$variable`, not names | Names differ per instance |
| **Drift guard:** remote `grafana.app/updatedBy` (or `createdBy` if never re-saved) starting with `user:` **and** remote spec/folder ≠ the repo file blocks the push; `get` uses `--limit 0` | gcx push is last-write-wins. A browser save sets `updatedBy: user:…`; pipeline pushes set `createdBy`/`updatedBy` to `service-account:…`. A dashboard created in the UI has only `createdBy`. `gcx resources get` stops at 50 items unless told otherwise (all verified) |
| Only JSON under `-Path`; YAML is rejected | gcx would push YAML resources too, unvalidated and unguarded (`gcx resources pull` writes JSON by default) |
| `--omit-manager-fields` on push | Otherwise gcx stamps `grafana.app/sourcePath` = the runner's absolute file path (user names, agent paths) on every dashboard |
| gcx reports exactly N successes for N files, 0 failures | Partial failures (403 on one folder) and silent skips fail the build |
| After the push, a named `get` confirms every repo dashboard exists | One review saw gcx count a dashboard as pushed that never reached the server (not reproduced). The counter alone isn't proof |
| Only `Dashboard`/`Folder` kinds, case-sensitive | Other kinds (LibraryPanel, DataSource from a broad pull) are named and must move out of `-Path` |

Exit code 0 = everything pushed, 1 = nothing or not everything pushed. The message names the files or
dashboards.

## 6. CI (Azure DevOps)

Follows `noobit:ci-pipelines`: PR validation through branch policy, deployment jobs on environments
with approvals, secrets from a variable group mapped via `env:`. Tokens live in the variable groups
`grafana-staging` / `grafana-prod` (`GRAFANA_TOKEN` as a secret, `GRAFANA_SERVER` = the public
`root_url`, because `enforce_domain` 301s any other host).

```yaml
# grafana-dashboards.yml — or a stage in the app pipeline
trigger:
  branches: { include: [main] }
  paths: { include: [grafana/resources, tools/grafana] }

pool: { vmImage: ubuntu-24.04 }   # pwsh is preinstalled

parameters:
- name: environments
  type: object
  default: [staging, prod]        # stages are generated in this order; each waits for the previous
- name: acceptDrift               # manual runs only: <uid>@<resourceVersion>[,…] printed by a DRIFT failure
  type: string
  default: none

variables:
  gcxVersion: 1.4.0

stages:
- stage: Validate
  jobs:
  - job: validate
    steps:
    - pwsh: ./tools/grafana/push-dashboards.ps1 -Path grafana/resources -ValidateOnly
      displayName: Validate dashboard resources

- ${{ each env in parameters.environments }}:
  - stage: push_${{ env }}
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
    - deployment: push
      environment: grafana-${{ env }}           # approvals/checks live on the environment
      variables:
      - group: grafana-${{ env }}               # GRAFANA_SERVER, GRAFANA_ORG_ID, secret GRAFANA_TOKEN
      strategy:
        runOnce:
          deploy:
            steps:
            - checkout: self
            - bash: |
                set -euo pipefail
                cd "$(Agent.TempDirectory)"
                curl -fsSLO "https://github.com/grafana/gcx/releases/download/v$(gcxVersion)/gcx_$(gcxVersion)_linux_amd64.tar.gz"
                curl -fsSLO "https://github.com/grafana/gcx/releases/download/v$(gcxVersion)/gcx_$(gcxVersion)_checksums.txt"
                grep " gcx_$(gcxVersion)_linux_amd64.tar.gz\$" "gcx_$(gcxVersion)_checksums.txt" | sha256sum -c -
                tar -xzf "gcx_$(gcxVersion)_linux_amd64.tar.gz" gcx
                echo "##vso[task.prependpath]$(Agent.TempDirectory)"
              displayName: Install gcx $(gcxVersion)
            - pwsh: ./tools/grafana/push-dashboards.ps1 -Path grafana/resources -AcceptDrift $env:ACCEPT_DRIFT
              displayName: Push dashboards to ${{ env }}
              env:
                GRAFANA_TOKEN: $(GRAFANA_TOKEN)     # secrets reach scripts only via env:
                ACCEPT_DRIFT: ${{ parameters.acceptDrift }}   # via env, never spliced into script text;
                                                              # the script accepts only <uid>@<digits> ('none' = no tokens)
```

Prod runs after staging succeeded (stage order plus the environment approval). Never hard-code
`-Force` or an `-AcceptDrift` token in the YAML. Accepting drift goes through the runtime parameter
`acceptDrift` (§8) on a manually queued run, behind the same environment approval, so prod tokens
never sit on laptops. **Folders:** with
folder-scoped tokens, an admin creates each managed folder once per instance (or pushes the folder
files once with an Editor token), and CI maintains the dashboards inside them. `-DryRun` (local
previews) keeps the count check meaningful: gcx reports dry-run resources as succeeded (verified). PR
builds stay offline (`-ValidateOnly`), because tokens belong only to the deployment stages
(`noobit:ci-pipelines` rule on secrets). A drift failure means a human decision: pull and merge the
UI edit, then queue the run with the printed token (§8).

## 7. File provisioning instead of push

For a single instance deployed from the same repo. Grafana reads the files, and the dashboards are
read-only in the UI:

```yaml
# grafana/provisioning/dashboards/repo.yaml
apiVersion: 1
providers:
  - name: repo
    type: file
    disableDeletion: false        # removing a file removes the dashboard
    allowUiUpdates: false         # UI save → "Cannot save provisioned dashboard"
    updateIntervalSeconds: 30     # > 10: polling (fs events are unreliable on bind mounts)
    options:
      path: /var/lib/grafana-dashboards
      foldersFromFilesStructure: true   # sub-folder name = Grafana folder (up to 4 levels)
```

Mount it in the compose service: `./grafana/dashboards:/var/lib/grafana-dashboards:ro`.
The files can be classic JSON or resource format (both verified) with these differences:

- **No `grafana.app/folder` annotation.** The provider decides the folder; a mismatching annotation
  makes Grafana reject the file ("dashboard folderUID … does not match provisioning provider folderUID").
- v2 dashboards must use the resource format.
- The API cannot save these dashboards (400). Don't point `push-dashboards.ps1` at a provisioned
  folder; it requires folder annotations precisely so the two modes don't mix.

## 8. Drift, deleting, renaming

- **Drift reported:**
  `DRIFT orders-overview: last saved by user:… at … - once merged: -AcceptDrift orders-overview@1791143025884999`.
  1. Pull that dashboard from the instance:
     `gcx resources pull dashboards/orders-overview -p grafana/resources --context prod-read`.
     Here `prod-read` is a context with a **Viewer** service-account token: it can pull, while a
     push gets 403 (verified). That's the only kind of prod token a laptop holds.
  2. Keep the UI change or drop it in the diff, re-apply your own change, then commit.
  3. Push with the printed token. Normally: queue the pipeline manually with
     `acceptDrift = orders-overview@1791143025884999` (several: comma-separated). Where a developer
     legitimately holds that environment's token (dev, or a short-lived break-glass account):
     `push-dashboards.ps1 -Path grafana/resources -Context prod -AcceptDrift orders-overview@1791143025884999`.
     The token pins the `resourceVersion` you pulled. If someone saved again since, the version
     differs and the push is refused (verified). That narrows the window to the seconds between the
     script's `get` and `push`; gcx itself has no compare-and-swap.
  4. CI pushes cleanly again. A changed file was written, so `updatedBy` is now the service account.
     If you kept the UI version exactly, the push was a no-op and `updatedBy` stays `user:…`. The guard
     passes because the content is identical (only a pulled file compares equal; the server adds defaults to hand-written specs, verified), and the script prints a `WARN`. The *next*
     repo change to that dashboard then reports DRIFT once and needs its token, though nobody touched
     the UI. Avoid it by including a real change (e.g. `"editable": false`) in the merge commit.

  Limit: the guard trusts every `service-account:…` identity as "the pipeline". A save made with some
  other service account (a personal one pointed at prod, say) isn't detected, so give staging/prod
  exactly one write-capable service account.

  `-Force` skips the guard for *all* dashboards. Keep it for deliberately discarding UI edits (dev
  instances). Grafana keeps version history, so even that is recoverable in
  *Dashboard settings → Versions*.
- **Delete:** gcx push never prunes. Remove the file *and* run
  `gcx resources delete dashboards/<uid> --context <env>` for every environment (or add a delete step
  to the pipeline that names the uids). Preview with `--dry-run`. A bare `gcx resources delete dashboards`
  without names refuses unless `--force`, and with it deletes everything, so never use that.
- **Rename the title:** edit `spec.title` freely. **Change the uid:** that's a new dashboard plus a
  delete of the old one, and it breaks bookmarks and links. Avoid it.
- **Move folders:** change the `grafana.app/folder` annotation. The target folder must exist in the
  repo or on the instance. A dashboard a *human* moved out of its managed folder (e.g. into General,
  where the deploy account has no access) is invisible to the drift `get`. It shows up as a 403 on
  push, not as DRIFT (verified). An admin moves it back, or pull it and re-annotate, then push.

## 9. Alternatives and the legacy API

- **Git Sync** (GA in 13; GitHub, GitHub Enterprise, GitLab, Bitbucket, plain Git): Grafana syncs a repo
  folder both ways (60 s polling by default, webhooks need a public instance) and can open PRs from UI
  saves. Choose it when the team wants UI authoring with PR review and the Git host is reachable from
  Grafana. Private hosts need `[provisioning] allowed_git_urls`. It replaces this push pipeline; don't
  run both on one folder.
- **Terraform provider:** when Grafana is already managed with Terraform; dashboards are then
  `grafana_dashboard` resources with `config_json = file(...)`.
- **Foundation SDK** (Go, TypeScript, Python, Java, PHP; no .NET) for generating many similar
  dashboards. Overkill for a handful of hand-made ones. Grafonnet isn't officially supported, and
  Grizzly is gone.
- **`gcx dev serve` / `gcx dev lint run <path>`**: `dev serve` previews local files. `dev lint run`
  (1.4.0) reported 0 violations even for invalid PromQL in v1 dashboards, so don't use it as a gate.
- **Legacy HTTP API** (Grafana ≤ 11 without gcx, or a one-off script). Deprecated since 13.0 but still
  works:

  ```
  POST /api/dashboards/db   {"dashboard": {<spec with uid, no id>}, "folderUid": "platform", "overwrite": true, "message": "…"}
  GET  /api/dashboards/uid/<uid>      → {"meta": {…, "provisioned": false, "version": n}, "dashboard": {…}}
  ```

  Verified on 13.2: a save without `overwrite` or with a stale `version` returns **409** "Dashboard
  already exists" (older docs say 412). A foreign `id` returns 400; a provisioned dashboard returns
  400. Omitting `folderUid` on update moves the dashboard to the root. Same title in the same folder
  is allowed now. New code targets `/apis/dashboard.grafana.app/v1/namespaces/<ns>/dashboards`
  (`PUT …/<uid>` with `metadata.resourceVersion` for optimistic concurrency, 409 on conflict), or just
  uses gcx.
