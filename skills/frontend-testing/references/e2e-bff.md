# Playwright e2e through the cookie BFF

Extends [../SKILL.md](../SKILL.md). Assumes the `bff-security` wiring: `GET /api/me` (anonymous → 401)
mints the readable `XSRF-TOKEN` cookie, `POST /api/auth/login` sets `__Host-session`, every
state-changing `/api` call validates the `X-XSRF-TOKEN` header. Verified against playwright.dev
(auth, api-testing, class-apirequest, test-use-options, ci) in October 2026.

## 1. Log in once — `e2e/auth.setup.ts`

API login, not UI: faster, and not coupled to the login form's markup (one separate UI test covers
the form). A standalone `request.newContext()` gets `ignoreHTTPSErrors` explicitly — the docs don't
promise that the `use` options reach a manually created context — from the same gated
`selfSignedTls` flag as the config (`e2e/env.ts`, SKILL.md), never a bare `true`.

```ts
import { test as setup, expect, request } from '@playwright/test';
import { selfSignedTls } from './env';

const authFile = 'playwright/.auth/user.json';   // gitignored: holds a live session cookie

setup('log in through the BFF', async ({ baseURL }) => {
  const api = await request.newContext({ baseURL, ignoreHTTPSErrors: selfSignedTls });

  // 1. anonymous /api/me → 401, but the antiforgery middleware still sets XSRF-TOKEN on it
  await api.get('/api/me');
  const xsrf = (await api.storageState()).cookies.find(c => c.name === 'XSRF-TOKEN')?.value;
  expect(xsrf, 'XSRF-TOKEN cookie from /api/me').toBeTruthy();

  // 2. log in with the header Angular's HttpClient would send (login is CSRF-protected too)
  const login = await api.post('/api/auth/login', {
    data: { email: process.env.E2E_USER, password: process.env.E2E_PASSWORD },
    headers: { 'X-XSRF-TOKEN': xsrf! },
  });
  expect(login.ok(), `login: ${login.status()}`).toBeTruthy();

  // 3. the login response re-issued XSRF-TOKEN for the new identity — save cookies after it
  await api.storageState({ path: authFile });
  await api.dispose();
});
```

- The antiforgery token is bound to the identity: a token minted while anonymous is rejected after
  login. That's why the state is saved **after** the login response (which carries a fresh token —
  `bff-security` sets `http.User` before the response starts).
- Credentials come from environment variables (pipeline secrets), never from the repo.
- Sessions expire (`ExpireTimeSpan`); the setup project re-runs on every `npx playwright test`, so a
  stale `user.json` from yesterday is never reused.
- **This is the run's one shared login.** The BFF's `"auth"` rate-limit policy (`bff-security`)
  allows 5 login attempts per minute per client IP, and in the e2e stack every request reaches the
  app through nginx from one IP. Every browser context and the `api` fixture reuse `user.json`;
  only the single UI login test and the few dedicated-user tests (§3 *Extra users*) call
  `/api/auth/login` again. Failed and retried attempts count too — hence the e2e-only raised limits
  in `compose.e2e.yaml` (§3), never a disabled limiter. The app's global per-user/IP limiter
  (`RateLimiting:Global:PermitLimit`, default 100 per window) is the second budget the suite would
  exhaust: every page load's static assets (`MapStaticAssets`) and `/api/me` count toward it too.

## 2. Seed through the API — `e2e/fixtures.ts`

```ts
import { test as base, request, type APIRequestContext } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import { selfSignedTls } from './env';

const authFile = 'playwright/.auth/user.json';

export const test = base.extend<{ api: APIRequestContext }>({
  // authenticated API client for arranging data; same session as the browser, plus the XSRF header
  api: async ({ baseURL }, use) => {
    const state = JSON.parse(await readFile(authFile, 'utf8')) as { cookies: { name: string; value: string }[] };
    const xsrf = state.cookies.find(c => c.name === 'XSRF-TOKEN')?.value ?? '';
    const api = await request.newContext({
      baseURL,
      storageState: authFile,
      ignoreHTTPSErrors: selfSignedTls,
      extraHTTPHeaders: { 'X-XSRF-TOKEN': xsrf },
    });
    await use(api);
    await api.dispose();
  },
});
export { expect } from '@playwright/test';
```

