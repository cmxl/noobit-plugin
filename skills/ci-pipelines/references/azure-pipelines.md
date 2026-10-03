# Azure Pipelines — deploy details, secrets, templates, GitHub Actions mapping

Extends [../SKILL.md](../SKILL.md). Verified October 2026 against learn.microsoft.com (SSH@0,
CopyFilesOverSSH@0, deployment jobs, environments/approvals, variable groups, EF Core applying
migrations) and docs.docker.com (compose profiles, `compose up --wait`, registry cache).

## Compose host prerequisites (one-time, by an admin — not the pipeline)

- Docker Engine + Compose plugin; the stack lives in `/opt/app` with `compose.yaml` and a gitignored
  `.env` holding **non-secrets only**: `APP_TAG=` (the deployed image tag), `REGISTRY=` (registry host),
  `COMPOSE_PROFILES=prod`. Credentials live in `./secrets/*` files mounted as compose secrets (`docker`):
  `db_connection` (DML identity, for `app`), `db_schema_owner` (DDL identity, for `migrate`), and the
  database role passwords the init script reads.
- `docker login <registry>` with a **pull-only** credential (e.g. a repository-scoped token).
  The pipeline pushes with its own service connection; the host never gets push rights.
- A deploy user in the `docker` group, key-only SSH; its public key belongs to the private key in the
  `compose-host` SSH service connection. Use an **RSA** key pair — `SSH@0`/`CopyFilesOverSSH@0`
  document RSA (and DSA) as their supported key algorithms, not Ed25519/ECDSA:
  `ssh-keygen -t rsa -b 4096 -m PEM -f compose-host` (classic PEM private-key format, as in Microsoft's
  own RSA examples).
- SSH reachable only from where the agent runs: restrict the firewall to the Azure DevOps hosted-agent
  IP ranges (Microsoft-hosted agents docs → Agent IP ranges), or run a self-hosted agent inside the host's network and skip public SSH.

## Compose additions for deploys

```yaml
services:
  app:
    image: ${REGISTRY}/app:${APP_TAG}      # the pipeline only changes APP_TAG in .env
    # … rest of the app service from the docker skill (healthcheck, networks, secrets, logging) …
```

