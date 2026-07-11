# Classic global Store (`@ngrx/store` + `@ngrx/effects`) — patterns reference

Verified against the NgRx v21 docs (Angular v20+). Use this for **SHARI** state (Shared,
Hydrated, Available across route re-entry, Retrieved via side effect, Impacted by many sources) and
when you want a single serializable state tree with time-travel debugging. For feature/component
state, prefer the Signal Store (`references/signal-store.md`).

Everything here is the **standalone + functional** style. Don't reproduce NgModules,
`StoreModule.forRoot`, or class-based effects.

## Contents
1. Standalone bootstrapping
2. Actions (`createActionGroup`) & good hygiene
3. Reducers & `createFeature`
4. Functional effects
5. Selectors
6. Entity (`createEntityAdapter`)
7. File structure
8. Testing

---

## 1. Standalone bootstrapping

Keep `provideStore()` empty at the root; register features with `provideState()` and effects with
`provideEffects()` — ideally lazily, at the route level.

```ts
// app.config.ts
import { provideStore, provideState } from '@ngrx/store';
import { provideEffects } from '@ngrx/effects';
import { provideStoreDevtools } from '@ngrx/store-devtools';
import { isDevMode } from '@angular/core';

export const appConfig: ApplicationConfig = {
  providers: [
    provideStore(),                        // recommended: empty at root
    provideStoreDevtools({ maxAge: 25, logOnly: !isDevMode() }),
  ],
};

// books.routes.ts — feature state & effects registered lazily
export const routes: Route[] = [
  {
    path: 'books',
    providers: [provideState(booksFeature), provideEffects(booksEffects)],
    loadComponent: () => import('./book-list').then((m) => m.BookList),
  },
];
```

`provideState` accepts a feature creator (`provideState(booksFeature)`) or a `{ name, reducer }`
pair. Effects start running as soon as they're provided; registering the same effects in multiple
lazy features does not run them twice.

## 2. Actions — `createActionGroup` & good hygiene

Prefer `createActionGroup` (prevents duplicate types at compile time, no barrel files). Type
convention: `[Source] Event`.

```ts
// book-list-page.actions.ts — page/UI events
import { createActionGroup, emptyProps, props } from '@ngrx/store';

export const BookListPageActions = createActionGroup({
  source: 'Book List Page',
  events: {
    Opened: emptyProps(),
    'Query Changed': (query: string) => ({ query }),
    'Pagination Changed': props<{ page: number; offset: number }>(),
  },
});

// books-api.actions.ts — API result events (camelCase names -> matching creator names)
export const BooksApiActions = createActionGroup({
  source: 'Books API',
  events: {
    booksLoadedSuccess: props<{ books: Book[] }>(),
    booksLoadedFailure: props<{ errorMsg: string }>(),
  },
});
```

**Hygiene rules (the reason for the split above):**
- **Model events, not commands.** Dispatch `[Book List Page] Opened`, not `[Books] Set Loading`.
  Let the reducer/effect decide what happens.
- **One action per event source.** Never reuse a single action across a page, an API result, and
  an effect — each source gets its own group. Many cheap, descriptive actions beat a few reused
  ones; they make devtools traces readable.
- Group files by source: `*-page.actions.ts` vs `*-api.actions.ts`.

## 3. Reducers & `createFeature`

`createFeature` bundles the reducer with auto-generated selectors (feature selector
`select<Name>State` + one `selectX` per top-level property). This is the modern default — it
removes hand-written feature-key strings and boilerplate selectors.

```ts
// books.reducer.ts
import { createFeature, createReducer, on } from '@ngrx/store';

interface State {
  books: Book[];
  loading: boolean;
  activeBookId: string | null; // NOT activeBookId?: string — createFeature rejects optional props
}
const initialState: State = { books: [], loading: false, activeBookId: null };

export const booksFeature = createFeature({
  name: 'books',
  reducer: createReducer(
    initialState,
    on(BookListPageActions.opened, (state) => ({ ...state, loading: true })),
    on(BooksApiActions.booksLoadedSuccess, (state, { books }) => ({ ...state, books, loading: false })),
  ),
  extraSelectors: ({ selectBooks, selectActiveBookId }) => ({
    selectActiveBook: createSelector(
      selectBooks, selectActiveBookId,
      (books, id) => books.find((b) => b.id === id) ?? null,
    ),
  }),
});

export const {
  name, reducer,
  selectBooksState, selectBooks, selectLoading, selectActiveBookId,
  selectActiveBook,
} = booksFeature;
```

## 4. Functional effects

`createEffect(fn, { functional: true })` with deps injected as function args (best for testing).

```ts
// books.effects.ts
import { inject } from '@angular/core';
import { Actions, createEffect, ofType } from '@ngrx/effects';
import { mapResponse, concatLatestFrom } from '@ngrx/operators'; // NOT @ngrx/effects
import { exhaustMap, tap } from 'rxjs';

export const loadBooks = createEffect(
  (actions$ = inject(Actions), booksService = inject(BooksService)) =>
    actions$.pipe(
      ofType(BookListPageActions.opened),
      exhaustMap(() =>
        booksService.getAll().pipe(
          mapResponse({
            next: (books) => BooksApiActions.booksLoadedSuccess({ books }),
            error: (e: { message: string }) => BooksApiActions.booksLoadedFailure({ errorMsg: e.message }),
          }),
        ),
      ),
    ),
  { functional: true },
);

// non-dispatching effect
export const alertOnError = createEffect(
  (actions$ = inject(Actions)) =>
    actions$.pipe(
      ofType(BooksApiActions.booksLoadedFailure),
      tap(({ errorMsg }) => alert(errorMsg)),
    ),
  { functional: true, dispatch: false },
);
```

