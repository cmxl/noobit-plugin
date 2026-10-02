---
name: angular-ngrx-state
description: >-
  Use when creating or refactoring NgRx state in an Angular app — a Signal Store (@ngrx/signals,
  signalStore, signalState, rxMethod, entities) or the classic Store (@ngrx/store, @ngrx/effects:
  actions, reducers, effects, selectors, facades); deciding "where should this state live";
  persisting or rehydrating state across reloads (localStorage/sessionStorage); testing stores; or
  when the user mentions NgRx, Signal Store or state management.
  Plain signal()/computed()/linkedSignal()/resource() without a store belong to the Angular skills.
---

# Modern NgRx state management (Angular v20+)

NgRx state management should be the default in Angular apps, and in v20+ apps the **Signal Store
(`@ngrx/signals`) is the default choice**. It uses native signals, needs no boilerplate action
plumbing, cleans up with the component that provides it, and now covers the full spectrum from
local component state to global app state. Reach for the **classic global Store** only when the
state genuinely earns it (see the decision guide).

Everything here targets **NgRx 22 / Angular 22** (NgRx 22 needs Angular 22 + TypeScript 6.0) and
the **functional, standalone** style; the patterns also hold for NgRx 20/21 on Angular 20/21. The
older NgModule / class-based-effects / `StoreModule.forRoot` style is legacy — don't reproduce it.
Upgrade with `ng update @ngrx/store@<v> @ngrx/signals@<v>` (runs the migration schematics) after
reading `ngrx.io/guide/migration/v<N>` — never by hand-bumping `package.json`.

**Boundary:** plain `signal()` / `computed()` / `linkedSignal()` / `resource()` / `httpResource()`
inside a component belong to the Angular skills. This skill starts when that state gets a store.

## Pick the right tool first

Ask which kind of state this is before writing anything. Getting this wrong is the most common
and most expensive mistake — it's far cheaper to choose correctly than to migrate later.

| Situation | Use |
|---|---|
| Feature- or component-scoped state, view models, forms, wizard/UI state | **Signal Store**, provided at the component or route level |
| A small amount of local state, no methods/effects worth extracting | **`signalState`** directly in the component/service |
| App-wide state that is **S**hared across features, needs **H**ydration, must survive route re-entry (**A**vailable), is **R**etrieved via side effects, and is **I**mpacted by events from many sources (the **SHARI** test) | **classic global Store** (`@ngrx/store` + `@ngrx/effects`) |
| You need serializable time-travel debugging / a single inspectable state tree across the whole app | **classic global Store** |

Default reasoning: start with a **Signal Store scoped to the feature**. Promote to a
root-provided Signal Store or the classic global Store only when SHARI actually applies. Don't
put component-specific derived values in a shared/global store — keep those local.

- **Signal Store** patterns, entities, effects, custom features, testing → read
  `references/signal-store.md`.
- **Classic global Store** patterns (actions/reducers/effects/selectors) → read
  `references/classic-store.md`.
- **Hydration / persistence** to local/sessionStorage for either store → read
  `references/hydration.md`.

Read the relevant reference file before generating non-trivial code — the APIs move fast and the
details there are verified against NgRx 22 (verified October 2026).

## Non-negotiable modern idioms

These apply to whichever store you use. They're the difference between current NgRx and code that
looks like it was copied from a 2021 tutorial.

- **Standalone, not NgModules.** Bootstrap with `provideStore()`, `provideState(feature)`,
  `provideEffects(...)` in `app.config.ts` or a route's `providers`. Prefer lazy, route-level
  registration for feature state and effects.
- **Functional over class-based.** Functional effects (`createEffect(() => {...}, { functional: true })`)
  and functional stores. Inject with `inject()` / `#private` fields, not constructor params.
- **Signals at the component boundary.** Consume classic Store state with `store.selectSignal(...)`,
  not `.select(...) | async`, in new code.
- **Immutable updates only.** `patchState` updaters and reducers must return new objects — never
  mutate. This is enforced conceptually and by `protectedState` (keep it on).
