# Authorization — policies, resource-based checks, tenant isolation

Verified against official documentation, October 2026 (learn.microsoft.com: policy-based authorization incl. default/fallback policies, resource-based authorization, EF Core global/named query filters, EF Core DbContext pooling with per-request state). Extends `SKILL.md` (fallback policy + `AllowAnonymous` opt-outs live there).

Three layers, each catching what the previous can't:

| Layer | Question | Mechanism |
|---|---|---|
| Endpoint | May this user call this endpoint at all? | Fallback policy, named policies on groups/endpoints |
| Resource | May this user do *this* to *that* order? | `IAuthorizationService.AuthorizeAsync(user, resource, requirement)` after loading it |
| Data | Can a query even *see* another tenant's rows? | EF Core named query filter `"Tenant"` + tenant stamped on writes |

## Policies and requirements

```csharp
builder.Services.AddAuthorizationBuilder()
    .SetFallbackPolicy(new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build())
    .AddPolicy(Policies.OrdersWrite, p => p.RequireClaim("permission", "orders:write"))
    .AddPolicy(Policies.Admin, p => p.RequireRole("admin"));

builder.Services.AddSingleton<IAuthorizationHandler, OrderAuthorizationHandler>(); // stateless → singleton;
                                                                                    // needs a DbContext → scoped

orders.MapPost("/", Create).RequireAuthorization(Policies.OrdersWrite);

public static class Policies
{
    public const string OrdersWrite = "orders:write";
    public const string Admin = "admin";
}
```

- Policy names are constants; claims come from the session principal created at sign-in (`CreatePrincipal`) — keep the claim set small, the cookie carries it on every request.
- A permission change must take effect: bump the security stamp (SKILL.md → session versioning) so `ValidatePrincipal` rejects the old cookie, or look permissions up server-side (cached) instead of baking them into claims.
- Combining: several `RequireAuthorization(...)` calls on nested groups **all** have to pass (documented policy combination).

## Resource-based authorization

Endpoint policies can't see the resource. Load it, then ask:

```csharp
public sealed class OrderAuthorizationHandler
    : AuthorizationHandler<OperationAuthorizationRequirement, Order>
{
    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext context, OperationAuthorizationRequirement requirement, Order order)
    {
        var userId = context.User.FindFirstValue(ClaimTypes.NameIdentifier);
        var allowed = requirement.Name switch
        {
            nameof(Operations.Read) => order.OwnerId == userId || context.User.IsInRole("support"),
            nameof(Operations.Cancel) => order.OwnerId == userId && order.Status == OrderStatus.Open,
            _ => false,
        };
        if (allowed) context.Succeed(requirement);
        return Task.CompletedTask;                   // never call Fail() just to "deny" — not succeeding denies
    }
}

public static class Operations
{
    public static readonly OperationAuthorizationRequirement Read = new() { Name = nameof(Read) };
    public static readonly OperationAuthorizationRequirement Cancel = new() { Name = nameof(Cancel) };
}

// endpoint
private static async Task<Results<NoContent, NotFound, ForbidHttpResult>> Cancel(
    Guid id, AppDbContext db, IAuthorizationService authz, ClaimsPrincipal user, CancellationToken ct)
{
    var order = await db.Orders.SingleOrDefaultAsync(o => o.Id == id, ct);   // tenant filter already applied
    if (order is null) return TypedResults.NotFound();
    if (!(await authz.AuthorizeAsync(user, order, Operations.Cancel)).Succeeded)
        return TypedResults.Forbid();
    order.Cancel();
    await db.SaveChangesAsync(ct);
    return TypedResults.NoContent();
}
```

- **404 vs 403**: across tenants the row is invisible (404) — never confirm that another tenant's id exists. Within a tenant, 403 is fine when the user can know the resource exists.
- List endpoints can't authorize row by row: put the rule into the query (`Where(o => o.OwnerId == userId)`) and test it like any other rule.

## Tenant isolation with EF Core 10 named query filters

EF Core 10 supports several **named** filters per entity, each disabled independently — so `IgnoreQueryFilters(["SoftDelete"])` for an "include deleted" admin view keeps the tenant filter in force.

