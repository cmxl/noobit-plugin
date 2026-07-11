# Hydration — persist & rehydrate state to browser storage

This covers **state persistence**: saving store state to `localStorage`/`sessionStorage` and
restoring it on reload. ("Hydration" here is a metaphor and is unrelated to Angular SSR client
hydration — for that, see the note at the end.)

Verified against NgRx v21 / Angular v20+. Pick the approach that matches the store type.

## Contents
1. Cross-cutting rules (SSR safety, versioning, whitelisting)
2. Classic Store — hydration meta-reducer (hand-rolled)
3. Classic Store — `ngrx-store-localstorage` (library)
4. Signal Store — custom `withStorageSync` feature (hand-rolled)
5. Signal Store — `@angular-architects/ngrx-toolkit` (library)
6. Choosing an approach
7. Note: SSR client hydration is a different thing

---

## 1. Cross-cutting rules

Whatever the approach, these apply:

- **Guard for SSR / non-browser.** `localStorage` doesn't exist on the server. Guard with
  `isPlatformBrowser(inject(PLATFORM_ID))` (or the simpler `typeof localStorage !== 'undefined'`).
  Writing to storage during server rendering will throw.
- **Whitelist, don't persist everything.** Persist only the slices that should survive a reload
  (filters, auth, cart, UI prefs). Never blindly persist `isLoading`, transient errors, or
  server-owned entity collections you'll re-fetch anyway.
- **Version the storage key.** Suffix the key (`app_state_v2`) and bump it when the state shape
  changes, so old persisted blobs don't rehydrate into a new shape. Always merge persisted data
  *over* the defaults so new/renamed slices still get their initial values.
- **Handle corruption.** Wrap `JSON.parse` in try/catch and drop the key on failure.
- Only JSON-serializable data survives — no `Date`/`Map`/class instances without custom
  serialize/parse.

## 2. Classic Store — hydration meta-reducer (hand-rolled)

The canonical mechanism. Rehydrate on `INIT`/`UPDATE` (both from `@ngrx/store`; `UPDATE` covers
lazily-registered feature reducers), persist on every other action.

```ts
// hydration.metareducer.ts
import { ActionReducer, INIT, UPDATE } from '@ngrx/store';

const STORAGE_KEY = 'app_state_v1';

export function hydrationMetaReducer(isBrowser: boolean) {
  return (reducer: ActionReducer<AppState>): ActionReducer<AppState> =>
    (state, action) => {
      if (isBrowser && (action.type === INIT || action.type === UPDATE)) {
        const stored = localStorage.getItem(STORAGE_KEY);
        if (stored) {
          try {
            return { ...reducer(state, action), ...JSON.parse(stored) }; // merge over defaults
          } catch {
            localStorage.removeItem(STORAGE_KEY);
          }
        }
      }
      const next = reducer(state, action);
      if (isBrowser) localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      return next;
    };
}
```

```ts
// app.config.ts
import { PLATFORM_ID, inject } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { provideStore, MetaReducer } from '@ngrx/store';

export const appConfig: ApplicationConfig = {
  providers: [
    provideStore(reducers, { metaReducers: getMetaReducers() }),
  ],
};
function getMetaReducers(): MetaReducer[] {
  const isBrowser = isPlatformBrowser(inject(PLATFORM_ID));
  return [hydrationMetaReducer(isBrowser)];
}
```

Best for one or two slices with simple needs. To persist only specific slices, pick them out in
the write step instead of serializing the whole tree.

## 3. Classic Store — `ngrx-store-localstorage` (library)

Still maintained; match the major to your Angular major (Angular 21 → `ngrx-store-localstorage@21.x`).
It's just a meta-reducer factory, so it drops into `provideStore`:

```ts
import { localStorageSync } from 'ngrx-store-localstorage';

export function localStorageSyncReducer(reducer: ActionReducer<AppState>): ActionReducer<AppState> {
  return localStorageSync({
    keys: ['todos', 'visibilityFilter'],  // whole slices, or { feature: ['prop'] } for partial
    rehydrate: true,
    checkStorageAvailability: true,        // SSR safety
  })(reducer);
}
// provideStore(reducers, { metaReducers: [localStorageSyncReducer] })
```

Useful options: `keys` (partial sub-props supported), `storage` (swap in `sessionStorage`),
`storageKeySerializer` (namespacing), `restoreDates`, `syncCondition` (opt-in "remember me"),
`checkStorageAvailability`, `mergeReducer` (custom rehydrate merge). Reach for it when you need
partial-slice sync, custom serialization/encryption, or conditional syncing.