```ts
// e2e/orders.spec.ts
import { test, expect } from './fixtures';

test('a new order shows up in the list', async ({ page, api }) => {
  const reference = `E2E-${crypto.randomUUID()}`;                 // unique → parallel-safe, no cleanup races
  const created = await api.post('/api/orders', { data: { reference, quantity: 1 } });
  expect(created.ok()).toBeTruthy();

  await page.goto('/orders');
  await expect(page.getByRole('row', { name: new RegExp(reference) })).toBeVisible();
});
```

- `page.request` / `context.request` share the browser context's cookies (Playwright docs) — use
  them for calls *during* a test that must affect the page's session; they still need the
  `X-XSRF-TOKEN` header on POST/PUT/DELETE.
- Assert on what the user sees, then (optionally) verify persistence through the API — not by
  querying the database from the test.
- Never add a "test-only" seed endpoint to the production app. Base data (the e2e user, reference
  data) comes from a seed step against the e2e database: EF `UseSeeding` gated on the `E2E`
  environment, executed by the `migrate` job (`docker compose run --rm migrate` — bundles run seeding).

## 3. The stack under test

Same images as production, started with compose; only the hostname, certificate and secrets differ.
**The canonical stack definition — `compose.e2e.yaml`, generated secrets, self-signed cert, migrate +
seed, start, teardown — lives in `ci-pipelines` → references/azure-pipelines.md → *Running e2e in the
pipeline*.** Local runs: see *Running the stack locally* below. The Playwright-relevant facts:

- **HTTPS is required.** `__Host-` cookies are `Secure`. The nginx catch-all refuses the TLS
  handshake for an unknown SNI (`ssl_reject_handshake`; 444 only on port 80), so the test hostname
  must be a real `server_name`: `app.e2e.test` — set in the e2e nginx config (production `app.conf`
  with the hostname swapped), in the app's `AllowedHosts` (`compose.e2e.yaml`, next to `localhost` for the container healthcheck), and mapped to
  `127.0.0.1` on the machine running the tests (`/etc/hosts`).
- **Certificate:** a throwaway self-signed cert generated per run, mounted where the production config
  expects the Let's Encrypt files. That is what the gated `ignoreHTTPSErrors: selfSignedTls` is for — it
  is only true for a `.test` host or `E2E_SELF_SIGNED=1`, so a real environment keeps TLS validation.
- **Test user:** created by the `migrate` job's seeding in the `E2E` environment, with a password
  generated per run and handed to Playwright as `E2E_PASSWORD` — no long-lived e2e credential exists.
- **Both rate limits, raised for e2e only:** `compose.e2e.yaml` sets two values the suite can't
  exhaust. All test traffic shares one client IP behind nginx, so the production limits would 429:
  - `RateLimiting__Auth__PermitLimit` (binds `RateLimiting:Auth:PermitLimit`; production default 5
    per `RateLimiting:Auth:WindowSeconds` = 60) — the setup login's retries, the UI login test and
    the dedicated-user logins.
  - `RateLimiting__Global__PermitLimit` (binds `RateLimiting:Global:PermitLimit`; production default
    100 per `RateLimiting:Global:WindowSeconds`) — the global limiter partitions by user (signed in) or IP
    (anonymous), and e2e has one shared user and one nginx IP; every navigation's static assets (served through `MapStaticAssets`, so they
    pass the limiter) plus `/api/me` count, so a parallel suite burns 100 in seconds.

  Both limiters stay on (same code path as production); their 429 behavior is proven in the .NET
  integration tests (`dotnet-testing`), not in e2e. nginx's own `limit_req` on the login location
  (`nginx-deploy`) needs the same treatment in the e2e nginx conf.
- **Extra users:** tests that change the password, "log out everywhere" or revoke sessions need
  their own user (SKILL.md rule 6). Create them in the same `E2E` seeding — e.g. a fixed list
  `e2e-session-1@example.test`, … with the generated e2e password — and log each one in once via
  the API in its own `request.newContext()`/browser context. Never re-log-in the shared user, never
  create users through the registration UI per test.
