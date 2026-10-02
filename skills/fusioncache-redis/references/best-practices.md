# FusionCache + Redis — Best Practices Reference

Verified against official documentation, July 2026. Primary sources: the FusionCache docs
(https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/README.md), Redis docs
(https://redis.io/docs/latest/), and the StackExchange.Redis docs
(https://stackexchange.github.io/StackExchange.Redis/). Full URL list at the bottom.
This file extends `SKILL.md` — read that first for the standard wiring and usage pattern.

## Current versions (July 2026)

| Component | Version | Notes |
|---|---|---|
| ZiggyCreatures.FusionCache | **2.9.0** (2026-09-22) | Targets netstandard2.0 / net8.0 / net9.0 / net10.0. AOT-compatible since 2.2.0. Verified October 2026. |
| StackExchange.Redis | **3.0.17** (2026-07-10) | v3.0 line is new (June 2026); 2.13.x was the prior stable line. Check the 3.0 release notes before upgrading a 2.x app. |
| Redis Open Source | **8.8.0** GA (2026-05-25) | 8.x line; 8.6 added the LRM (least-recently-modified) eviction policies. |

Notable in FusionCache 2.5/2.6: optional **distributed-level stampede protection** via
`IFusionCacheDistributedLocker` (see below), `MemoryCacheDuration` entry option as a
cache-coherence mitigation when no backplane exists, configurable cleanup behavior for
`RemoveByTag()`, and a built-in Best Practices Advisor that flags configuration issues.

Notable in 2.7–2.9 (use **≥ 2.9.0**): builder extensions `WithRedisDistributedLocker()` (2.8)
next to `WithStackExchangeRedisBackplane()`; fixes for distributed locks not being released
(`SkipDistributedCacheWrite` in 2.8, failed L1 write in 2.9) and for an expired tag marker being
re-materialized with a newer timestamp, which acted like a spurious `RemoveByTag()` (2.8); eager
refresh now checks L2 before running the factory (2.9); the Advisor warns when the System.Text.Json
serializer cannot round-trip value tuples (2.7) — cache records, not tuples.

## Established patterns

### The resilience trio: fail-safe + soft timeout + eager refresh

These three are designed to be combined; the docs call the combination "fresh data as soon as
possible + no blocking + complete protection from cache stampede". Verified semantics:

- **Fail-safe** must be enabled *at write time* (`IsFailSafeEnabled` when the entry is saved).
  On factory failure after logical expiry, the stale value is re-served and re-cached for
  `FailSafeThrottleDuration` (throttles retry pressure); `FailSafeMaxDuration` is the absolute
  ceiling after which the entry is physically gone. Fail-safe only applies to `GetOrSet(Async)`
  (there is a factory to fail); for read-only calls like `TryGet` use `AllowStaleOnReadOnly`.
- **`FactorySoftTimeout` only fires when fail-safe is enabled AND a stale value exists.**
  Without both, it is inert. `FactoryHardTimeout` fires unconditionally and throws
  `SyntheticTimeoutException` — handle it. Soft must be lower than hard.
- After a soft timeout the factory **keeps running in the background** and updates the cache
  when it completes (`AllowTimedOutFactoryBackgroundCompletion`, default `true`). You get a fast
  stale answer now and fresh data moments later, for free.
- **Eager refresh** is passive: no timers. `EagerRefreshThreshold` must be `> 0.0` and `< 1.0`
  (anything else is treated as null = disabled). A request arriving after the threshold but
  before expiry serves the cached value instantly and triggers one background refresh — only the
  first such request triggers it (stampede-safe). Keep the threshold high (0.8+); low values
  cause near-constant refreshes against your data source.

Two fail-safe refinements worth using:

```csharp
public sealed class ExchangeRateService(IFusionCache cache, IRatesApi api)
{
    public async Task<RateDto> GetRateAsync(string pair, CancellationToken ct) =>
        await cache.GetOrSetAsync<RateDto>(
            CacheKeys.Rate(pair),
            async (ctx, token) =>
            {
                var result = await api.TryGetRateAsync(pair, token);
                if (result.IsFailure)
                    return ctx.Fail(result.Error); // trigger fail-safe without throwing
                return result.Value;
            },
            failSafeDefaultValue: RateDto.Unavailable, // cold start: no stale value yet
            token: ct);
}
```

`ctx.Fail(...)` activates fail-safe for Result-style factories (no exception needed);
`failSafeDefaultValue` covers the first-ever call when there is no stale entry to fall back on.

### Defaults are conservative — own your `DefaultEntryOptions`

Out of the box: `Duration` 30s, fail-safe **off**, no timeouts, no jitter, no eager refresh,
`AllowBackgroundDistributedCacheOperations` **off**. The SKILL.md wiring exists precisely
because FusionCache's shipped defaults are deliberately safe/minimal. Recommended flow (per
Options.md): set a solid `DefaultEntryOptions` baseline once, then customize per call with the
**lambda** overload (`options => options.SetDuration(...)`) — the lambda starts from a duplicate
of the defaults and applies your delta. Passing a fresh `FusionCacheEntryOptions` instance
bypasses the defaults entirely; avoid it unless that is the intent.

### Tagging: `RemoveByTag` is a logical barrier, not a mass delete

Verified from Tagging.md: `RemoveByTag("products")` writes one special entry
(`__fc:t:products`) containing the current timestamp. Nothing is scanned or eagerly deleted.
On every read of a tagged entry, FusionCache lazily compares the entry's creation time against
its tags' barrier timestamps — older entries are treated as expired ("a sort of 'barrier' or
'high-pass filter'"). Consequences:

- `RemoveByTag` is O(1) regardless of how many entries carry the tag — safe on hot paths.
- Do not expect Redis key counts to drop; invalidated entries linger until natural expiry
  (v2.6.0 added configurable cleanup behavior for `RemoveByTag()`).
- Tag-barrier lookups are cheap and amortized (shared tags load once, reused across entries),
  but **avoid overtagging** — the docs compare too many tags per entry to high-cardinality
  labels in observability systems. A handful of coarse tags per entry is the sweet spot.
- With multiple nodes, tag barriers propagate via the backplane; without one you get temporary
  cache incoherence. Docs: "you should always use the backplane, as that is THE way to solve
  cache coherence for good."
- `Clear()` is built on the same mechanism (a `*` tag) and the HybridCache adapter supports
  `RemoveByTag("*")` since 2.6.0.

### Backplane + auto-recovery

- The Redis backplane uses **pub/sub**; notifications are metadata only (key, timestamp, action
  type) — never the cached value. Nodes that hold the entry in L1 re-fetch from L2; nodes that
  don't simply evict and lazily reload on next access.
- Point the backplane at the **same Redis** as L2 — connection reuse is explicitly fine.
- Backplane channels embed a wire-format version (`...Backplane:v1`), so mixed FusionCache
  versions can coexist on one Redis during rolling upgrades.
- **Auto-recovery is on by default** and covers transient failures of both L2 and the
  backplane: failed distributed operations go into an internal queue that is periodically
  processed; duplicates per key are consolidated (latest wins) and superseded items are dropped.
  You do not need to write retry code for the distributed side.
- Backplane **without** an L2 is a special mode: set
  `DefaultEntryOptions.SkipBackplaneNotifications = true` and re-enable per call only where you
  explicitly publish changes; otherwise every `Set` from every node evicts everyone else's L1
  with no shared L2 to refill from.
- No backplane at all in multi-node? `MemoryCacheDuration` (v2.5+) caps how long L1 can be out
  of sync — the docs call this a *mitigation*, not a solution.

### Distributed stampede protection (distributed locker)

The in-memory locker (always on) limits a cold key to **one factory run per node**; a distributed
locker limits it to **one across all nodes**. The docs' own verdict: going from 100,000 queries to
10 is the big win, from 10 to 1 "less so" — and every factory run then pays a Redis lock round-trip.
Add it only for **expensive or rate-limited factories in multi-node setups** (heavy aggregations,
paid/throttled external APIs):

```csharp
// package ZiggyCreatures.FusionCache.Locking.Distributed.Redis (>= 2.9.0), same multiplexer as in SKILL.md
    .WithRedisDistributedLocker(o => o.ConnectionMultiplexerFactory = () => redis.Value);
```

Opt cheap calls out per call with `options => options.SetSkipDistributedLocker(true)` (or set
`SkipDistributedLocker = true` in `DefaultEntryOptions` and opt the expensive calls back in). It is
an **efficiency** measure, not a correctness lock — never rely on it for "only one node does X"; use
a real distributed lock (raw Redis, DB) for that.

### Named caches

`services.AddFusionCache("Products")` registers an isolated instance (own duration defaults,
serializer, L2, backplane). Consume via `IFusionCacheProvider.GetCache("Products")` (mirrors
`IHttpClientFactory`) or .NET keyed DI (`[FromKeyedServices("Products")]`). When several named
caches (or several apps) share one Redis, call `WithCacheKeyPrefixByCacheName()` so keys become
`Products:...` automatically — never rely on discipline to avoid collisions.

### HybridCache adapter

`services.AddFusionCache().AsHybridCache()` exposes the *same* instance as both `IFusionCache`
and Microsoft's `HybridCache` — mixed consumers share data, stampede protection, tags,
fail-safe, and the backplane. Key verified facts: Microsoft's default HybridCache
implementation **lacks multi-node invalidation** (FusionCache's backplane fixes that
transparently); `HybridCacheEntryOptions` exposes far fewer knobs than
`FusionCacheEntryOptions` (no timeouts, no eager refresh per call) so tune via
`DefaultEntryOptions`; `AsKeyedHybridCache("Name")` gives named HybridCache instances, which
Microsoft's design does not offer. Use the adapter only where a library demands `HybridCache`;
first-party code should inject `IFusionCache`.

### OpenTelemetry

Package `ZiggyCreatures.FusionCache.OpenTelemetry`; FusionCache is listed in the official OTel
registry. Wire-up:

```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing.AddFusionCacheInstrumentation())
    .WithMetrics(metrics => metrics.AddFusionCacheInstrumentation());
```

Traces/metrics cover high-level operations (GetOrSet/Set/Remove, hit/miss) and, optionally,
low-level memory/distributed/backplane activity. Turn this on from day one — cache hit ratio is
the first number you need when tuning durations.

### Redis production settings for a pure cache workload

- **`maxmemory`**: always set it (64-bit default is 0 = unbounded). Leave headroom if
  replication is on — replication/AOF buffers are *excluded* from the eviction accounting.
- **`maxmemory-policy allkeys-lru`**: the documented "good default option" (Pareto-shaped
  access). `allkeys-lfu` if a stable hot set dominates. The default `noeviction` turns a full
  cache into write errors — never ship it for a cache. Since every FusionCache entry has a TTL,
  `volatile-*` would also work; prefer `allkeys-*` anyway — it never runs out of eviction
  candidates, and FusionCache tolerates arbitrary eviction by design.
- **Persistence off**: RDB and AOF both disabled (`save ""`, `appendonly no`). The persistence
  docs state it plainly: "You can disable persistence completely. This is sometimes used when
  caching." Everything in a FusionCache L2 is reconstructible from the source of truth.
- **Only reconstructible data in this Redis.** Anything that must survive a restart or eviction —
  ASP.NET Core Data Protection keys above all (`bff-security`) — goes to the database or a separate,
  persistent `noeviction` Redis, never into the cache instance.
- **Keyspace notifications**: leave `notify-keyspace-events` at its default (disabled, "the
  feature uses some CPU power"). FusionCache does not use them — the backplane runs on its own
  pub/sub channel.
- **Dedicated instance**: docs recommend running cache and durable data on *separate* Redis
  instances rather than mixing policies on one.
- **Monitor**: `INFO stats` → `keyspace_hits / (keyspace_hits + keyspace_misses)` for hit
  ratio; high `evicted_keys` means wrong policy or undersized `maxmemory`.

### StackExchange.Redis connection

- `ConnectionMultiplexer` is thread-safe and "designed to be shared and reused" — one instance
  per Redis endpoint for the application lifetime. `RedisCache`, the Redis backplane and the
  Redis distributed locker each open their **own** multiplexer from a `Configuration` string;
  pass the same `ConnectionMultiplexerFactory` to all of them (as in SKILL.md — the pattern the
  FusionCache docs show). Raw StackExchange.Redis for non-cache work (locks, streams) gets its
  own singleton, ideally on the separate durable instance.
- Connection string for cache workloads: `abortConnect=false` so the app starts even if Redis
  is briefly down (this is Azure's default for exactly that reason) — with FusionCache this is
  what lets the app degrade to L1-only instead of failing at startup.
- Reconnects are automatic with exponential backoff (`ReconnectRetryPolicy`); do not write
  reconnect loops. Leave `allowAdmin=false` unless an ops tool truly needs it.

### Testing cached code

`dotnet-testing` forbids mocking `IFusionCache`. Use real instances and substitute the factory's
dependencies instead.

```csharp
[Fact]
public async Task Second_read_is_a_cache_hit()
{
    var ct = TestContext.Current.CancellationToken;
    using var cache = new FusionCache(new FusionCacheOptions());   // memory-only, no Redis
    var api = Substitute.For<IRatesApi>();
    api.GetRateAsync("EURUSD", Arg.Any<CancellationToken>()).Returns(new RateDto(1.1m));
    var sut = new RateService(cache, api);

    await sut.GetAsync("EURUSD", ct);
    await sut.GetAsync("EURUSD", ct);

    await api.Received(1).GetRateAsync("EURUSD", Arg.Any<CancellationToken>());
}

[Fact]
public async Task Factory_failure_serves_stale_value()
{
    var ct = TestContext.Current.CancellationToken;
    using var cache = new FusionCache(new FusionCacheOptions
    {
        DefaultEntryOptions = new FusionCacheEntryOptions { IsFailSafeEnabled = true },
    });
    var api = Substitute.For<IRatesApi>();
    api.GetRateAsync("EURUSD", Arg.Any<CancellationToken>()).Returns(
        Task.FromResult(new RateDto(1.1m)),
        Task.FromException<RateDto>(new HttpRequestException()));
    var sut = new RateService(cache, api);

    await sut.GetAsync("EURUSD", ct);                              // prime
    await cache.ExpireAsync(CacheKeys.Rate("EURUSD"), token: ct);  // logically expired, stale kept
    var rate = await sut.GetAsync("EURUSD", ct);                   // factory throws → fail-safe

    Assert.Equal(1.1m, rate.Rate);
}
```

Soft timeout works the same way: set `FactorySoftTimeout` (e.g. 50 ms) and return a
`TaskCompletionSource<T>().Task` that never completes on the second call — the stale value must
come back without waiting. No `Task.Delay`-based expiry anywhere.

Cross-node behavior (L2 + backplane) needs a real Redis and two cache instances in one process:

```csharp
// Redis comes from an assembly/collection fixture (one container per test run — dotnet-testing),
// e.g. a RedisFixture wrapping new RedisBuilder("redis:8").Build() (Testcontainers.Redis).
public sealed class CacheBackplaneTests(RedisFixture redis)
{
[Fact]
public async Task Write_on_node_A_is_seen_by_node_B()
{
    var ct = TestContext.Current.CancellationToken;
    using var nodeA = CreateNode(redis.GetConnectionString());
    using var nodeB = CreateNode(redis.GetConnectionString());

    await nodeA.SetAsync("product:1", new ProductDto(1, "old"), token: ct);
    Assert.Equal("old", (await nodeB.GetOrDefaultAsync<ProductDto>("product:1", token: ct))!.Name);

    await nodeA.SetAsync("product:1", new ProductDto(1, "new"), token: ct); // backplane evicts B's L1

    var deadline = DateTime.UtcNow.AddSeconds(5);                  // pub/sub is async: poll
    ProductDto? seen;
    while ((seen = await nodeB.GetOrDefaultAsync<ProductDto>("product:1", token: ct))!.Name != "new"
           && DateTime.UtcNow < deadline)
        await Task.Delay(50, ct);
    Assert.Equal("new", seen!.Name);

    static FusionCache CreateNode(string redisConnection)
    {
        var cache = new FusionCache(new FusionCacheOptions());
        cache.SetupDistributedCache(
            new RedisCache(new RedisCacheOptions { Configuration = redisConnection }),
            new FusionCacheSystemTextJsonSerializer(
                new JsonSerializerOptions { TypeInfoResolver = AppJsonContext.Default })); // the app's real options
        cache.SetupBackplane(new RedisBackplane(new RedisBackplaneOptions { Configuration = redisConnection }));
        return cache;
    }
}
}
```

Use distinct keys per test (or a per-test `CacheKeyPrefix`) since the container is shared.

Use the app's real serializer options there — it is the test that catches a missing source-gen
envelope type. In `WebApplicationFactory` tests, point the `Redis` connection string at the
container instead of replacing FusionCache.

## Anti-patterns

| Anti-pattern | Why it is wrong | Fix |
|---|---|---|
| `FactorySoftTimeout` with fail-safe disabled | Soft timeout requires fail-safe **and** a stale entry; otherwise it never triggers | Enable `IsFailSafeEnabled` in `DefaultEntryOptions` |
| `EagerRefreshThreshold = 1.0f` (or `0f`) | Values outside `(0.0, 1.0)` are treated as null — feature silently off | Use e.g. `0.8f`; assert options in tests |
| `EagerRefreshThreshold = 0.1f` | Near-every request schedules a background refresh — hammers the source | Keep it high (0.8–0.9) |
| Expecting `RemoveByTagAsync` to delete Redis keys immediately | It writes one timestamp barrier; entries are hidden lazily on read | Accept logical expiry; rely on TTLs (or v2.6 cleanup behavior) for physical space |
| Tagging entries with per-user/per-request tags | Overtagging = high cardinality; per-entry barrier checks multiply | Few coarse tags (`"products"`), exact-key `RemoveAsync` for the rest |
| Reading L2/Redis directly right after a write with `AllowBackgroundDistributedCacheOperations = true` | Distributed write is fire-and-forget; you may read stale/missing | Read through FusionCache (L1 is already updated), or disable background ops for that call |
| `FactoryHardTimeout` with no exception handling | It throws `SyntheticTimeoutException` by design | Catch it at the call site, or prefer soft timeout + fail-safe |
| Fail-safe on but no `failSafeDefaultValue` for cold-start-critical external calls | First-ever call has no stale value — failure still surfaces | Pass `failSafeDefaultValue` where a placeholder is acceptable |
| New `ConnectionMultiplexer` per operation (or in `using`) | Docs: it is meant to be shared and held "for the application's lifetime" | One singleton per endpoint |
| Distributed locker used as a "run once cluster-wide" guarantee | It is an efficiency optimization, not a correctness lock | Real distributed lock for correctness; locker only for expensive/rate-limited factories |
| Source-gen-only `TypeInfoResolver` without FusionCache's envelope types | Every L2 write throws `FusionCacheSerializationException` — L1 keeps working, so it hides | Add `FusionCacheDistributedEntry<T>` per cached type + `<long>` to the context (SKILL.md); the two-node test catches it |
| Default `abortConnect=true` against cloud Redis | App fails to start during a Redis blip instead of degrading to L1 | `abortConnect=false` in the connection string |
| `noeviction` (server default) on a cache instance | Full memory ⇒ write errors ⇒ degraded cache, not evictions | `maxmemory` + `allkeys-lru` |
| AOF/RDB enabled on a pure cache | fork() latency spikes, disk I/O, slower restarts — for data you can rebuild | Disable persistence; if the instance also holds durable data, split into two instances |
| Enabling keyspace notifications to drive invalidation | Fire-and-forget pub/sub, CPU cost, cluster-node-local; reinvents the backplane badly | Use the FusionCache backplane |
| Backplane with no L2 and default notifications | Every write evicts all other nodes' L1 with nothing to refill from | Either add L2, or `SkipBackplaneNotifications = true` by default and opt in per publish |
| Multiple apps / named caches sharing Redis without prefixes | Key and wire-format collisions | `WithCacheKeyPrefixByCacheName()` (and per-app prefixes) |
| Registering Microsoft's `AddHybridCache()` alongside FusionCache | Two competing caches, no backplane on one of them | `AddFusionCache().AsHybridCache()` — one instance, both interfaces |

## Sources

- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/README.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/Options.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/FailSafe.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/Timeouts.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/EagerRefresh.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/Tagging.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/Backplane.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/BackgroundDistributedOperations.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/CacheStampede.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/AutoRecovery.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/CacheLevels.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/NamedCaches.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/MicrosoftHybridCache.md
- https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/OpenTelemetry.md
- https://github.com/ZiggyCreatures/FusionCache/releases
- https://www.nuget.org/packages/ZiggyCreatures.FusionCache
- https://www.nuget.org/packages/StackExchange.Redis
- https://github.com/redis/redis/releases
- https://redis.io/docs/latest/develop/reference/eviction/
- https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- https://redis.io/docs/latest/develop/pubsub/keyspace-notifications/
- https://stackexchange.github.io/StackExchange.Redis/Basics
- https://stackexchange.github.io/StackExchange.Redis/Configuration
