# Signal Store (`@ngrx/signals`) — patterns reference

Verified against the NgRx v21 docs (Angular v20+). Package entry points: `@ngrx/signals`,
`@ngrx/signals/entities`, `@ngrx/signals/rxjs-interop`, `@ngrx/signals/events`,
`@ngrx/signals/testing`; plus `@ngrx/operators` for `tapResponse` / `mapResponse`.

## Contents
1. Core building blocks
2. Providing & scoping (root vs local)
3. Computed / derived state
4. Methods & side effects (`rxMethod`, `signalMethod`, async)
5. Entity management
6. Custom store features (`signalStoreFeature`)
7. Private members, `withProps`, exposing the store type
8. `signalState` (store-less local state)
9. Testing
10. Anti-patterns
11. Events plugin (advanced Flux-style)

---

## 1. Core building blocks

`signalStore(...features)` returns an **injectable class**. It is not registered anywhere by
default — add it to a `providers` array or pass `{ providedIn: 'root' }`. State must be an object
literal.

```ts
import { signalStore, withState, withComputed, withMethods, patchState } from '@ngrx/signals';
import { computed, inject } from '@angular/core';

type BookSearchState = {
  books: Book[];
  isLoading: boolean;
  filter: { query: string; order: 'asc' | 'desc' };
};

const initialState: BookSearchState = {
  books: [],
  isLoading: false,
  filter: { query: '', order: 'asc' },
};

export const BookSearchStore = signalStore(
  withState(initialState),
  withComputed(({ books, filter }) => ({
    booksCount: computed(() => books().length),
    sortedBooks: computed(() => {
      const dir = filter.order() === 'asc' ? 1 : -1;
      return books().toSorted((a, b) => dir * a.title.localeCompare(b.title));
    }),
  })),
  withMethods((store, booksService = inject(BooksService)) => ({
    updateQuery(query: string): void {
      patchState(store, (state) => ({ filter: { ...state.filter, query } }));
    },
    async loadAll(): Promise<void> {
      patchState(store, { isLoading: true });
      const books = await booksService.getAll();
      patchState(store, { books, isLoading: false });
    },
  })),
);
```

Each state slice becomes a `Signal`; nested objects become a `DeepSignal` with a child signal per
property (`store.filter()`, `store.filter.query()`), created lazily on first access.

`withState` also accepts a **factory** run in the injection context, so it can `inject()` — handy
for seeding from a token: `withState(() => inject(BOOK_SEARCH_STATE))`.

### `patchState` — the only mutation path

Takes the store/`signalState` instance, then partial objects and/or immutable updater functions:

```ts
patchState(store, { isLoading: true });
patchState(store, (state) => ({ filter: { ...state.filter, query } }));
patchState(store, setPending(), setAllEntities(books)); // compose updaters
```

Prefer **reusable updater functions** typed with `PartialStateUpdater` over inline object spreads
for anything used more than once — they're testable and composable:

```ts
import { PartialStateUpdater } from '@ngrx/signals';
function setQuery(query: string): PartialStateUpdater<{ filter: { query: string } }> {
  return (state) => ({ filter: { ...state.filter, query } });
}
```

`getState(store)` reads the whole state; inside a reactive context (`effect`) it tracks changes.
Keep `protectedState` at its default (`true`) so only the store's own methods can patch state;
only disable it (`signalStore({ protectedState: false }, ...)`) as a last resort.

## 2. Providing & scoping

- **Local (default choice for feature/component state):** add to a component or route
  `providers: [BookSearchStore]`. Lifecycle is tied to that component/route — created on entry,
  destroyed on leave (its `onDestroy` hook, `rxMethod` subscriptions, and `takeUntilDestroyed`
  all clean up automatically). This is also the SSR-safe default, since it's rebuilt per
  navigation rather than shared.

  ```ts
  @Component({ providers: [BookSearchStore], /* ... */ })
  export class BookSearch { readonly store = inject(BookSearchStore); }
  ```

- **Root (`{ providedIn: 'root' }`):** one shared instance app-wide. Use only for genuinely global
  state. Never *also* list a root-provided store in a component `providers` array — that creates a
  second instance.

## 3. Computed / derived state

Return `computed(...)` (or a bare `() => value`, which is auto-wrapped). Keep each computed
**single-responsibility** so memoization stays effective — don't build one mega view-model
computed. To share logic between computeds in the same feature, define a local `computed` in the
factory and return both:

```ts
withComputed(({ filter }) => {
  const direction = computed(() => (filter.order() === 'asc' ? 1 : -1));
  return { direction, directionReversed: () => direction() * -1 };
})
```

`deepComputed(() => ({...}))` produces a `DeepSignal` when you want child signals per nested
result property. `withLinkedState(({ options }) => ({ selected: () => options()[0] }))` (v20+)
derives a *patchable* state slice from other signals (wraps `linkedSignal`) — use it when a slice
must track/reset relative to another.