- **Start and wait for health**, then test: `up -d --wait nginx`. `depends_on: condition:
  service_healthy` gates the start order (nginx waits for a healthy `app`, which waits for healthy
  `db`/`redis`), and `--wait` returns once every started service is healthy; certbot is not started.
- Locally against `ng serve`, proxy `/api` to the BFF with the dev-server proxy so the app stays
  same-origin; the BFF rules don't change.

### Running the stack locally

The pipeline's "Prepare" step doesn't run as-is outside Azure DevOps: it reads Azure macros
(`$(Pipeline.Workspace)`, `$(registryHost)`, `$(imageTag)`), emits a `##vso` logging command,
copies a migrations bundle built by an earlier stage and pulls a CI-built image, and Playwright's
`E2E_USER`/`E2E_PASSWORD` come from the job's `env:`. The local deltas (bash — WSL/Git Bash on
Windows, where the hosts entry goes into `C:\Windows\System32\drivers\etc\hosts`):

```sh
# 1. build what CI would have built (project paths/Dockerfile per repo)
docker build -t e2e.local/app:dev .
# same flags as the CI bundle step: Release + Production (never Development config / user secrets)
ASPNETCORE_ENVIRONMENT=Production dotnet ef migrations bundle --self-contained -r linux-x64 \
  -o migrations/efbundle --project src/App.Infrastructure --startup-project src/App.Api --configuration Release
# exported, not written to .env — your own .env (COMPOSE_FILE, …) stays untouched
export REGISTRY=e2e.local APP_TAG=dev
# 2. from the Prepare step, verbatim: the mkdir / openssl rand / printf secrets / chmod / sed / openssl req
#    lines — drop the cp, the .env printf and the ##vso line; add the hosts entry once
# 3. same compose commands as the stage, minus `pull app`
c="docker compose -f compose.yaml -f compose.e2e.yaml"
$c run --rm migrate && $c up -d --wait nginx
(cd web && E2E_USER=e2e@example.test E2E_PASSWORD="$(cat ../secrets/e2e_password)" npx playwright test)
$c down --volumes
```

## 4. CI (Azure DevOps)

The full `E2E` stage (stack preparation, migrate, start, Playwright, result publishing, teardown) is in
`ci-pipelines` → references/azure-pipelines.md. Playwright-specific points it relies on:

- `npx playwright install --with-deps chromium` on the agent (browsers aren't cached in `node_modules`).
- `env:` maps `CI: 'true'`, `E2E_BASE_URL: https://app.e2e.test`, `E2E_USER` and the secret
  `E2E_PASSWORD` explicitly — secret pipeline variables never reach scripts on their own.
- JUnit (`test-results/e2e-junit.xml`) is published with `condition: succeededOrFailed()`; the HTML
  report (`playwright-report`, with traces) is published as an artifact when the job failed.

`workers: process.env.CI ? 1 : undefined` is Playwright's CI recommendation (stability over speed on a
2-core agent); shard across jobs (`--shard=1/3`) when the suite gets long rather than raising workers.

## Anti-patterns

| Anti-pattern | Why it hurts | Instead |
|---|---|---|
| UI login per test | Slow; breaks when the form changes; trips the login rate limiter (one client IP behind nginx) → 429 | Setup project + `storageState`; extra users seeded, logged in once |
| Shared mutable fixtures ("the test customer") | Order-dependent, parallel runs collide | Unique data per test via the `api` fixture |
| `waitForTimeout` / `setTimeout` | Flaky and slow | Web-first `expect`, `waitForResponse` |
| Asserting with `expect(await el.textContent())` | No retry → flaky | `await expect(el).toHaveText(...)` |
| `--disable-web-security`, CORS changes for tests | Tests a different app than production | Same-origin through nginx |
| Test-only endpoints in the app | Ships an attack surface | Seed step against the e2e database |
| Raising timeouts to fix flakes | Hides real race conditions | Open the trace from the retry |