Key rules:
- **`catchError`/`mapResponse` must be *inside* the flattening operator** (`switchMap`/`exhaustMap`
  /`concatMap`/`mergeMap`) so an error doesn't complete the outer effect stream and stop it
  reacting to future actions.
- **`mapResponse`** (from `@ngrx/operators`) is the modern low-boilerplate success/error mapper —
  prefer it over manual `map` + `catchError`.
- **`concatLatestFrom`** (from `@ngrx/operators`, **not** `@ngrx/effects`) lazily reads store state
  only when the action fires: `concatLatestFrom(() => store.select(selectX))`.
- Register a namespace import: `import * as booksEffects from './books.effects'` →
  `provideEffects(booksEffects)`.
- `@ngrx/operators` is a separate package from `@ngrx/effects` — install it if it isn't already present.

## 5. Selectors

```ts
import { createSelector, createFeatureSelector } from '@ngrx/store';

// composition (up to 8 inputs)
export const selectVisibleBooks = createSelector(
  selectUser, selectAllBooks,
  (user, books) => (user ? books.filter((b) => b.userId === user.id) : books),
);

// view-model (dictionary) selector — no projector needed
export const selectBooksPageVm = createSelector({ books: selectBooks, query: selectQuery });
```

Consume in components as **signals** (modern default):

```ts
export class BookList {
  private readonly store = inject(Store);
  readonly vm = this.store.selectSignal(selectBooksPageVm);
}
```

`selectSignal` accepts an optional equality fn. Don't use **"selectors with props"** — deprecated,
removed in v23; use factory selectors or view-model selectors instead. `inject(Store)` without a
generic is fine (types are inferred from selectors).

## 6. Entity (`createEntityAdapter`)

```ts
import { EntityState, EntityAdapter, createEntityAdapter } from '@ngrx/entity';

export interface State extends EntityState<User> {
  selectedUserId: string | null;
}
export const adapter: EntityAdapter<User> = createEntityAdapter<User>({
  sortComparer: (a, b) => a.name.localeCompare(b.name), // or false (unsorted, faster)
});
export const initialState: State = adapter.getInitialState({ selectedUserId: null });

export const userReducer = createReducer(
  initialState,
  on(UserActions.loadUsersSuccess, (state, { users }) => adapter.setAll(users, state)),
  on(UserActions.updateUser, (state, { update }) => adapter.updateOne(update, state)), // Update<T>
  on(UserActions.deleteUser, (state, { id }) => adapter.removeOne(id, state)),
);

const { selectAll, selectEntities, selectIds, selectTotal } = adapter.getSelectors();
export const selectAllUsers = selectAll;
```

Methods: `addOne/addMany`, `setOne/setMany/setAll`, `updateOne/updateMany` (partial via
`Update<T> = { id, changes: Partial<T> }`), `upsertOne/upsertMany`, `removeOne/removeMany/removeAll`,
`mapOne/map`. Combine adapter selectors with `createFeature`/`createSelector`.

## 7. File structure

```
books/
├── book.model.ts
├── book-list-page.actions.ts   # page/UI events
├── books-api.actions.ts        # API result events
├── books.reducer.ts            # createFeature -> reducer + auto selectors (+ extraSelectors)
├── books.effects.ts            # functional effects, xxx$ names, inject() deps
└── books.selectors.ts          # only if you keep derived selectors out of createFeature
```

Conventions: action type `[Source] Event`; feature name a short lowercase string; effect fields end
in `$`; prefer `#private`/`inject()` over constructor injection; register state/effects in the
feature route's `providers` for lazy loading.

## 8. Testing

- **Reducers** — call directly (pure function). Unknown action → same reference; known action → new
  instance.
  ```ts
  expect(booksReducer(initialState, { type: 'Unknown' } as any)).toBe(initialState);
  expect(booksReducer(initialState, retrieved({ books }))).not.toBe(initialState);
  ```
- **Selectors** — test the projector, no store: `selectBookCollection.projector(allBooks, ['1','2'])`.
- **Functional effects** — plain function calls, pass fakes as args, no `TestBed`:
  ```ts
  loadBooks(of(BookListPageActions.opened()), { getAll: () => of(booksMock) } as BooksService)
    .subscribe((action) => { expect(action).toEqual(BooksApiActions.booksLoadedSuccess({ books: booksMock })); done(); });
  ```
- **Components/guards that select state** — `provideMockStore({ initialState, selectors: [{ selector, value }] })`
  from `@ngrx/store/testing`; override with `overrideSelector`, update via `setResult()` +
  `store.refreshState()`.
- **Class/marble effects** — `provideMockActions(() => actions$)` + RxJS `TestScheduler`.