## 4. Signal Store — custom `withStorageSync` feature (hand-rolled)

Pattern: `onInit` reads storage → `patchState`; then an `effect()` reads `getState(store)` and
writes on every change. `onInit` runs in the injection context, so `inject()`/`effect()` are legal
there, and the effect is torn down with the store.

```ts
import { effect, inject, PLATFORM_ID } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { getState, patchState, signalStoreFeature, type, withHooks } from '@ngrx/signals';

export function withStorageSync<State extends object>(config: {
  key: string;
  storage?: 'local' | 'session';
  select?: (state: State) => Partial<State>;
}) {
  const { key, storage = 'local', select = (s: State) => s } = config;
  return signalStoreFeature(
    { state: type<State>() },                 // required input: any state
    withHooks({
      onInit(store) {
        if (!isPlatformBrowser(inject(PLATFORM_ID))) return;   // SSR guard
        const engine = storage === 'session' ? sessionStorage : localStorage;

        const raw = engine.getItem(key);                        // 1. read on init
        if (raw !== null) {
          try { patchState(store, JSON.parse(raw) as Partial<State>); }
          catch { engine.removeItem(key); }
        }
        effect(() => {                                          // 2. write on any change
          engine.setItem(key, JSON.stringify(select(getState(store) as State)));
        });
      },
    }),
  );
}

// usage
export const FilterStore = signalStore(
  withState({ query: '', order: 'asc' as const }),
  withStorageSync<{ query: string; order: 'asc' | 'desc' }>({ key: 'filter_v1' }),
);
```

If TypeScript errors when composing multiple input-requiring features, add an unused generic:
`function withStorageSync<State extends object, _>(...)`.

## 5. Signal Store — `@angular-architects/ngrx-toolkit` (library)

Recommended for production Signal Store persistence — SSR-safe out of the box (no manual
`isPlatformBrowser`), supports `select`/`autoSync`, and offers session/IndexedDB backends. Match
the major to Angular (Angular 21 → `@angular-architects/ngrx-toolkit@21.x`).

```ts
import { withStorageSync, withSessionStorage } from '@angular-architects/ngrx-toolkit';

signalStore(withState({ name: 'John' }), withStorageSync('user'));                    // localStorage
signalStore(withState({ name: 'John' }), withStorageSync('user', withSessionStorage()));
signalStore(withState({ cart: [] }), withStorageSync({ key: 'cart', select: (s) => ({ cart: s.cart }) }));
```

Options: `key`, `autoSync` (default true), `select`, `stringify`/`parse`. Exposes
`readFromStorage()` / `writeToStorage()` / `clearStorage()` / `whenSynced()`. The same package's
`withDevtools('name')` gives Signal Stores a Redux DevTools tab (swap to `withDevtoolsStub` in prod
via `angular.json` file replacements).

## 6. Choosing an approach

| Need | Use |
|---|---|
| Classic Store, 1–2 slices, simple | hand-rolled meta-reducer (§2) |
| Classic Store, partial slices / encryption / conditional sync | `ngrx-store-localstorage` (§3) |
| Signal Store, want zero deps / full control (e.g. cross-tab sync) | custom `withStorageSync` feature (§4) |
| Signal Store, production, want SSR-safe + IndexedDB + DevTools | `@angular-architects/ngrx-toolkit` (§5) |

Neither library listens for the `storage` event (cross-tab sync) by default — add a
`window.addEventListener('storage', ...)` in a custom feature if you need tabs to stay in sync.

## 7. Note: SSR client hydration is a different thing

If the user means **Angular SSR hydration** (`provideClientHydration()`, reconciling
server-rendered DOM, `TransferState` to avoid re-fetching), that is unrelated to browser-storage
persistence. Key fact: with `provideClientHydration()` + `provideHttpClient()`, Angular's HTTP
transfer cache already dedupes SSR `GET`s, so an NgRx effect calling `HttpClient.get(...)` won't
double-fetch during hydration — no extra code needed. Only reach for explicit `TransferState`
store-seeding when the data isn't a cacheable `HttpClient` GET (WebSocket/GraphQL/POST) or you want
selectors populated synchronously at bootstrap. Ask the user which "hydration" they mean if it's
ambiguous.