## 4. Methods & side effects

Three tools, in rough order of reach:

1. **Async methods** — for simple one-shot loads (see `loadAll` above). Fine when there's no
   race condition to manage.
2. **`rxMethod<T>(pipe(...))`** (`@ngrx/signals/rxjs-interop`) — the RxJS-powered replacement for
   classic Effects. Callable with a static value, a `Signal`, a computation fn, or an `Observable`;
   re-runs the pipe on each new input. Use it when you need debouncing, cancellation
   (`switchMap`), or sequencing (`concatMap`/`exhaustMap`).

   ```ts
   import { rxMethod } from '@ngrx/signals/rxjs-interop';
   import { tapResponse } from '@ngrx/operators';
   import { debounceTime, distinctUntilChanged, pipe, switchMap, tap } from 'rxjs';

   withMethods((store, books = inject(BooksService)) => ({
     loadByQuery: rxMethod<string>(
       pipe(
         debounceTime(300),
         distinctUntilChanged(),
         tap(() => patchState(store, { isLoading: true })),
         switchMap((query) =>
           books.getByQuery(query).pipe(
             tapResponse({
               next: (books) => patchState(store, { books }),
               error: console.error,
               finalize: () => patchState(store, { isLoading: false }),
             }),
           ),
         ),
       ),
     ),
   }))
   ```

   **`tapResponse` is essential**: it keeps the outer stream alive if the inner call errors, so one
   failed request doesn't kill the whole `rxMethod` subscription. Wire a signal to it in a
   constructor/field initializer (an injection context):

   ```ts
   constructor() { this.store.loadByQuery(this.store.filter.query); } // re-fetches on query change
   ```

   **Injection-context rule:** calling `rxMethod`/`signalMethod` with a signal/observable outside an
   injection context without an explicit `{ injector }` is deprecated and will throw. When calling a
   root store's method from a component `ngOnInit`, pass the component's injector.

3. **`signalMethod<T>((x) => {...})`** — RxJS-free alternative using an internal `effect`; smaller
   bundle; only tracks the signal(s) you pass in. Prefer `rxMethod` when race conditions or
   multiple synchronous emissions matter (signals are glitch-free, so only the last change
   propagates).

There is **no separate `Actions` stream** in a Signal Store — side effects live in the store,
co-located with the state they touch. For decoupled inter-store coordination, see the Events
plugin (§11).

## 5. Entity management (`@ngrx/signals/entities`)

`withEntities<T>()` (requires an `id: string | number`) adds `ids`, `entityMap` (state) and
`entities` (computed). Mutate with standalone updater functions inside `patchState`:

```ts
import { withEntities, addEntity, updateEntity, removeEntities, setAllEntities } from '@ngrx/signals/entities';

export const TodosStore = signalStore(
  withEntities<Todo>(),
  withMethods((store) => ({
    add(todo: Todo) { patchState(store, addEntity(todo)); },
    toggle(id: number) { patchState(store, updateEntity({ id, changes: (t) => ({ done: !t.done }) })); },
    clearDone() { patchState(store, removeEntities((t) => t.done)); },
    load(todos: Todo[]) { patchState(store, setAllEntities(todos)); },
  })),
);
```

Updaters: `add*` / `prepend*` (no-op on duplicate id), `update*` (by id(s) or predicate, partial
or fn changes), `updateAllEntities`, `set*` (add-or-replace), `setAllEntities`, `upsert*`
(add-or-merge), `remove*` / `removeAllEntities`.

- **Custom id:** pass `{ selectId }` (a `SelectEntityId<T>`) as the 2nd arg to add/set/update
  updaters (not needed for remove).
- **DRY config:** `entityConfig({ entity: type<Todo>(), collection: 'todo', selectId })`, then pass
  the config to `withEntities(...)` and every updater.
- **Named collections:** `withEntities({ entity: type<Book>(), collection: 'book' })` renames props
  to `bookIds` / `bookEntityMap` / `bookEntities`; every updater then needs `{ collection: 'book' }`.
  Multiple collections work, but **prefer a dedicated store per entity type**.
- Prefix a collection with `_` to make it private, then expose a public computed.

## 6. Custom store features (`signalStoreFeature`)

Extract reusable slices of behavior. Return `signalStoreFeature(...)` from a `withXxx()` factory.

**Self-contained feature + its updater functions:**

```ts
export type RequestStatus = 'idle' | 'pending' | 'fulfilled' | { error: string };

export function withRequestStatus() {
  return signalStoreFeature(
    withState<{ requestStatus: RequestStatus }>({ requestStatus: 'idle' }),
    withComputed(({ requestStatus }) => ({
      isPending: computed(() => requestStatus() === 'pending'),
      isFulfilled: computed(() => requestStatus() === 'fulfilled'),
      error: computed(() => {
        const s = requestStatus();
        return typeof s === 'object' ? s.error : null;
      }),
    })),
  );
}
export const setPending = () => ({ requestStatus: 'pending' as const });
export const setFulfilled = () => ({ requestStatus: 'fulfilled' as const });
export const setError = (error: string) => ({ requestStatus: { error } });
```