```csharp
public sealed class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public const string TenantFilter = "Tenant";
    public const string SoftDeleteFilter = "SoftDelete";

    // Set by the scoped registration below. Guid.Empty matches no row: an unset tenant fails closed.
    public Guid TenantId { get; set; }

    public DbSet<Order> Orders => Set<Order>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(AppDbContext).Assembly);
        // a filter that references a context member is evaluated per context instance (EF docs)
        modelBuilder.Entity<Order>()
            .HasQueryFilter(TenantFilter, o => o.TenantId == TenantId)
            .HasQueryFilter(SoftDeleteFilter, o => !o.IsDeleted);
    }

    // Both overloads route here: SaveChanges() → SaveChanges(true), SaveChangesAsync(ct) → SaveChangesAsync(true, ct).
    // Override the sync one too, or a sync call skips the tenant guard.
    public override int SaveChanges(bool acceptAllChangesOnSuccess)
    {
        GuardTenantWrites();
        return base.SaveChanges(acceptAllChangesOnSuccess);
    }

    public override Task<int> SaveChangesAsync(bool acceptAllChangesOnSuccess, CancellationToken ct = default)
    {
        GuardTenantWrites();
        return base.SaveChangesAsync(acceptAllChangesOnSuccess, ct);
    }

    private void GuardTenantWrites()
    {
        foreach (var entry in ChangeTracker.Entries<ITenantOwned>())
        {
            if (entry.State == EntityState.Added)
            {
                if (TenantId == Guid.Empty)                               // outside a request, nobody stamped it
                    throw new InvalidOperationException("No tenant set: refusing to write a tenant-owned row.");
                entry.Entity.TenantId = TenantId;                         // writes are stamped, not trusted
            }
            else if (entry.State is EntityState.Modified or EntityState.Deleted
                     && (entry.Entity.TenantId != TenantId
                         // the ORIGINAL value too: a foreign row loaded via IgnoreQueryFilters()
                         // and re-stamped with the current tenant must not pass
                         || entry.Property<Guid>(nameof(ITenantOwned.TenantId)).OriginalValue != TenantId))
                throw new InvalidOperationException("Cross-tenant write blocked.");
        }
    }

    // Pooling resets only EF's own state — a custom property survives into the next lease. Clear it on
    // return so a direct IDbContextFactory<T> user that forgets to set TenantId fails closed, not as the last tenant.
    public override void Dispose() { TenantId = Guid.Empty; base.Dispose(); }
    public override ValueTask DisposeAsync() { TenantId = Guid.Empty; return base.DisposeAsync(); }
}
```

Registration on top of the canonical pooled factory (`data-access` → DbContext registration) — the EF docs' pattern for per-request state in pooled contexts: hand out the context through a scoped registration that stamps the tenant.

```csharp
builder.Services.AddPooledDbContextFactory<AppDbContext>((sp, o) => /* provider config — data-access */);
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<ITenantContext, ClaimsTenantContext>();      // reads the "tenant_id" claim
// registered AFTER the factory: the last registration wins over the factory's own scoped AppDbContext
builder.Services.AddScoped(sp =>
{
    var db = sp.GetRequiredService<IDbContextFactory<AppDbContext>>().CreateDbContext();
    db.TenantId = sp.GetRequiredService<ITenantContext>().TenantId;
    return db;                                                          // scope disposal returns it to the pool
});

public sealed class ClaimsTenantContext(IHttpContextAccessor accessor) : ITenantContext
{
    // No HttpContext → Guid.Empty, never an exception: Data Protection's PersistKeysToDbContext, migrations
    // and hosted services resolve AppDbContext outside a request. Reads then match no row; tenant-owned
    // writes throw in SaveChanges — non-tenant tables (the key ring) keep working.
    public Guid TenantId =>
        Guid.TryParse(accessor.HttpContext?.User.FindFirstValue("tenant_id"), out var id) ? id : Guid.Empty;
}
```

- **Tenant id source**: a claim stamped at sign-in from the user's membership — never a header, query string or route value the client controls (if a route carries a tenant, verify membership against the claim).
- **Outside a request** (workers, `IDbContextFactory<T>` direct use) nothing stamps `TenantId` — it stays `Guid.Empty` (cleared on every return to the pool by the `Dispose` overrides), so the context sees no rows and refuses tenant-owned inserts until the job sets `db.TenantId` explicitly per tenant it processes. That's the intended failure mode.
- **Sync `SaveChanges` is guarded too** (both overloads above). Bulk `ExecuteUpdate`/`ExecuteDelete` bypass `SaveChanges`: the tenant filter still scopes their `WHERE`, but nothing stops `SetProperty(o => o.TenantId, …)` — ban that in review.
- **Filters cover LINQ only** — including `ExecuteUpdate`/`ExecuteDelete` — but **not** `FromSql`/Dapper: every hand-written query carries `tenant_id = @tenantId` explicitly (`data-access`). On PostgreSQL, row-level security is a defense-in-depth option for raw SQL; it doesn't replace the filter.
- **Caching**: tenant-scoped cache keys must contain the tenant id (`fusioncache-redis`).
- Never `IgnoreQueryFilters()` without filter names in tenant-facing code — it drops the tenant filter too. Grep for it in review.

### Enforcement tests (`dotnet-testing`)

