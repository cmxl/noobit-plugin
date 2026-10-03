---
name: frontend-testing
description: Use when testing the Angular side of the cookie-BFF stack — Playwright e2e through nginx + compose (setup-project login + storageState, X-XSRF-TOKEN API seeding, self-signed HTTPS, CI stage), or Vitest unit tests via ng test for BFF client pieces (401 interceptor, /api/me init, guards). Generic TestBed/Vitest patterns belong to angular-testing. Not for .NET tests (dotnet-testing), store internals (angular-ngrx-state), or Jasmine/Karma/Cypress.
---

# Frontend testing — Vitest + Playwright for the cookie-BFF stack

## Overview

Two layers, each with one job:

| Layer | Tool | Proves | Runs against |
|---|---|---|---|
| Unit / component | **Vitest** through `ng test` | Component, service, store, interceptor, guard logic | jsdom (default) — no server |
| End-to-end | **Playwright** | The real stack: Angular → nginx → BFF cookie auth + antiforgery → DB | The docker compose stack over HTTPS |

This skill is the **stack glue**: how Angular's Vitest builder, zoneless TestBed and Playwright fit the
`__Host-session` cookie BFF (`bff-security`), nginx (`nginx-deploy`) and compose (`docker`). Generic
API depth lives in the external skills when installed — `angular-testing` (TestBed patterns),
`vitest`, `playwright-best-practices` — load them for framework detail; this skill wins on anything
specific to this stack. Store unit tests: `angular-ngrx-state` → references/signal-store.md §9 (don't
duplicate them here). .NET side: `dotnet-testing`.

Verified against angular.dev (testing, zoneless, HTTP testing, `ng test` reference) and
playwright.dev (auth, API testing, test options, CI) in October 2026 — Angular 21+ (Vitest and
zoneless are the defaults), Playwright 1.x.

## Unit tests — Vitest via the Angular builder

New Angular projects test with **Vitest + jsdom** through the `@angular/build:unit-test` builder
(`ng test`). Don't add a separate `vitest.config.ts` or `@analogjs` plugin to an Angular CLI project
unless you need `runnerConfig`; don't reintroduce Karma.

```bash
ng test                                              # watch mode (TTY)
ng test --no-watch --no-progress --coverage          # CI; coverage needs @vitest/coverage-v8 (dev dep)
ng test --filter "OrderList"                         # regex on suite/test names
```

Builder options worth knowing (`angular.json` → `test.options`): `providersFile` (default providers
for every test — put `provideHttpClient()`-style app-wide test providers there), `setupFiles`,
`coverageThresholds`, `coverageReporters` (`cobertura` for CI), `reporters` + `outputFile` (JUnit for
CI; `outputFile` applies to the **first** reporter only), `browsers` (real browser instead of jsdom).

### Zoneless TestBed — the rules

- **TestBed is zoneless by default** (Angular 21+), even if zone.js is loaded. Add
  `provideZoneChangeDetection()` only for a legacy zone-based app.
- **`await fixture.whenStable()` instead of `fixture.detectChanges()`** — it matches production
  scheduling. Always `await fixture.whenStable()` after creating the component or changing inputs,
  before asserting on the DOM.
- TestBed throws `ExpressionChangedAfterItHasBeenCheckedError` for template values changed without a
  notification — that is a real OnPush/signals bug in the component (or the test host), not test noise.
- No `fakeAsync`/`tick` (zone.js utilities). Timers: `vi.useFakeTimers()` → `await vi.runAllTimersAsync()`
  → `vi.useRealTimers()`.
- Signal inputs: `fixture.componentRef.setInput('name', value)` (or `inputBinding` via
  `TestBed.createComponent(..., { bindings })`). Never assign to an `input()` property.

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { OrderList } from './order-list';

describe('OrderList', () => {
  let fixture: ComponentFixture<OrderList>;
  let http: HttpTestingController;

  beforeEach(async () => {
    TestBed.configureTestingModule({
      imports: [OrderList],                                        // standalone component
      providers: [provideHttpClient(), provideHttpClientTesting()], // this order — testing overrides the backend
    });
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(OrderList);
    fixture.componentRef.setInput('customerId', 42);
    await fixture.whenStable();
  });

  afterEach(() => http.verify());                                  // no unexpected requests

  it('renders the orders the API returns', async () => {
    http.expectOne('/api/customers/42/orders').flush([{ id: 1, number: 'A-1' }]);
    await fixture.whenStable();
    expect(fixture.nativeElement.querySelectorAll('li').length).toBe(1);
  });
});
```

### What to unit-test in the BFF client

| Piece | Test |
|---|---|
| 401 interceptor (redirect to login) | `req.flush(null, { status: 401, statusText: 'Unauthorized' })` → router navigated; 403 does **not** redirect |
| `/api/me` app initializer / auth store | Anonymous (401) and logged-in responses both resolve startup; nothing but "who am I" is stored |
| Functional guards | `TestBed.runInInjectionContext(() => guard(route, state))` with a stubbed auth state |
| XSRF | Don't unit-test Angular's built-in `X-XSRF-TOKEN` handling — prove it in e2e (it needs a real cookie) |
| Stores | Store unit tests per `angular-ngrx-state` → references/signal-store.md §9: real store, mocked data service, assert on state. Component/integration tests: real store + real service + `HttpTestingController` (as above), or a stub store for pure presentation |

## E2E — Playwright against the compose stack

Playwright drives the **real** stack: the same images, nginx with TLS, the BFF, a real database. The
cookie BFF dictates three things: log in **once** and reuse the cookies, send the antiforgery header
on every state-changing API call you make from tests, and talk HTTPS (`__Host-` cookies are
`Secure`-only).

```ts
// e2e/env.ts — shared by the config, auth.setup.ts and fixtures.ts
export const baseURL = process.env.E2E_BASE_URL ?? 'https://app.e2e.test';  // must match nginx server_name + AllowedHosts
// Only the throwaway e2e stack has a self-signed cert: a `.test` host (RFC 6761, never public) or an
// explicit opt-in. Any other E2E_BASE_URL keeps full TLS validation.
export const selfSignedTls =
  new URL(baseURL).hostname.endsWith('.test') || process.env.E2E_SELF_SIGNED === '1';
