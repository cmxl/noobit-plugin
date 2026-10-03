---
name: ci-pipelines
description: Use when creating or fixing CI/CD for this stack in Azure DevOps YAML pipelines — multi-stage build/test/deploy, UseDotNet@2 + global.json, Cache@2 for NuGet/npm, Testcontainers on hosted agents, test results + coverage, BuildKit registry cache, EF migration gate + bundle, SSH deploy to a compose host, e2e stage, environments/approvals, variable groups/Key Vault, PR validation. Not for Dockerfiles (docker), test code or Azure PaaS deploys.
---

# CI pipelines — Azure DevOps YAML for the .NET + Angular + compose stack

## Overview

One YAML pipeline per app, in the repo (`azure-pipelines.yml`), three stages:

```
Build & test (every push + PR) ──► Image (main only) ──► Deploy (main, environment approval)
 restore/build/test, EF gate,       BuildKit build,        copy migration bundle → run it
 Angular tests, migration bundle    registry cache, push   → compose pull + up --wait
```

The pipeline never holds a production secret it doesn't need: the compose host keeps its own secret
files (`docker`), the pipeline only ships an image tag and a migration bundle. Azure DevOps is primary;
a GitHub Actions mapping is in the reference. **Never write an organization or project name into a
pipeline file or docs** — pipelines reference service connections, variable groups and environments
by their names inside the project.

Verified against learn.microsoft.com (Azure Pipelines tasks/YAML schema, pipeline caching, EF Core
applying migrations), docs.docker.com (registry cache, compose) and the hosted-image readme
(Ubuntu 24.04: Docker 28, Buildx, Compose, .NET 10 SDKs) in October 2026.

## The pipeline

