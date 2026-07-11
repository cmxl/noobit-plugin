---
name: angular-ngrx-state
description: >-
  Modern NgRx state management for Angular v20+ applications. Default to the Signal Store
  (@ngrx/signals); reach for the classic global Store (createActionGroup / createFeature /
  functional effects / selectors) only for genuinely app-wide shared state. Covers store
  structure, computed/selectors, side effects (rxMethod / functional effects), entity
  management, browser-storage hydration (persist & rehydrate to local/sessionStorage), and
  testing. Use this skill WHENEVER working with state in an Angular app — creating or
  refactoring a store, component/service state, actions, reducers, effects, selectors, or a
  facade; deciding "where should this state live"; persisting or rehydrating state across
  reloads; or when the user mentions NgRx, Signal Store, signalStore, signalState,
  @ngrx/signals, state management, or wiring up data flow — even if they don't say "NgRx"
  explicitly.
---

# Modern NgRx state management (Angular v20+)

NgRx state management should be the default in Angular apps, and in v20+ apps the **Signal Store
(`@ngrx/signals`) is the default choice**. It uses native signals, needs no boilerplate action
plumbing, cleans up with the component that provides it, and now covers the full spectrum from
local component state to global app state. Reach for the **classic global Store** only when the
state genuinely earns it (see the decision guide).

Everything here targets **NgRx 21 / Angular 20+** and the **functional, standalone** style. The
older NgModule / class-based-effects / `StoreModule.forRoot` style is legacy — don't reproduce it.

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
details there are verified against the v21 docs.

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

## Traps the official docs still get wrong

Call these out because copying from ngrx.io or old blog posts will bite you:

- **`concatLatestFrom` imports from `@ngrx/operators`, not `@ngrx/effects`** (moved in v18). Same
  for `tapResponse` / `mapResponse`. These live in the separate **`@ngrx/operators`** package —
  install it (`pnpm add @ngrx/operators` / `npm i @ngrx/operators`) if it isn't already in the
  project; it does not ship with `@ngrx/effects`.
- **Don't use "selectors with props"** — deprecated, removed in v23. Use factory selectors,
  view-model (dictionary) selectors, or `selectSignal`.
- **`rxMethod` / `signalMethod` called with a signal or observable must run in an injection
  context** (constructor / field initializer) or be passed an explicit `{ injector }`. Calling
  them elsewhere without an injector is deprecated and will throw — and leaks when a root-scoped
  method outlives a component.
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
├── books.effects.ts            # functional effects, xxx$ names
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