```csharp
[Fact]
public void Every_tenant_owned_entity_has_the_tenant_filter()
{
    using var db = new AppDbContext(new DbContextOptionsBuilder<AppDbContext>()
        .UseNpgsql("Host=unused").Options);                             // model building only, no connection
    var missing = db.Model.GetEntityTypes()
        .Where(t => typeof(ITenantOwned).IsAssignableFrom(t.ClrType))
        .Where(t => t.FindDeclaredQueryFilter(AppDbContext.TenantFilter) is null)
        .Select(t => t.ClrType.Name)
        .ToList();
    Assert.Empty(missing);
}

[Fact]   // integration (ApiFixture + Testcontainers): the behavior, not just the metadata
public async Task Tenant_A_cannot_read_tenant_B_order()
{
    var ct = TestContext.Current.CancellationToken;
    Guid tenantA = Guid.CreateVersion7(), tenantB = Guid.CreateVersion7();
    var orderOfB = await api.SeedOrderAsync(tenantB, ct);
    var clientA = await api.CreateAuthenticatedClientAsync(tenantA, ct);

    var response = await clientA.GetAsync($"/api/orders/{orderOfB.Id}", ct);

    Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);      // invisible, not forbidden
}
```

The two fixture helpers extend `dotnet-testing`'s `ApiFixture` (same https client + `X-XSRF-TOKEN` setup as its `CreateAuthenticatedClientAsync(ct)`); the test-only `TestAuthHandler` turns a header into the `tenant_id` claim — the header exists only because the test scheme reads it, production auth never looks at it:

```csharp
// ApiFixture (dotnet-testing → WebApplicationFactory + xUnit v3)
public async Task<HttpClient> CreateAuthenticatedClientAsync(Guid tenant, CancellationToken ct)
{
    var client = CreateClient(new WebApplicationFactoryClientOptions
    {
        BaseAddress = new Uri("https://localhost"),   // Secure cookies are only resent over https
        AllowAutoRedirect = false,
    });
    client.DefaultRequestHeaders.Add(TestAuthHandler.TenantHeader, tenant.ToString());
    using var me = await client.GetAsync("/api/me", ct);   // mints XSRF-TOKEN for this identity
    var xsrf = me.Headers.GetValues("Set-Cookie")
        .Select(c => c.Split(';')[0])
        .Single(c => c.StartsWith("XSRF-TOKEN=", StringComparison.Ordinal))["XSRF-TOKEN=".Length..];
    client.DefaultRequestHeaders.Add("X-XSRF-TOKEN", Uri.UnescapeDataString(xsrf));
    return client;
}

public async Task<Order> SeedOrderAsync(Guid tenant, CancellationToken ct)
{
    await using var db = await Services.GetRequiredService<IDbContextFactory<AppDbContext>>()
        .CreateDbContextAsync(ct);
    db.TenantId = tenant;                                   // SaveChanges stamps the row with it
    var order = new Order();
    db.Orders.Add(order);
    await db.SaveChangesAsync(ct);
    return order;
}

// TestAuthHandler.HandleAuthenticateAsync — claims for the test principal:
//   new Claim("tenant_id", Request.Headers[TenantHeader].ToString())   // TenantHeader = "X-Test-Tenant"
```

Add the same pair for every list endpoint (tenant A's list never contains B's rows) and for one write (cancel B's order as A → 404, row unchanged).

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Relying on every endpoint remembering `RequireAuthorization()` | Fallback policy; explicit `AllowAnonymous` opt-outs |
| Ownership check only in the SPA (hidden button) | `IAuthorizationService` on the server, every time |
| `Where(o => o.TenantId == tenantId)` sprinkled by hand | Named `"Tenant"` query filter + stamping in `SaveChangesAsync`; hand-written SQL is the only place for explicit predicates |
| Tenant id from a request header | Claim from the authenticated session |
| `IgnoreQueryFilters()` for "include deleted" | `IgnoreQueryFilters([AppDbContext.SoftDeleteFilter])` |
| 403 for another tenant's resource | 404 — don't leak existence |
| Tenant set in `OnConfiguring` with pooling | `OnConfiguring` runs once per pooled instance — stamp per scope as above |

## Sources

- https://learn.microsoft.com/en-us/aspnet/core/security/authorization/policies?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/authorization/resourcebased?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/ef/core/querying/filters (named filters, EF 10)
- https://learn.microsoft.com/en-us/ef/core/what-is-new/ef-core-10.0/whatsnew#named-query-filters
- https://learn.microsoft.com/en-us/ef/core/performance/advanced-performance-topics#dbcontext-pooling (per-request state with pooled contexts)
- https://learn.microsoft.com/en-us/ef/core/miscellaneous/multitenancy
- https://learn.microsoft.com/en-us/dotnet/api/microsoft.entityframeworkcore.metadata.ireadonlyentitytype.finddeclaredqueryfilter