```yaml
trigger:
  branches: { include: [main] }
# PRs: Azure Repos ignores `pr:` — add this pipeline as a *Build validation* branch policy on main.

variables:
  - group: app-ci                 # NON-secret values only (registryHost) — pipeline scope reaches PR builds
  - name: NUGET_PACKAGES
    value: $(Pipeline.Workspace)/.nuget/packages
  - name: npm_config_cache
    value: $(Pipeline.Workspace)/.npm
  - name: imageRepo
    value: $(registryHost)/app
  - name: imageTag
    value: $(Build.BuildId)

pool: { vmImage: ubuntu-24.04 }   # Linux: Testcontainers needs Linux containers; pin the image, not -latest

stages:
- stage: Build
  jobs:
  - job: ci
    steps:
    - task: UseDotNet@2
      inputs: { packageType: sdk, useGlobalJson: true }
    - task: Cache@2
      displayName: Cache NuGet
      inputs:
        key: 'nuget | "$(Agent.OS)" | **/packages.lock.json'
        restoreKeys: 'nuget | "$(Agent.OS)"'
        path: $(NUGET_PACKAGES)
    - script: dotnet restore App.slnx --locked-mode   # RID-less on purpose: <RuntimeIdentifiers>linux-x64;linux-arm64 in Directory.Build.props puts both RIDs in every graph; never restore -r (NU1004, rule 2)
    - script: dotnet build App.slnx -c Release --no-restore
    - script: dotnet tool restore                     # dotnet-ef from the repo's .config/dotnet-tools.json (aspnet-backend)
    - script: dotnet ef migrations has-pending-model-changes --project src/App.Infrastructure --startup-project src/App.Api --configuration Release --no-build   # dotnet ef: -c is --context — the configuration needs the long --configuration
      displayName: EF model has a migration
    - script: dotnet test --solution App.slnx -c Release --no-build --report-xunit-trx --coverage --coverage-output-format cobertura --results-directory $(Agent.TempDirectory)/TestResults
      displayName: .NET tests (Testcontainers)   # --coverage: EVERY test project needs Microsoft.Testing.Extensions.CodeCoverage (rule 4)
    - task: Cache@2
      displayName: Cache npm
      inputs:
        key: 'npm | "$(Agent.OS)" | web/package-lock.json'
        restoreKeys: 'npm | "$(Agent.OS)"'
        path: $(npm_config_cache)
    - script: npm ci
      workingDirectory: web
    - script: npx ng test --no-watch --no-progress --coverage --coverage-reporters cobertura --reporters junit --output-file test-results/unit-junit.xml
      workingDirectory: web
      displayName: Angular tests (Vitest)
    - task: PublishTestResults@2
      condition: succeededOrFailed()
      inputs: { testResultsFormat: VSTest, testResultsFiles: '$(Agent.TempDirectory)/TestResults/**/*.trx', testRunTitle: .NET }
    - task: PublishTestResults@2
      condition: succeededOrFailed()
      inputs: { testResultsFormat: JUnit, testResultsFiles: web/test-results/unit-junit.xml, testRunTitle: Angular }
    - script: find web/coverage -name cobertura-coverage.xml -exec cp {} $(Agent.TempDirectory)/TestResults/angular.cobertura.xml \;
      displayName: Collect Angular coverage next to the .NET files
    - task: PublishCodeCoverageResults@2      # one call: it merges every matching summary file
      inputs: { summaryFileLocation: '$(Agent.TempDirectory)/TestResults/**/*.xml' }   # trx files are *.trx
    - script: dotnet ef migrations bundle --self-contained -r linux-x64 -o $(Build.ArtifactStagingDirectory)/migrations/efbundle --project src/App.Infrastructure --startup-project src/App.Api --configuration Release
      displayName: Migration bundle (main only — what deploy runs)
      condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
      # the bundle restores for -r itself; MSBuild reads env vars as properties, so RestoreLockedMode
      # makes drift fail instead of silently rewriting a lock file (verified)
      env: { ASPNETCORE_ENVIRONMENT: Production, RestoreLockedMode: true }
    - script: dotnet ef migrations script --idempotent -o $(Build.ArtifactStagingDirectory)/migrations/migrations.sql --project src/App.Infrastructure --startup-project src/App.Api --configuration Release --no-build
      displayName: Idempotent script (review / DBA artifact — also on PRs, for the reviewer)
    - publish: $(Build.ArtifactStagingDirectory)/migrations
      artifact: migrations

- stage: Image
  dependsOn: Build
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
  jobs:
  - job: image
    steps:
    - task: Docker@2
      inputs: { command: login, containerRegistry: registry }   # Docker Registry service connection
    - script: docker buildx create --use --driver docker-container   # registry cache export needs a non-default driver
    - script: >-
        docker buildx build --platform linux/amd64 --push
        -t $(imageRepo):$(imageTag)
        --cache-from type=registry,ref=$(imageRepo):buildcache
        --cache-to type=registry,ref=$(imageRepo):buildcache,mode=max
        .
      displayName: Build + push (BuildKit, registry cache)

- stage: Deploy
  dependsOn: Image                  # add E2E here when the optional e2e stage is used (reference)
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
  # variables:                      # a SECRET group goes here — stage scope of a main-only stage, never
  # - group: app-deploy-secrets     # pipeline scope. This pipeline needs none: the host owns its secrets
  jobs:
  - deployment: production
    environment: production         # approvals, branch control, exclusive lock live on the environment
    strategy:
      runOnce:
        deploy:
          steps:
          - download: current
            artifact: migrations
          - task: CopyFilesOverSSH@0
            inputs: { sshEndpoint: compose-host, sourceFolder: $(Pipeline.Workspace)/migrations, contents: efbundle, targetFolder: /opt/app/migrations }
          - task: SSH@0
            inputs:
              sshEndpoint: compose-host
              runOptions: inline
              failOnStdErr: false   # docker reports progress on stderr; set -e fails on real errors
              inline: |
                set -euo pipefail
                cd /opt/app
                chmod +x migrations/efbundle
                export APP_TAG=$(imageTag)        # shell env beats .env: pull + migrate use the new tag
                docker compose pull app
                docker compose run --rm migrate   # fails → step fails, .env still names the old tag
                sed -i "s/^APP_TAG=.*/APP_TAG=$APP_TAG/" .env
                docker compose up -d --no-deps --wait app
```