- **Standalone updater functions.** Define entity/state updaters as exported functions (e.g.
  `setPending()`), not inline store methods — they're tree-shakable, testable, and composable.
- **One store per file**, co-located with its feature. Don't split one logical store across many
  interdependent custom features just for the sake of it.

## Common traps

Call these out because copying from old blog posts or pre-v18 code will bite you:

- **`concatLatestFrom` imports from `@ngrx/operators`, not `@ngrx/effects`** (moved in v18). Same
  for `tapResponse` / `mapResponse`. These live in the separate **`@ngrx/operators`** package —
  install it (`pnpm add @ngrx/operators` / `npm i @ngrx/operators`) if it isn't already in the
  project; it does not ship with `@ngrx/effects`. Since v22 only the object form
  `tapResponse({ next, error })` exists — the positional `(next, error)` form was removed.
- **Don't use "selectors with props"** — deprecated, removed in v23. Use factory selectors,
  view-model (dictionary) selectors, or `selectSignal`.
- **`rxMethod` / `signalMethod` called with a signal or observable belong in an injection
  context** (constructor / field initializer) or get an explicit `{ injector }`. Elsewhere they
  currently fall back to the store's injector and log a dev-mode deprecation warning ("in a future
  version, this will throw") — and a root store's watcher then outlives the calling component.
- **No giant "view-model" computed.** One focused `computed` per concern, so memoization actually
  works.
- **`createFeature` can't be used with optional (`?`) state properties.** Model them as
  `x: T | null` and initialize to `null`.

## File & naming conventions

**Signal Store** (one file per store, kebab-case, `*-store.ts`):

```
book-search/
├── book.ts                 # domain model / type
├── books-service.ts        # data access, injected into the store
├── book-search-store.ts    # signalStore(...)
├── book-search.ts          # component that provides + injects the store
├── book-list.ts            # dumb child components (input/output)
└── book-search-store.spec.ts
shared/
└── with-request-status.ts  # reusable signalStoreFeature() + its updater fns
```

**Classic Store** (split by concern, one action group per event source):

```
books/
├── book.model.ts
├── book-list-page.actions.ts   # page/UI events
├── books-api.actions.ts        # API result events
├── books.reducer.ts            # createFeature(...) -> reducer + auto selectors
├── books.effects.ts            # functional effects, named for what they do (loadBooks)
└── books.selectors.ts          # extra/derived selectors (or fold into createFeature)
```

## Verify before claiming done

State changes must type-check and pass tests. After generating store code, run the project's build
and the affected unit tests before claiming it works — use whatever the project uses:

```bash
ng build && ng test                      # standard Angular CLI
# or, in an Nx workspace:
nx build <app> && nx test <project>      # runner is often Vitest or Jest
```

Don't claim the store "works" without running these. See the testing sections in the reference
files for the store-specific patterns (`TestBed` + `unprotected` for Signal Store; `.projector`
and plain function calls for classic reducers/selectors/functional effects).

Lint with **`@ngrx/eslint-plugin`** (`ng add @ngrx/eslint-plugin`; v22 supports flat config /
ESLint 9+ only). Its `signals`, `store`, `effects` and `operators` configs catch most of the traps
above (e.g. `prefer-protected-state`, `prefer-concat-latest-from`, `on-function-explicit-return-type`,
`signal-store-feature-should-use-generic-type`).

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official
docs instead of guessing (ngrx.io is a SPA — if a fetch returns only the landing page, read the
Markdown source under `github.com/ngrx/platform/tree/main/projects/www/src/app/pages/guide/`):
- Signal Store / `@ngrx/signals`: https://ngrx.io/guide/signals
- Store: https://ngrx.io/guide/store · Effects: https://ngrx.io/guide/effects · Operators: https://ngrx.io/guide/operators
- Migration guides (breaking changes per major): https://ngrx.io/guide/migration/v22
- ESLint plugin rules: https://ngrx.io/guide/eslint-plugin
- Changelog: https://github.com/ngrx/platform/blob/main/CHANGELOG.md
- NgRx Toolkit (`@ngrx-toolkit/core` — storage sync, DevTools, `withResource`): https://ngrx-toolkit.angulararchitects.io/
