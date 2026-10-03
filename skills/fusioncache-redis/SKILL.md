---
name: fusioncache-redis
description: Use when adding or changing caching in .NET — cache keys, invalidation, Redis, Redis connection setup, IDistributedCache, HybridCache, output cache vs data cache, cache stampede/thundering herd, stale data, testing cached code, or slow reads that should be cached. FusionCache is the standard; never hand-roll IMemoryCache+Redis combos.
---

# FusionCache + Redis

## Overview

All application caching goes through **FusionCache** (v2+): L1 in-memory + L2 Redis distributed cache + Redis backplane for cross-node invalidation. It gives stampede protection, fail-safe, soft timeouts, and eager refresh for free — never reimplement those.

Do **not** use `IMemoryCache`, `IDistributedCache`, or raw `StackExchange.Redis` for app data caching directly. (Raw Redis is fine for non-cache uses: locks, streams, counters.)

## Wiring

```csharp
// One multiplexer for L2 + backplane. AbortOnConnectFail = false (= abortConnect=false in the
// connection string): the app starts and degrades to L1-only while Redis is unreachable.
var redisOptions = ConfigurationOptions.Parse(builder.Configuration.GetConnectionString("Redis")!);
redisOptions.AbortOnConnectFail = false;
var redis = new Lazy<Task<IConnectionMultiplexer>>(
    async () => await ConnectionMultiplexer.ConnectAsync(redisOptions));

builder.Services.AddStackExchangeRedisCache(o => o.ConnectionMultiplexerFactory = () => redis.Value);

builder.Services.AddFusionCache()
    .WithCacheKeyPrefix("shop:")                        // app isolation on a shared Redis
    .WithDefaultEntryOptions(new FusionCacheEntryOptions
    {
        Duration = TimeSpan.FromMinutes(5),
        JitterMaxDuration = TimeSpan.FromSeconds(10),   // avoid synchronized expiry
        IsFailSafeEnabled = true,                       // serve stale on factory failure
        FailSafeMaxDuration = TimeSpan.FromHours(2),
        FailSafeThrottleDuration = TimeSpan.FromSeconds(30),
        FactorySoftTimeout = TimeSpan.FromMilliseconds(300), // return stale, refresh in bg
        FactoryHardTimeout = TimeSpan.FromSeconds(5),
        EagerRefreshThreshold = 0.8f,                   // refresh in bg at 80% of lifetime
        DistributedCacheSoftTimeout = TimeSpan.FromSeconds(1),
        AllowBackgroundDistributedCacheOperations = true,
    })
    .WithSerializer(new FusionCacheSystemTextJsonSerializer(
        new JsonSerializerOptions { TypeInfoResolver = AppJsonContext.Default }))
    .WithRegisteredDistributedCache()
    .WithStackExchangeRedisBackplane(o => o.ConnectionMultiplexerFactory = () => redis.Value);
```

**Source-generated serializer:** FusionCache stores each L2 value inside its own envelope, so the
context must list the envelope per cached type plus `long` (tag/`Clear()` barriers) — a missing type
throws `FusionCacheSerializationException` on the first L2 write:

```csharp
[JsonSerializable(typeof(ProductDto))]
[JsonSerializable(typeof(FusionCacheDistributedEntry<ProductDto>))] // ZiggyCreatures.Caching.Fusion.Internals.Distributed
[JsonSerializable(typeof(FusionCacheDistributedEntry<long>))]
internal sealed partial class AppJsonContext : JsonSerializerContext;   // the app's one context (aspnet-backend)
```

Packages: `ZiggyCreatures.FusionCache`, `ZiggyCreatures.FusionCache.Serialization.SystemTextJson`, `ZiggyCreatures.FusionCache.Backplane.StackExchangeRedis`, `Microsoft.Extensions.Caching.StackExchangeRedis`.

FusionCache also implements Microsoft's `HybridCache` abstraction (`AsHybridCache()`) if a library demands it.

## Usage pattern

**Factories may outlive the request.** With `FactorySoftTimeout` (timed-out factories keep running in
the background by default) and `EagerRefreshThreshold`, the factory can run *after* the request has
returned and its scope is disposed. A factory must therefore never use a request-scoped service
(`DbContext`, anything that depends on one) captured from the constructor — create its own scope:

```csharp
public sealed class ProductService(IFusionCache cache, IDbContextFactory<AppDbContext> dbFactory)
{
    public async Task<ProductDto?> GetAsync(int id, CancellationToken ct) =>
        await cache.GetOrSetAsync<ProductDto?>(
            CacheKeys.Product(id),
            async (ctx, token) =>
            {
                // own context per factory run — safe when it runs in the background after the request
                await using var db = await dbFactory.CreateDbContextAsync(token);
                // multi-tenant app only: db.TenantId = tenantId; — a method parameter (also in the key), never ambient
                var product = await db.Products.AsNoTracking()
                    .Where(p => p.Id == id)
                    .Select(p => new ProductDto(p.Id, p.Name))   // inline projection: SELECT id, name only
                    .FirstOrDefaultAsync(token);                  // (a .ToDto() method call loads the whole entity)
                if (product is null)
                    ctx.Options.Duration = TimeSpan.FromSeconds(30); // short negative caching
                return product;
            },
            options => options.SetDuration(TimeSpan.FromMinutes(10)),
            tags: ["products"],
            ct);

    public async Task InvalidateAsync(int id, CancellationToken ct)
    {
        await cache.RemoveAsync(CacheKeys.Product(id), token: ct);   // exact key
        // or, category-wide: await cache.RemoveByTagAsync("products", token: ct);
    }
}
```