**Requiring input** from the host store (type-checked — missing requirements = compile error):

```ts
import { EntityState } from '@ngrx/signals/entities';

export function withSelectedEntity<Entity>() {
  return signalStoreFeature(
    { state: type<EntityState<Entity>>() }, // required input
    withState<{ selectedEntityId: EntityId | null }>({ selectedEntityId: null }),
    withComputed(({ entityMap, selectedEntityId }) => ({
      selectedEntity: computed(() => {
        const id = selectedEntityId();
        return id ? entityMap()[id] : null;
      }),
    })),
  );
}
```

- To feed a runtime signal from the store into a feature, use
  `withFeature(({ entities }) => withBooksFilter(entities))`.
- **Feature order matters** — a feature can only reference members declared before it (put
  `withMethods` before a `withHooks` that calls those methods).
- **Known TS gotcha:** combining multiple input-requiring features that declare no generic errors
  out; add an unused generic — `function withX<_>() {...}`.

## 7. Private members, `withProps`, exposing the type

Any root-level slice/prop/computed/method prefixed with `_` is private (type-level enforced):

```ts
export const CounterStore = signalStore(
  withState({ count: 0, _internal: 0 }),
  withComputed(({ count }) => ({ _double: computed(() => count() * 2) })),
);
```

`withProps` adds static props, observables, or grouped injected deps:

```ts
withProps(() => ({ booksService: inject(BooksService), logger: inject(Logger) })),
withProps(({ isLoading }) => ({ isLoading$: toObservable(isLoading) })), // integration point
```

`withHooks` for lifecycle; use the factory form when `onDestroy` needs injected deps:

```ts
withHooks((store) => {
  const logger = inject(Logger);
  return {
    onInit() { logger.debug('init'); store.loadAll(); },
    onDestroy() { logger.debug('destroy'); },
  };
})
```

Expose the store's type for typing helpers/injection:
`export type CounterStore = InstanceType<typeof CounterStore>;`

## 8. `signalState` — store-less local state

For modest local state with no methods worth extracting, skip the store:

```ts
import { signalState, patchState } from '@ngrx/signals';

export class Counter {
  readonly state = signalState({ count: 0 });
  increment() { patchState(this.state, (s) => ({ count: s.count + 1 })); }
}
```

## 9. Testing

Principles from the docs: test the **public API only**; don't spy on the store's own methods
(extract complex logic to a service and mock the service); assert on **state**, not on "was called".
**Always use `TestBed`** — it provides the injection context `rxMethod`/`inject` need.

```ts
import { TestBed } from '@angular/core/testing';
import { unprotected } from '@ngrx/signals/testing';
import { patchState } from '@ngrx/signals';

it('doubles on increment', () => {
  TestBed.configureTestingModule({ providers: [CounterStore] }); // omit for providedIn:'root'
  const store = TestBed.inject(CounterStore);
  store.increment();
  expect(store.count()).toBe(1);
  expect(store.doubleCount()).toBe(2);
});

it('can seed protected state', () => {
  const store = TestBed.inject(CounterStore);
  patchState(unprotected(store), { count: 5 }); // bypass protection in tests only
  expect(store.doubleCount()).toBe(10);
});
```

Mock injected deps with `{ provide: BooksService, useValue: {...} }`. For `rxMethod`/`signalMethod`,
run in an injection context and await via `await expect.poll(() => store.x()).toBe(...)` or
`TestBed.tick()`. To test a component, provide a plain object of signals + fns for the store.

## 10. Anti-patterns to avoid

- Mutating state non-immutably in a `patchState` updater.
- Disabling `protectedState` and patching from outside the store.
- Spying on / asserting store methods instead of asserting state.
- Calling `rxMethod`/`signalMethod` with a signal/observable outside an injection context.
- One giant view-model computed (kills memoization) — split into focused computeds.
- Component-specific derived state living in a shared/global store.
- Referencing a member before the feature that defines it (feature ordering).
- Cramming many entity collections into one store (prefer one store per entity type).
- Assuming Redux DevTools "just works" — it doesn't for Signal Store; use
  `@angular-architects/ngrx-toolkit`'s `withDevtools`.

## 11. Events plugin (advanced, `@ngrx/signals/events`)

For decoupled, Flux-style coordination *across* stores (most apps don't need this — the default
Signal Store is enough). `event(...)` / `eventGroup(...)` define events; `withReducer(on(...))`
does pure transitions; `withEventHandlers(...)` runs side effects that react to `events.on(...)`
and can auto-dispatch a returned event (use `mapResponse`, not `tapResponse`, to map to
success/failure events); dispatch via `inject(Dispatcher)` or `injectDispatch(group)`. This is the
recommended replacement for the deprecated `withRedux` from ngrx-toolkit.