Paths (`App.slnx`, `src/App.Api`, `src/App.Infrastructure`, `web/`), the `app-ci` group and the
`registry` / `compose-host` connection names are placeholders — adapt them; keep the shape.
Compose `migrate` service, host prerequisites, rollback, secrets and the GitHub Actions mapping:
**[references/azure-pipelines.md](references/azure-pipelines.md).**

## Rules

1. **One exact SDK everywhere.** `global.json` pins it (`"version": "10.0.401"`,
   `"rollForward": "latestPatch"`, plus `"test": { "runner": "Microsoft.Testing.Platform" }` — the
   `dotnet test --solution … --coverage` step above is MTP syntax; canonical block in `aspnet-backend`); CI uses `UseDotNet@2` + `useGlobalJson: true`; the Dockerfile's
   build stage uses the matching tag (`mcr.microsoft.com/dotnet/sdk:10.0.401`, `docker`). Implicit
   package versions follow the SDK, so a drifting SDK breaks `--locked-mode`. Renovate bumps
   `global.json` and the Dockerfile `FROM` tags in one grouped PR (its `nuget` manager reads
   `global.json`, the `dockerfile` manager the tags).
2. **Cache downloads, not outputs.** `NUGET_PACKAGES` keyed on `**/packages.lock.json`, npm's cache
   dir keyed on `package-lock.json`. Never cache `node_modules` with `npm ci` (it deletes it) or
   `bin/obj`. **Prerequisite — the repo must commit lock files** (`noobit:aspnet-backend` sets it up):
   `<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>` in `Directory.Build.props`
   (under central package management the lock files capture `Directory.Packages.props`),
   `<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>` in the same `Directory.Build.props` (all projects — the
   bundle and `publish -r`/`-a` build referenced libraries for the RID too, and a host-only setting lets that rewrite their
   lock files; verified), every
   `packages.lock.json` committed, and a `.config/dotnet-tools.json` manifest pinning `dotnet-ef`
   for `dotnet tool restore`. Without lock files the cache key matches nothing and `--locked-mode`
   has nothing to enforce. The restore is **always RID-less** — here and in the Dockerfile
   (`docker`): `RuntimeIdentifiers` makes a plain restore pull both RIDs' assets (runtime packs
   included) into the graph and the lock files, so the self-contained `migrations bundle -r linux-x64`
   and `publish -r <rid> --no-restore` (or the image's `publish -a $TARGETARCH`) find them without
   touching a lock file (Learn: "`RuntimeIdentifiers` is used at restore time to ensure the right
   assets are in the graph"; verified). Never `dotnet restore -r <rid> --locked-mode`: `-r` replaces
   the `RuntimeIdentifiers` list (two RIDs → one), so every committed lock file mismatches → NU1004
   (verified). A lock-file change in CI means someone forgot to commit one — run `dotnet restore`
   locally and commit the diff.
3. **Integration tests run in CI, with real containers.** Microsoft-hosted Ubuntu agents ship a running
   Docker engine — Testcontainers works with no setup; Windows agents can't run Linux containers.
   Hosted agents have 2 cores / 7 GB RAM / ~10 GB free disk: pin slim images, avoid running SQL
   Server *and* Postgres in one job. Never skip integration tests because "CI has no Docker".
4. **Publish results even on failure** (`condition: succeededOrFailed()`); one
   `PublishCodeCoverageResults@2` call for all Cobertura files. Coverage is evidence, not a gate
   target (`dotnet-testing`). `--coverage` on a solution-wide `dotnet test` is passed to every test
   project: each one must reference `Microsoft.Testing.Extensions.CodeCoverage` (put it in
   `Directory.Build.props` for test projects), or that project rejects the unknown option and the run
   exits with code 5 (invalid command line).
5. **EF gate before anything ships:** `dotnet ef migrations has-pending-model-changes` fails the build
   when someone changed the model without a migration (since EF 9, `Migrate`/bundles would throw at
   deploy time instead). Build the **bundle** (what deploy runs) and the **idempotent script** (what a
   reviewer or DBA reads) from the same commit. Migrations run as a deploy step with a
   schema-privileged connection — never `Database.Migrate()` at app startup (`data-access`).
6. **Migrate before switching, and keep migrations backward compatible.** The old app version runs
   against the new schema between `migrate` and `up` (and on rollback): expand/contract —
   add columns/tables first, drop them a release later.
7. **BuildKit with a registry cache.** `--cache-to type=registry,…,mode=max` caches every stage
   (restore layers included) across ephemeral agents; the cache ref is a separate tag, never the
   image tag. Needs a `docker-container` builder. The Dockerfile's cache-friendly shape (`docker`)
   is what makes the cache hit.
8. **Immutable tags.** Deploy `:$(Build.BuildId)` (or the commit SHA) — never `:latest`. Rollback =
   previous tag in the host `.env` + `docker compose up -d --no-deps --wait app`.
9. **Gate production on the environment, not in YAML:** approvals, *Branch control* (only
   `refs/heads/main`), *Exclusive lock* — configured on the `production` environment by its owner.
10. **Secrets:** variable groups (Key Vault-linked for production secrets), authorized per pipeline;
    secret variables are not visible to scripts unless mapped via `env:`. No secrets in YAML, in
    `script:` text, or as `docker build --build-arg`. A **secret** variable group is linked only at
    the `variables:` of a main-only stage/job — pipeline-level groups reach PR builds. The compose
    host's runtime secrets stay in its `secrets/` files — the pipeline never needs them.
11. **PR validation = branch policy.** Build validation (required) + minimum reviewers on `main`;
    the PR build runs the Build stage only (Image/Deploy are main-only by condition).

## Common mistakes

| Mistake | Fix |
|---|---|
| `pr:` block in an Azure Repos pipeline "doesn't trigger" | Branch policy → Build validation |
| `UseDotNet@2` with a hard-coded `version` drifting from `global.json` | `useGlobalJson: true` |
| Cache key on `*.csproj` / no lock files | `RestorePackagesWithLockFile` + key on `**/packages.lock.json` |
| `--cache-to type=registry` with the default `docker` driver | `docker buildx create --use --driver docker-container` first |
| `Database.Migrate()` on startup "because the pipeline is simpler" | Bundle artifact + `docker compose run --rm migrate` |
| Bundle built in `Development` (loads user secrets / dev config) | `ASPNETCORE_ENVIRONMENT=Production` when building and running it |
| Integration tests on `windows-latest` | `ubuntu-24.04` — Linux containers |
| Connection strings / registry passwords in YAML or `inline:` scripts | Variable group (Key Vault) mapped via `env:`; host secret files for runtime secrets |
| `sed … APP_TAG … .env` before `run --rm migrate` | A failed migration leaves `.env` on the new tag — export the tag, migrate, then write `.env` |
| SSH port open to the world for the hosted agent | Restrict to Azure DevOps IP ranges, or a self-hosted agent inside the network |
| Deploying `:latest` | Build-id tag in the host `.env`; rollback by tag |

## Official docs — verify, don't guess

- YAML schema: https://learn.microsoft.com/azure/devops/pipelines/yaml-schema/
- Pipeline caching: https://learn.microsoft.com/azure/devops/pipelines/release/caching
- Tasks: `UseDotNet@2`, `Cache@2`, `PublishTestResults@2`, `PublishCodeCoverageResults@2`, `Docker@2`, `SSH@0`, `CopyFilesOverSSH@0` — https://learn.microsoft.com/azure/devops/pipelines/tasks/reference/
- Environments, approvals & checks: https://learn.microsoft.com/azure/devops/pipelines/process/environments · https://learn.microsoft.com/azure/devops/pipelines/process/approvals
- Variable groups / Key Vault: https://learn.microsoft.com/azure/devops/pipelines/library/link-variable-groups-to-key-vaults
- Hosted agents (software, limits): https://learn.microsoft.com/azure/devops/pipelines/agents/hosted
- EF Core applying migrations (bundles, scripts, pending-changes check): https://learn.microsoft.com/ef/core/managing-schemas/migrations/applying
- Docker registry cache: https://docs.docker.com/build/cache/backends/registry/
- Related skills: `docker` (Dockerfile, compose), `data-access` (migration strategy), `dotnet-testing` (MTP flags, Testcontainers), `frontend-testing` (Playwright e2e job).
