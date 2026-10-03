# Background & scheduled jobs

Verified against official documentation, October 2026 (learn.microsoft.com: hosted services, .NET 10 hosting breaking changes; PostgreSQL `INSERT … ON CONFLICT`; quartz-scheduler.net). Extends `SKILL.md` → Configuration & DI → Background work and [best-practices.md → Hosted services](best-practices.md#hosted-services--graceful-shutdown) (paced `PeriodicTimer` loop, per-iteration `try/catch`, shutdown timeout).

## Pick the mechanism

| Need | Use |
|---|---|
| Work triggered by a request, fine to lose on crash (cache warm-up, best-effort notification) | `Channel<T>` + one `BackgroundService` reader |
| Work that must not be lost | Persist first (outbox/job row in the same transaction), then a worker processes it — or RabbitMQ (`rabbitmq-messaging`) |
| Periodic job, idempotent, fine on every replica (local cache refresh) | `BackgroundService` + `PeriodicTimer` |
| Periodic job that must run **once across replicas** (billing run, cleanup, report) | `PeriodicTimer` + a **database lease** (below) — or Quartz.NET with a clustered job store when you need cron, misfire handling and many jobs |
| Outbox dispatch across replicas | Row claiming with `FOR UPDATE SKIP LOCKED` / `UPDLOCK, READPAST` — no lease needed (`rabbitmq-messaging` → outbox dispatcher) |

Never `Task.Run` fire-and-forget from an endpoint: the work dies with the process, has no scope, and its exceptions go nowhere. The one documented exception is a deferred Discord interaction (`discord` → Stack fit): the follow-up edit must outlive the deferral response, the work is short and losable (the user simply re-runs the command), so the `Task.Run` body must create its own DI scope and catch/log its own exceptions.

## Rules for every worker

- **.NET 10: all of `ExecuteAsync` runs on a background thread** (breaking change) — code before the first `await` no longer blocks startup. Work that must finish *before* the app serves traffic goes into `StartAsync` (before `base.StartAsync`) or `IHostedLifecycleService`.
- **Scoped services per unit of work**: inject `IServiceScopeFactory` (or `IDbContextFactory<T>`), create an async scope per iteration/message — never capture a `DbContext` in the worker (`data-access` → DbContext registration).
- **Every iteration** gets its own `try/catch` with logging, its own `Activity` (`observability.md`), and threads `stoppingToken` into every call.
- **Unhandled exceptions stop the host** (`BackgroundServiceExceptionBehavior.StopHost`, default) — intended for "can't continue" failures, never for one bad item.
- **Graceful shutdown budget**: `HostOptions.ShutdownTimeout` (default 30 s) must fit inside the container's stop grace period — Docker/compose sends SIGKILL after `stop_grace_period` (default 10 s), so raise that to ≥ the host timeout (`docker`). Finish or abandon the current item on cancellation; anything abandoned must be safely re-runnable.

## Run once across replicas — database lease

A lease row per job: whoever holds an unexpired lease runs; a crashed holder's lease simply expires. Works with the app database you already have, no extra infrastructure.

```sql
-- PostgreSQL (EF migration owns this table)
CREATE TABLE job_leases (
    job_name    text        PRIMARY KEY,
    owner       text        NOT NULL,
    lease_until timestamptz NOT NULL
);
```

```csharp
public sealed class JobLease(NpgsqlDataSource db)
{
    // true = this instance owns the lease until now() + ttl (new lease, expired lease, or renewal)
    public async Task<bool> TryAcquireAsync(string job, string owner, TimeSpan ttl, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        var won = await conn.ExecuteScalarAsync<string?>(new CommandDefinition("""
            INSERT INTO job_leases (job_name, owner, lease_until)
            VALUES (@job, @owner, now() + @ttl)
            ON CONFLICT (job_name) DO UPDATE
                SET owner = EXCLUDED.owner, lease_until = EXCLUDED.lease_until
                WHERE job_leases.lease_until < now() OR job_leases.owner = EXCLUDED.owner
            RETURNING owner
            """, new { job, owner, ttl }, cancellationToken: ct));   // TimeSpan → interval
        return won == owner;                                         // no row returned = someone else holds it
    }
}

public sealed class NightlyCleanupJob(
    IServiceScopeFactory scopes, JobLease lease, ILogger<NightlyCleanupJob> logger) : BackgroundService
{
    private static readonly string Owner = $"{Environment.MachineName}:{Guid.NewGuid():N}";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        do
        {
            try
            {
                if (!await lease.TryAcquireAsync("nightly-cleanup", Owner, TimeSpan.FromMinutes(10), stoppingToken))
                    continue;                                        // another replica runs it
                await using var scope = scopes.CreateAsyncScope();
                await scope.ServiceProvider.GetRequiredService<ICleanupService>().RunDueAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { logger.LogError(ex, "Cleanup run failed; retrying next tick"); }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
```

- The lease **TTL must exceed the longest run** (or renew it mid-run) — a lease that expires during a long run lets a second replica start. Leases are mutual exclusion *in practice*, not a proof: make the job idempotent ("process rows due and not yet processed", not "process everything since last run").
- "Run at 02:00" = store `next_run_at`/`last_run_at` in the job's own table and let `RunDueAsync` decide; the timer only polls.
- SQL Server: same table (`JobName` PK, `LeaseUntil datetime2`); `UPDATE … SET Owner = @owner, LeaseUntil = DATEADD(second, @ttl, SYSUTCDATETIME()) WHERE JobName = @job AND (LeaseUntil < SYSUTCDATETIME() OR Owner = @owner)`, and when it touches 0 rows try the `INSERT` — a primary-key violation (error 2627) means another replica holds it.
- Postgres alternative for short jobs: `pg_try_advisory_xact_lock(<key>)` inside a transaction that spans the job — released on commit/rollback; avoid session-level advisory locks with pooled connections (the lock outlives your logical use of the connection).

**Not a lock:** FusionCache's distributed locker only deduplicates cache-factory runs — an efficiency measure, explicitly not a correctness lock (`fusioncache-redis`). Never use it (or `IMemoryCache`, or a static flag) for "only one replica does X".

## Quartz.NET — when the job list grows

Reach for Quartz.NET (Apache-2.0) when you need cron schedules, misfire policies, many jobs or an admin view: Quartz 4.x is **one package, `Quartz`** — the hosted service (`AddQuartzHostedService`) and the System.Text.Json job-store serializer are built in; `Quartz.Extensions.DependencyInjection`, `Quartz.Extensions.Hosting` and `Quartz.Serialization.SystemTextJson` are empty 4.x shims (remove them — nuget.org, 4.3.0). A persistent ADO.NET job store with clustering (`UsePersistentStore(s => { …; s.UseSystemTextJsonSerializer(); s.UseClustering(); })`) runs each trigger once across the cluster, and `AddQuartzHostedService(o => o.WaitForJobsToComplete = true)` drains jobs on shutdown. Do **not** add `Quartz.Serialization.Newtonsoft` (the 4.x name of the old `Quartz.Serialization.Json`) — it exists only for databases already holding Newtonsoft output. The job-store tables come from Quartz's own SQL scripts — add them through an EF migration (`migrationBuilder.Sql(...)`) so EF still owns the schema. Wire it from the quartz-scheduler.net **4.x** docs (not the 3.x pages); it's an ADR-worthy dependency, not a default.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| `Task.Run` fire-and-forget from an endpoint | Channel + worker, or persist + worker (sole exception: deferred Discord interactions — `discord`) |
| Same `PeriodicTimer` job on N replicas doing non-idempotent work | Database lease or clustered Quartz |
| FusionCache distributed locker / Redis `SETNX` without expiry as the "run once" guard | DB lease with TTL (+ idempotent job) |
| Captured `DbContext` in a singleton worker | Scope or `IDbContextFactory<T>` per iteration |
| Container stop grace (10 s) shorter than host shutdown timeout (30 s) | Raise `stop_grace_period`; keep iterations short and cancellable |

## Sources

- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/host/hosted-services?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/dotnet/core/compatibility/extensions/10.0/backgroundservice-executeasync-task
- https://www.postgresql.org/docs/current/sql-insert.html (ON CONFLICT … DO UPDATE … WHERE, RETURNING)
- https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS
- https://www.quartz-scheduler.net/documentation/quartz-4.x/packages/hosted-services-integration.html · https://www.quartz-scheduler.net/documentation/quartz-4.x/packages/microsoft-di-integration.html · https://www.quartz-scheduler.net/documentation/quartz-4.x/migration-guide.html (Quartz 4.3.0; hosting + STJ folded into `Quartz`)
- https://docs.docker.com/reference/compose-file/services/#stop_grace_period