Plus the one-shot **`migrate`** service — defined once, in `data-access` →
references/migrations-ci.md → *Compose deployment* (app image + the pipeline's bundle bind-mounted from
`./migrations`, `profiles: [tools]`, `backend` network, schema-owner connection string as the
`db_schema_owner` secret file under the app's config key — never argv or `.env`). Don't redefine it here.

- `docker compose run --rm migrate` starts `db` if needed (depends_on), runs the bundle, removes the
  container, and fails the SSH step on a non-zero exit — `.env` still holds the old tag, nothing switched.
- The deploy sets the new tag only in the **shell environment** for `pull`/`migrate` (shell variables
  win over `.env` in compose interpolation) and writes it into `.env` only after the migration
  succeeded — see the deploy step in [../SKILL.md](../SKILL.md).
- The bundle uses EF's migration lock (EF 9+), so a parallel run can't corrupt the history table;
  the environment's *Exclusive lock* check stops parallel deploys earlier anyway.
- `docker compose up -d --no-deps --wait app` returns only when the new container is healthy (it
  needs the `HEALTHCHECK` from `docker`) and fails the step otherwise — `.env` then already names the
  new tag, so follow *Rollback* below. nginx answers 502 for the seconds the container is replaced
  (`docker` → Fast redeploy).

## Rollback

```bash
cd /opt/app
sed -i "s/^APP_TAG=.*/APP_TAG=<previous build id>/" .env
docker compose up -d --no-deps --wait app
```

Schema stays at the newer version — which is why migrations must be backward compatible
(expand/contract). Reverting a migration (`efbundle <older migration>`) is a deliberate, reviewed
operation, never an automatic rollback step: down-migrations can drop data.

## Idempotent script vs bundle

| Artifact | Use |
|---|---|
| `efbundle` | What the deploy runs — single executable, consistent transactions, migration lock |
| `migrations.sql` (`--idempotent`) | What a human reviews before approving; what a DBA applies by hand when the policy says so. Not covered by the migration lock |

If the bundle build complains about missing `linux-x64` assets, `Directory.Build.props` is missing
`<RuntimeIdentifiers>linux-x64;linux-arm64</RuntimeIdentifiers>` (`aspnet-backend`; all projects, not just the host): add it,
run `dotnet restore` locally and commit the updated `packages.lock.json` — the RID-less `dotnet restore
App.slnx --locked-mode` in CI (and in the Dockerfile) then restores both RIDs' assets too. Don't add
`-r linux-x64` to the restore instead: `-r` replaces the `RuntimeIdentifiers` list, so every
project's lock file mismatches and locked mode fails (NU1004, verified — SKILL.md rule 2). The RID
belongs only on the steps after the restore: `migrations bundle -r linux-x64`, `publish -r <rid> --no-restore`.

## Secrets and variables

- **Variable groups**, authorized per pipeline (Pipeline permissions), not "open access" when they hold
  secrets. Production secrets: link the group to **Azure Key Vault** (only secret names are mapped;
  values are fetched at run time).
- Secret variables are **not** exposed to scripts automatically — map them explicitly:
  `env: { E2E_PASSWORD: $(E2ePassword) }`. Never interpolate a secret into an `inline:` SSH script
  (macros are expanded into the script text that runs on the host).
- Restrict secret groups to protected branches: reference the group only in stages whose condition
  requires `refs/heads/main`, and put a *Branch control* check on the environment.
- Never pass secrets as `docker build --build-arg` (they persist in image history — `docker`); use
  BuildKit `--secret` if a build step truly needs one (e.g. a private NuGet feed).

## Private NuGet feed

On Ubuntu 24.04+ hosted images `NuGetCommand@2` isn't supported — authenticate the .NET CLI with
`NuGetAuthenticate@1` before `dotnet restore`. Inside a Docker build, pass the feed credential as a
BuildKit secret, not an ARG.

## Running e2e in the pipeline (optional stage)

The canonical e2e stack: the images that will be deployed, started with compose on the agent, with
only hostname, certificate and secrets swapped. Playwright side (setup project, fixtures, config):
`frontend-testing` → references/e2e-bff.md, which links here for the stack.

**`compose.e2e.yaml`** (committed, next to `compose.yaml`):

```yaml
services:
  app:
    environment:
      AllowedHosts: app.e2e.test;localhost  # the e2e hostname instead of the production one; localhost for the HEALTHCHECK
      # all e2e traffic reaches the app from one IP (nginx) — both production limits would 429 the
      # suite: the login limit (5 per 60 s per IP, bff-security) and the global per-user/IP limiter
      # (default 100 per window — static assets via MapStaticAssets and /api/me count too).
      # Raised here only; both limiters stay on.
      RateLimiting__Auth__PermitLimit: "1000"
      RateLimiting__Global__PermitLimit: "100000"
  migrate:
    environment:
      ASPNETCORE_ENVIRONMENT: E2E           # lets the app's UseSeeding create the e2e user (bundles run seeding)
      Seed__E2eUser: e2e@example.test
    secrets:
      - { source: e2e_password, target: Seed__E2ePassword }
  nginx:
    volumes:                                # same container paths as production → these mounts replace them
      - ./e2e/nginx:/etc/nginx/conf.d:ro    # production app.conf with server_name swapped (sed, below)
      - ./e2e/letsencrypt:/etc/letsencrypt:ro   # self-signed cert at live/app.e2e.test/{fullchain,privkey}.pem
secrets:
  e2e_password: { file: ./secrets/e2e_password }
```

Gitignore what the stage generates: `.env`, `secrets/`, `migrations/`, `e2e/nginx/`, `e2e/letsencrypt/`.
`Seed__*` and the seeding itself are app code (`UseSeeding`/`UseAsyncSeeding` gated on the `E2E`
environment) — never a test-only endpoint.

**The stage** (between Image and Deploy; add `E2E` to Deploy's `dependsOn` to gate production on it):

```yaml
- stage: E2E
  dependsOn: Image
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
  jobs:
  - job: e2e
    variables:
      compose: docker compose -f compose.yaml -f compose.e2e.yaml
    steps:
    - download: current
      artifact: migrations                  # → $(Pipeline.Workspace)/migrations/efbundle
    - task: Docker@2
      inputs: { command: login, containerRegistry: registry }
    - script: |
        set -eu
        cp -r "$(Pipeline.Workspace)/migrations" ./migrations && chmod +x migrations/efbundle
        printf 'REGISTRY=%s\nAPP_TAG=%s\n' "$(registryHost)" "$(imageTag)" > .env   # non-secrets only
        mkdir -p secrets e2e/nginx e2e/letsencrypt/live/app.e2e.test
        # throwaway credentials, generated per run (hex → no escaping inside connection strings)
        pg=$(openssl rand -hex 24); owner=$(openssl rand -hex 24); app=$(openssl rand -hex 24); e2e=$(openssl rand -hex 24)
        printf '%s' "$pg" > secrets/db_password
        printf '%s' "$owner" > secrets/db_owner_password
        printf '%s' "$app" > secrets/db_app_password
        printf 'Host=db;Database=app;Username=app_owner;Password=%s' "$owner" > secrets/db_schema_owner
        printf 'Host=db;Database=app;Username=app_user;Password=%s' "$app" > secrets/db_connection
        printf '%s' "$e2e" > secrets/e2e_password
        chmod 444 secrets/*                  # readable by the container users (app 1654, postgres 999)
        echo "##vso[task.setvariable variable=E2ePassword;issecret=true]$e2e"
        # the production nginx config, only the hostname swapped; cert where that config expects it.
        # PROD_HOST = your production server_name (the one in app.conf and the cert paths) - set it as a
        # pipeline variable; app.example.com is only the skill's placeholder
        conf=$(<nginx/conf.d/app.conf)                    # literal (non-regex) replacement
        printf '%s\n' "${conf//"$PROD_HOST"/app.e2e.test}" > e2e/nginx/app.conf
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=app.e2e.test" \
          -addext "subjectAltName=DNS:app.e2e.test" \
          -keyout e2e/letsencrypt/live/app.e2e.test/privkey.pem -out e2e/letsencrypt/live/app.e2e.test/fullchain.pem
        echo "127.0.0.1 app.e2e.test" | sudo tee -a /etc/hosts
      displayName: Prepare e2e stack (env, secrets, cert, hosts)
    - script: $(compose) pull app
      displayName: Pull the image that will be deployed
    - script: $(compose) run --rm migrate
      displayName: Migrate + seed (ASPNETCORE_ENVIRONMENT=E2E)
    - script: $(compose) up -d --wait nginx
      displayName: Start stack (nginx + its dependencies, no certbot)
    - script: npm ci && npx playwright install --with-deps chromium
      workingDirectory: web
    - script: npx playwright test
      displayName: E2E
      workingDirectory: web
      env: { CI: 'true', E2E_BASE_URL: 'https://app.e2e.test', E2E_USER: e2e@example.test, E2E_PASSWORD: $(E2ePassword) }
    - task: PublishTestResults@2
      condition: succeededOrFailed()
      inputs: { testResultsFormat: JUnit, testResultsFiles: web/test-results/e2e-junit.xml, testRunTitle: E2E }
    - publish: web/playwright-report
      artifact: playwright-report
      condition: failed()
    - script: $(compose) logs --no-color > $(Build.ArtifactStagingDirectory)/compose.log
      condition: failed()
    - publish: $(Build.ArtifactStagingDirectory)/compose.log
      artifact: e2e-compose-log
      condition: failed()
    - script: $(compose) down --volumes
      displayName: Tear down
      condition: always()
```

- No pipeline secrets needed: every credential is generated per run and dies with the agent;
  `E2ePassword` is set as a secret output variable (masked in logs) and mapped into Playwright's `env`.
- `up --wait nginx` targets nginx explicitly, which enables its `prod` profile for it alone — its
  dependencies (`app` → `db`, `redis`) start too, `certbot` doesn't (no ACME from an agent).
  `depends_on: condition: service_healthy` gates the start order (nginx starts only after `app` is
  healthy, `app` after `db`/`redis`); `--wait` then returns once every started service is healthy.
- The migration runs exactly as in production (`run --rm migrate`, schema-owner secret), so the
  e2e stage also proves the bundle against an empty database.

## Templates

When a second service gets a pipeline, move the job bodies into `templates/dotnet-ci.yml`,
`templates/image.yml`, `templates/deploy-compose.yml` with `parameters:` (paths, image name,
environment) and `extends`/`template:` them — copy-pasted pipelines drift. Keep templates in the
same repo until a second repo needs them.

## GitHub Actions equivalent (when the repo lives on GitHub)

| Azure Pipelines | GitHub Actions |
|---|---|
| `UseDotNet@2` + `useGlobalJson` | `actions/setup-dotnet` with `global-json-file: global.json` |
| `Cache@2` (NuGet / npm) | `actions/setup-dotnet` `cache: true` (lock files) / `actions/setup-node` `cache: npm` |
| `PublishTestResults@2` | A JUnit report action, or upload TRX/JUnit as artifacts (`--report-xunit-junit`) |
| BuildKit registry cache | `docker/setup-buildx-action` + `docker/build-push-action` with `cache-from/cache-to: type=registry` (or `type=gha`) |
| Environment approvals | GitHub environments with required reviewers |
| Variable groups / Key Vault | Environment secrets; Azure Key Vault via OIDC login |
| Branch policy build validation | Branch protection with required status checks |
| `SSH@0` | `ssh` from a step with the key from a secret (or a self-hosted runner on the host) |

Verify action inputs on the actions' own READMEs before use — this table is a map, not a spec.