```

```ts
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test';
import { baseURL, selfSignedTls } from './e2e/env';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI
    ? [['junit', { outputFile: 'test-results/e2e-junit.xml' }], ['html', { open: 'never' }]]
    : 'html',
  use: {
    baseURL,
    ignoreHTTPSErrors: selfSignedTls,   // gated — pointing E2E_BASE_URL at a real host keeps TLS checks on
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: 'playwright/.auth/user.json' },
      dependencies: ['setup'],
    },
  ],
});
```

Login setup, `api` seeding fixture, compose/CI wiring and the anti-patterns:
**[references/e2e-bff.md](references/e2e-bff.md) — read it before writing e2e tests.**

Core e2e rules:

1. **Log in through the BFF once** in the `setup` project (API, not UI) and save `storageState`;
   every test starts authenticated. One dedicated UI test covers the login form itself. Logins are
   scarce: the BFF's `"auth"` limiter allows 5/min per IP and all e2e traffic arrives through nginx
   from one IP, so `compose.e2e.yaml` raises `RateLimiting__Auth__PermitLimit` — and
   `RateLimiting__Global__PermitLimit` (default 100/window; static assets and `/api/me` count) — for the e2e stack and
   extra users come from the E2E seeding, each logged in once (references/e2e-bff.md §1, §3).
2. **Seed through the API, never the UI**, with the `X-XSRF-TOKEN` header taken from the
   `XSRF-TOKEN` cookie — exactly what Angular's `HttpClient` sends. Unique data per test
   (`crypto.randomUUID()`), so tests run in parallel without cleanup races.
3. **Web-first assertions only** — `await expect(locator).toBeVisible()` / `toHaveText()` retry
   until the timeout. No `waitForTimeout`, no sleeps, no `expect(await locator.isVisible())`.
4. **User-facing locators**: `getByRole`, `getByLabel`, `getByText`; `getByTestId` as the fallback.
5. **Traces on retry** (`trace: 'on-first-retry'`) and the HTML report as a CI artifact — a flaky
   test is debugged from its trace, never "fixed" with a longer timeout.
6. **Logout** only clears the cookie in that test's browser context — safe with the shared
   `storageState` (the saved cookie stays valid for every other context). Tests that **change the
   password, "log out everywhere" or revoke sessions** rotate the user's security stamp
   (`bff-security`), which invalidates every session of that user — they use their own seeded user
   and context, never the shared one.

## Common mistakes

| Mistake | Fix |
|---|---|
| `fixture.detectChanges()` everywhere / `fakeAsync` in a zoneless app | `await fixture.whenStable()`; `vi.useFakeTimers()` for timers |
| `component.myInput = …` on a signal input | `fixture.componentRef.setInput('myInput', …)` |
| `provideHttpClientTesting()` before `provideHttpClient()` | Real client first, testing backend second |
| Mocking `HttpClient` with `vi.fn()` | `HttpTestingController` (`expectOne` / `flush` / `verify`) |
| UI login in `beforeEach` of every test | `setup` project + `storageState` |
| API seeding POST without `X-XSRF-TOKEN` | 400 from the antiforgery filter — read the `XSRF-TOKEN` cookie and send the header |
| e2e against `http://` or a host nginx doesn't serve | HTTPS + the real `server_name` (the catch-all refuses the TLS handshake for unknown SNI, 444 on :80; `__Host-` cookies need `Secure`) |
| `page.waitForTimeout(2000)` | Web-first `expect` assertions / `page.waitForResponse` |
| Unconditional `ignoreHTTPSErrors: true` while `baseURL` is env-overridable | Gate it on the host (`.test`) or an explicit `E2E_SELF_SIGNED=1` (`e2e/env.ts`); prod smoke tests use real certs |
| Committing `playwright/.auth/` | Gitignore it — it holds a live session cookie |

## Official docs — verify, don't guess

- Angular testing (Vitest, `ng test`): https://angular.dev/guide/testing · CLI options: https://angular.dev/cli/test
- Zoneless testing: https://angular.dev/guide/zoneless · Component scenarios (setInput, fake timers): https://angular.dev/guide/testing/components-scenarios
- HTTP testing: https://angular.dev/guide/http/testing · Coverage: https://angular.dev/guide/testing/code-coverage
- Vitest: https://vitest.dev/
- Playwright auth: https://playwright.dev/docs/auth · API testing: https://playwright.dev/docs/api-testing · Options: https://playwright.dev/docs/test-use-options · CI: https://playwright.dev/docs/ci
