---
name: fusioncache-redis
description: Use when adding or changing caching in .NET — cache keys, invalidation, Redis, IDistributedCache, HybridCache, cache stampede/thundering herd, stale data, or slow reads that should be cached. FusionCache is the standard; never hand-roll IMemoryCache+Redis combos.
---

# FusionCache + Redis

## Overview

All application caching goes through **FusionCache** (v2+): L1 in-memory + L2 Redis distributed cache + Redis backplane for cross-node invalidation. It gives stampede protection, fail-safe, soft timeouts, and eager refresh for free — never reimplement those.

Do **not** use `IMemoryCache`, `IDistributedCache`, or raw `StackExchange.Redis` for app data caching directly. (Raw Redis is fine for non-cache uses: locks, streams, counters.)

## Wiring

```csharp
builder.Services.AddStackExchangeRedisCache(o =>
    o.Configuration = builder.Configuration.GetConnectionString("Redis"));

builder.Services.AddFusionCache()
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
    .WithSerializer(new FusionCacheSystemTextJsonSerializer())
    .WithRegisteredDistributedCache()
    .WithBackplane(new RedisBackplane(new RedisBackplaneOptions
    {
        Configuration = builder.Configuration.GetConnectionString("Redis"),
    }));
```

Packages: `ZiggyCreatures.FusionCache`, `ZiggyCreatures.FusionCache.Serialization.SystemTextJson`, `ZiggyCreatures.FusionCache.Backplane.StackExchangeRedis`, `Microsoft.Extensions.Caching.StackExchangeRedis`.

FusionCache also implements Microsoft's `HybridCache` abstraction (`AsHybridCache()`) if a library demands it.

## Usage pattern

```csharp
public sealed class ProductService(IFusionCache cache, AppDbContext db)
{
    public async Task<ProductDto?> GetAsync(int id, CancellationToken ct) =>
        await cache.GetOrSetAsync(
            CacheKeys.Product(id),
            async (ctx, token) =>
            {
                var product = await db.Products.AsNoTracking()
                    .Where(p => p.Id == id)
                    .Select(p => p.ToDto())
                    .FirstOrDefaultAsync(token);
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

## Key & tag conventions

- Central `static class CacheKeys`: `public static string Product(int id) => $"product:{id}";` — never inline string keys.
- Key format: `{entity}:{id}` or `{entity}:{qualifier}:{value}`, lowercase, colon-separated.
- Tags (FusionCache v2) for group invalidation: tag every entry with its entity collection (`"products"`) so writes can `RemoveByTagAsync`.
- Cache **DTOs/projections, never EF entities** (tracking references + serialization pitfalls).
- Version keys when the shape changes: `product:v2:{id}` avoids poisoned deserialization after deploys.

## What to cache

| Cache | Don't cache |
|---|---|
| Read-heavy reference data (lookups, config) | Per-user unless keyed by user id |
| Expensive query projections | Anything transactional/consistency-critical |
| External API responses (with fail-safe) | Large blobs (>~1 MB — Redis pressure) |

Invalidate on write (explicit `RemoveAsync`/`RemoveByTagAsync` in the code path that mutates), rely on duration+jitter as the safety net — not the primary mechanism.

## Common mistakes

| Mistake | Fix |
|---|---|
| `GetAsync` + manual `SetAsync` | `GetOrSetAsync` — it's the stampede-protected path |
| No jitter | Synchronized mass expiry hammers the DB |
| Fail-safe off for external calls | Serving slightly stale beats a 500 |
| Caching entities with nav properties | Cache flat DTOs |
| Invalidation without backplane in multi-node | Other nodes serve stale L1 for the full duration |
| Redis down = app down | L2 problems must degrade to L1-only (soft timeouts + background distributed ops, as wired above) |

## Official docs — verify, don't guess

When an API or behavior is uncertain or newer than your knowledge, WebFetch/WebSearch the official docs instead of guessing:
- FusionCache (docs index): https://github.com/ZiggyCreatures/FusionCache/blob/main/docs/README.md
- Redis: https://redis.io/docs/latest/
- StackExchange.Redis client: https://stackexchange.github.io/StackExchange.Redis/