`IDbContextFactory<AppDbContext>` comes from the one canonical registration in `data-access` → "DbContext
registration" (`AddPooledDbContextFactory`, which also provides the scoped `AppDbContext` for request
code) — don't add a second registration here. A context from the factory has no request, so under
`bff-security`'s tenant model (`references/authorization.md`) its `TenantId` is `Guid.Empty` — it sees no
rows and refuses tenant-owned inserts. In a multi-tenant app set `db.TenantId` right after
`CreateDbContextAsync`, from the tenant id the method takes as a parameter (the same one in the cache key).
For other scoped dependencies inside a cache factory, use
`IServiceScopeFactory`: `await using var scope = scopeFactory.CreateAsyncScope();`.

**Invalidation is not instantly global.** With background distributed operations on, `RemoveAsync` /
`RemoveByTagAsync` return once L1 is updated; L2 and the backplane follow, so another node can serve the
old value for a few milliseconds. Where the next request on another node must see the write, make that
call wait:

```csharp
await cache.RemoveAsync(CacheKeys.Product(id), o =>
{
    o.AllowBackgroundDistributedCacheOperations = false;
    o.AllowBackgroundBackplaneOperations = false;
}, ct);
// RemoveByTagAsync takes options, not a lambda: cache.CreateEntryOptions(o => { ...same two lines... })
```

## Key & tag conventions

- Central `static class CacheKeys`: `public static string Product(int id) => $"product:{id}";` — never inline string keys.
- Key format: `{entity}:{id}` or `{entity}:{qualifier}:{value}`, lowercase, colon-separated.
- **Tenant- or user-scoped data MUST carry the tenant/user id in the key**: `{tenant}:{entity}:{id}`
  (`CacheKeys.Order(tenantId, id)`). A key without it serves one tenant's data to another — a security
  bug, not a cache bug. Pass the id in as a parameter; never read it from ambient context (`HttpContext`,
  a scoped tenant accessor) inside the factory — it may run after the request is gone.
- `WithCacheKeyPrefix("app:")` (or `WithCacheKeyPrefixByCacheName()` for named caches) when several
  apps share one Redis.
- Tags (FusionCache v2) for group invalidation: tag every entry with its entity collection (`"products"`) so writes can `RemoveByTagAsync`.
- Cache **DTOs/projections, never EF entities** (tracking references + serialization pitfalls).
- Version keys when the shape changes: `product:v2:{id}` avoids poisoned deserialization after deploys.

## What to cache

| Cache | Don't cache |
|---|---|
| Read-heavy reference data (lookups, config) | Tenant/user data without the id in the key |
| Expensive query projections | Anything transactional/consistency-critical |
| External API responses (with fail-safe) | Large blobs (>~1 MB — Redis pressure) |

Invalidate on write (explicit `RemoveAsync`/`RemoveByTagAsync` in the code path that mutates), rely on duration+jitter as the safety net — not the primary mechanism.

This is the **data** cache. Whole HTTP responses belong to ASP.NET Core output caching (`aspnet-backend`);
use it for anonymous, identical-for-everyone responses and FusionCache for the data behind
per-user/per-tenant responses.

## Testing

Never mock `IFusionCache` (`dotnet-testing`) — use a real one:
- **Unit tests**: `new FusionCache(new FusionCacheOptions())` — memory-only, no Redis; substitute the
  factory's dependency and assert it was called once for two reads.
- **Fail-safe / timeouts, deterministically**: prime the entry, `await cache.ExpireAsync(key)`
  (logically expired, stale kept), then make the substituted dependency throw or never complete →
  assert the stale value comes back. No sleeps.
- **L2 + backplane**: Testcontainers Redis and **two** FusionCache instances on it; set on node A,
  poll node B until it sees the new value (pub/sub is async).

Code for all three: [references/best-practices.md](references/best-practices.md#testing-cached-code).

## Common mistakes

| Mistake | Fix |
|---|---|
| Factory uses a constructor-injected `DbContext` / scoped service | It may run after the request ended (soft timeout, eager refresh) → `ObjectDisposedException` or "second operation on this context", hidden by fail-safe. Use `IDbContextFactory<T>` or `IServiceScopeFactory` inside the factory |
| `GetAsync` + manual `SetAsync` | `GetOrSetAsync` — it's the stampede-protected path |
| No jitter | Synchronized mass expiry hammers the DB |
| Fail-safe off for external calls | Serving slightly stale beats a 500 |
| Caching entities with nav properties | Cache flat DTOs |
| Invalidation without backplane in multi-node | Other nodes serve stale L1 for the full duration |
| Redis down = app down | L2 problems must degrade to L1-only (`abortConnect=false` + soft timeouts + background distributed ops, as wired above) |
| Key missing tenant/user id | Cross-tenant data leak — put the id in the key |
| One multiplexer each for L2, backplane, locker | Share one via `ConnectionMultiplexerFactory` |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- FusionCache (docs index): https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/README.md
- Redis: https://redis.io/docs/latest/
- StackExchange.Redis client: https://stackexchange.github.io/StackExchange.Redis/
- **Established patterns & current versions (verified October 2026): [references/best-practices.md](references/best-practices.md) — read it before writing code in this area.**
