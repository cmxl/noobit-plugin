# HTTP interactions — reference implementation

Discord POSTs every interaction to your **Interactions Endpoint URL**; you answer in the HTTP response. No
gateway connection, no long-lived process, scales like any ASP.NET Core app. Trade-off: no guild events
(members, messages, reactions, voice) — pair with Webhook Events for installs/entitlements.

Code targets Discord.Net 3.20.1; [testing.md](testing.md) POSTs Ed25519-signed Discord payloads to it
end-to-end. Gateway-mode code it reuses (options, `InteractionErrors`, `DiscordLog`) is in
[gateway-bot.md](gateway-bot.md).

Code blocks omit `using` directives (add the System.*, Discord.*, Microsoft.Extensions.* and `MyApp.*` namespaces the
types come from); the file-scoped namespace shows which project a file belongs to.

**Contents:** 1 How it works · 2 Registration · 3 Endpoint and signed-request verification (shared with Webhook
Events) · 4 Startup (modules, login, command registration, error replies) · 5 Modules (RestInteractionModuleBase)
· 6 Deployment & portal setup · 7 Gotchas specific to HTTP mode

## 1. How it works

Flow: verify → PING or parse → dispatch to `InteractionService` (`RunMode.Async`) → the module's first
Respond/Defer/Modal becomes the HTTP response (≤ 3 s) → later edits and follow-ups are REST calls.

Key mechanics of Discord.Net in HTTP mode:
- `DiscordRestClient.ParseHttpInteractionAsync(publicKey, sig, ts, body, doApiCallOnCreation)` verifies and
  parses (Newtonsoft internally). Pass `_ => false` so it doesn't make REST calls inside your 3 s budget.
- `RestInteraction.Respond/Defer/RespondWithModal` **return JSON strings** instead of sending.
  `RestInteractionModuleBase<T>` forwards that JSON to `RestInteractionContext.InteractionResponseCallback`.
- Follow-ups and edits are real REST calls → the `DiscordRestClient` must be logged in with the bot token.

## 2. Registration

`DiscordHttpExtensions.cs`

```csharp
namespace MyApp.Interactions;

public static class DiscordHttpExtensions
{
    public static IServiceCollection AddDiscordHttpInteractions(this IServiceCollection services)
    {
        services.AddOptions<DiscordOptions>()
            .BindConfiguration(DiscordOptions.SectionName)
            // Mode-specific rules (SKILL.md "Stack fit"); the hex format is a DataAnnotation on DiscordOptions.
            .Validate(o => o.PublicKey.Length > 0, "Discord:PublicKey is required for HTTP interactions")
            // Production needs a logged-in client (follow-ups/edits are REST, DM parsing reads CurrentUser).
            // Development may run without a token (guild interactions only).
            .Validate<IHostEnvironment>((o, env) => env.IsDevelopment() || !string.IsNullOrWhiteSpace(o.Token),
                "Discord:Token is required outside Development")
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<DiscordOptions>, DiscordOptionsValidator>(); // gateway-bot.md §2

        services.AddSingleton(new DiscordRestConfig
        {
            LogLevel = LogSeverity.Info,
            UseInteractionSnowflakeDate = false, // measure the 3 s window from receipt, not from the snowflake
        });
        services.AddSingleton(sp => new DiscordRestClient(sp.GetRequiredService<DiscordRestConfig>()));
        services.AddSingleton<IDiscordClient>(sp => sp.GetRequiredService<DiscordRestClient>());
        services.AddSingleton(sp => new InteractionService(sp.GetRequiredService<DiscordRestClient>(),
            new InteractionServiceConfig
            {
                DefaultRunMode = RunMode.Async, // same semantics as the gateway host (results via InteractionExecuted)
                ThrowOnError = false,           // handled in InteractionExecuted
                UseCompiledLambda = true,
                LogLevel = LogSeverity.Info,
            }));
        services.AddHostedService<DiscordHttpStartup>();
        services.AddHealthChecks();
        services.AddScoped<IWebhookEventInbox, EfWebhookEventInbox>(); // your EF Core inbox (app-integration.md §5)

        services.AddSingleton<AnnouncementQueue>();
        services.AddSingleton<IAnnouncementQueue>(sp => sp.GetRequiredService<AnnouncementQueue>());
        services.AddHostedService<AnnouncementPublisher>();

        services.AddSingleton<IDocsSearch, DocsSearch>(); // your implementation (rich-ui.md §5)
        return services;
    }
}
```

`Program.cs`

```csharp
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddDiscordHttpInteractions();

var app = builder.Build();
app.MapDiscordInteractions("/discord/interactions");
app.MapDiscordWebhookEvents("/discord/events");
app.MapHealthChecks("/health/live", new() { Predicate = _ => false }) // dependency-free: Discord's state never restarts the app
    .AllowAnonymous()       // probes carry no cookie: opt out of the BFF fallback policy (noobit:bff-security)
    .DisableRateLimiting();
app.Run();

public partial class Program;
```

The endpoint never awaits the command: it dispatches with `Task.Run` and answers as soon as the module's first
response (respond/defer/modal) reaches the callback, so it works under either run mode. `RunMode.Async` is kept
so failures surface through `InteractionExecuted` exactly as on the gateway and the shared error handler applies.

## 3. Endpoint and signed-request verification

`DiscordInteractionsEndpoint.cs`

```csharp
namespace MyApp.Interactions;

/// <summary>Discord's "Interactions Endpoint URL" — contract: SKILL.md rule 12, design points below.</summary>
public static class DiscordInteractionsEndpoint
{
    private static readonly TimeSpan ResponseBudget = TimeSpan.FromMilliseconds(2500); // leave headroom under 3 s
    private const int MaxBodyBytes = 1024 * 1024; // interaction payloads are small; refuse to buffer more unauthenticated bytes
    private static readonly TimeSpan MaxClockSkew = TimeSpan.FromMinutes(5); // replay window for signed requests

    public static IEndpointConventionBuilder MapDiscordInteractions(this IEndpointRouteBuilder app, string pattern)
    {
        // Root provider: commands run (RunMode.Async) after this request ends, so they must not use RequestServices.
        var root = app.ServiceProvider;
        return app.MapPost(pattern, (HttpContext http) => HandleAsync(http, root))
            .AllowAnonymous()       // the Ed25519 signature IS the auth; under the BFF fallback policy Discord's PING gets 401
            .DisableAntiforgery()   // authenticated by signature, not cookies — the BFF/antiforgery rules don't apply here
            .ExcludeFromDescription();
        // Rate limiting: exempt this route from the BFF's per-IP global limiter (design points below) — the body
        // cap bounds memory, and Ed25519 verification is cheap enough to need no per-route limiter.
    }

    private static async Task HandleAsync(HttpContext http, IServiceProvider root)
    {
        var rest = root.GetRequiredService<DiscordRestClient>();
        var interactions = root.GetRequiredService<InteractionService>();
        var publicKey = root.GetRequiredService<IOptions<DiscordOptions>>().Value.PublicKey;
        var logger = root.GetRequiredService<ILoggerFactory>().CreateLogger(typeof(DiscordInteractionsEndpoint));
        var now = (root.GetService<TimeProvider>() ?? TimeProvider.System).GetUtcNow();

        var signature = http.Request.Headers["X-Signature-Ed25519"].ToString();
        var timestamp = http.Request.Headers["X-Signature-Timestamp"].ToString();

        var body = await DiscordSignedRequest.ReadBodyAsync(http.Request, MaxBodyBytes, http.RequestAborted);
        if (body is null)
        {
            http.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            return;
        }

        if (!DiscordSignedRequest.IsFresh(timestamp, now, MaxClockSkew)
            || !DiscordSignedRequest.IsValidSignature(publicKey, signature, timestamp, body))
        {
            http.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        // PING (type 1): answer directly. Discord.Net's parser requires a user object a PING may not carry.
        bool isPing;
        try
        {
            isPing = IsPing(body);
        }
        catch (JsonException)
        {
            http.Response.StatusCode = StatusCodes.Status400BadRequest; // signed but not JSON: a client error, not a 500
            return;
        }

        if (isPing)
        {
            await WriteJsonAsync(http, """{"type":1}""");
            return;
        }

        // doApiCallOnCreation: false — no REST lookups inside the 3 s budget (Guild stays null, see §4 preconditions).
        RestInteraction? interaction;
        try
        {
            interaction = await rest.ParseHttpInteractionAsync(publicKey, signature, timestamp, body, _ => false);
        }
        catch (Newtonsoft.Json.JsonException)
        {
            // Discord.Net deserializes with Newtonsoft: valid JSON of the wrong shape ("type": 1.5) throws here
            http.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        if (interaction is null)
        {
            // Interaction type Discord.Net doesn't model (e.g. PRIMARY_ENTRY_POINT for Activities).
            logger.LogWarning("Unsupported interaction type received");
            http.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        var initialResponse = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var delivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = new RestInteractionContext(rest, interaction, async json =>
        {
            initialResponse.TrySetResult(json);
            // Hold the command until the HTTP response is flushed, so a FollowupAsync/ModifyOriginalResponseAsync
            // right after DeferAsync doesn't race Discord receiving the deferral ("Unknown interaction").
            await delivered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        });

        // Dispatch OFF the request path. Even under RunMode.Async, unknown commands and stale buttons raise
        // InteractionExecuted *inline* inside ExecuteCommandAsync — its error reply goes through the callback above,
        // which waits for this request to flush. Awaiting dispatch here would deadlock that path for 5 s.
        var dispatch = Task.Run(() => interactions.ExecuteCommandAsync(context, root));
        _ = dispatch.ContinueWith(t => logger.LogError(t.Exception, "Dispatching interaction {InteractionId} failed", interaction.Id),
            TaskContinuationOptions.OnlyOnFaulted);

        string json;
        try
        {
            json = await initialResponse.Task.WaitAsync(ResponseBudget, http.RequestAborted);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            // Budget exceeded or Discord hung up: a late Respond/Defer fails fast instead of waiting 5 s on the gate.
            delivered.TrySetCanceled();
            if (ex is OperationCanceledException)
            {
                return; // RequestAborted — nobody is listening for a status code
            }

            logger.LogWarning("Interaction {InteractionId} produced no initial response within {Budget} ms — defer slow work",
                interaction.Id, ResponseBudget.TotalMilliseconds);
            http.Response.StatusCode = StatusCodes.Status500InternalServerError;
            return;
        }

        http.Response.OnCompleted(() =>
        {
            delivered.TrySetResult();
            return Task.CompletedTask;
        });
        await WriteJsonAsync(http, json);
    }

    private static bool IsPing(byte[] body)
    {
        var reader = new Utf8JsonReader(body);
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.PropertyName && reader.CurrentDepth == 1 && reader.ValueTextEquals("type"u8))
            {
                // TryGetInt32: GetInt32 throws FormatException (not JsonException) on 1.5 / 1e99 → would be a 500
                return reader.Read() && reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out var type) && type == 1;
            }

            if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray && reader.CurrentDepth > 0)
            {
                reader.Skip();
            }
        }

        return false;
    }

    private static Task WriteJsonAsync(HttpContext http, string json)
    {
        http.Response.StatusCode = StatusCodes.Status200OK;
        http.Response.ContentType = "application/json";
        return http.Response.WriteAsync(json);
    }
}
```

**Signed-request verification** — stated once here, shared by this endpoint and the Webhook Events endpoint
(app-integration.md §5):

`DiscordSignedRequest.cs`

```csharp
namespace MyApp.Interactions;

/// <summary>Raw-body reading and Ed25519 checks for requests Discord signs (interactions, Webhook Events).</summary>
public static class DiscordSignedRequest
{
    /// <summary>
    /// Reads the raw body, stopping after <paramref name="maxBytes"/> — also for chunked requests without a
    /// Content-Length. Returns <c>null</c> when the body is larger than allowed.
    /// </summary>
    public static async Task<byte[]?> ReadBodyAsync(HttpRequest request, int maxBytes, CancellationToken ct)
    {
        if (request.ContentLength > maxBytes)
        {
            return null; // cheap early exit when the client declares the size
        }

        using var buffer = new MemoryStream();
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = await request.Body.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > maxBytes)
            {
                return null;
            }

            buffer.Write(chunk, 0, read);
        }

        return buffer.ToArray();
    }

    // Discord.Net exposes its Ed25519 check only as an instance method on DiscordRestClient. This private instance
    // is never logged in and makes no REST calls — it lets every hosting mode verify (a gateway-mode app has no
    // DiscordRestClient registration), without touching the app's real client.
    private static readonly DiscordRestClient Verifier = new();

    /// <summary>Ed25519 over timestamp + body. Malformed headers are <c>false</c> (→ 401), never an exception (→ 500).</summary>
    public static bool IsValidSignature(string publicKey, string signature, string timestamp, byte[] body)
    {
        if (publicKey.Length != 64 || signature.Length != 128 || timestamp.Length == 0)
        {
            return false; // an unconfigured key verifies nothing — fail closed
        }

        try
        {
            return Verifier.IsValidHttpInteraction(publicKey, signature, timestamp, body);
        }
        catch (Exception)
        {
            return false; // Discord.Net's hex parser throws on malformed input
        }
    }

    /// <summary>Replay guard: the signed Unix-seconds timestamp must lie within ±<paramref name="maxSkew"/> of now.</summary>
    public static bool IsFresh(string timestamp, DateTimeOffset now, TimeSpan maxSkew) =>
        long.TryParse(timestamp, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds)
        && seconds <= DateTimeOffset.MaxValue.ToUnixTimeSeconds()
        && (now - DateTimeOffset.FromUnixTimeSeconds(seconds)).Duration() <= maxSkew;
}
```

Design points (signed-request rules apply to both Discord endpoints):
- **Raw bytes, bounded**: the signature covers timestamp + the exact body — model binding or re-serialization
  breaks it. The read stops at the cap (1 MiB here) even without a Content-Length (chunked), so unauthenticated
  callers can't make you buffer arbitrary amounts → 413.
- **401 for anything unverifiable**, including missing headers and malformed hex (Discord.Net's hex parser
  throws → would be 500). Antiforgery is disabled: these endpoints are authenticated by signature, not cookies;
  the cookie-BFF rules (`noobit:bff-security`) apply to browser endpoints, not Discord's machine-to-machine calls.
- **Exempt both Discord routes from the BFF's global limiter.** bff-security's `GlobalLimiter` (100/min per
  IP) applies to every endpoint, and Discord's POSTs come from a small pool of egress IPs — a busy bot gets
  429s, which users see as "The application did not respond". Return a no-limiter partition for these paths
  inside the global partitioner (everything else stays as bff-security defines it). The 1 MiB body cap stays;
  block abusive sources at the edge (nginx/WAF). `.DisableRateLimiting()` on both endpoints is equivalent
  while they carry no named policy; the partitioner keeps the exemption next to the limiter it carves out of.

  ```csharp
  o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
      ctx.Request.Path.StartsWithSegments("/discord")   // /discord/interactions + /discord/events
          ? RateLimitPartition.GetNoLimiter("discord")
          : RateLimitPartition.GetFixedWindowLimiter(   // bff-security's per-user / per-IP partition, unchanged
              ctx.User.FindFirstValue(ClaimTypes.NameIdentifier) is { } userId ? $"u:{userId}"
                  : $"ip:{ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown"}",
              _ => new FixedWindowRateLimiterOptions { PermitLimit = 100, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
  ```
- **PING handled before parsing**: Discord.Net's parser requires a `user`/`member` object; a PING may lack one.
- **Timestamp freshness**: Discord.Net doesn't check it, so the endpoint rejects timestamps more than 5 minutes
  from now (401). Handlers with side effects should still be idempotent on `interaction.Id`. A host clock that
  drifts by minutes now fails every request — keep NTP on.
- **Dispatch off the request path** (`Task.Run`, SKILL.md "Stack fit"): the command must outlive the response.
  Unknown commands and stale buttons raise
  `InteractionExecuted` *inline* inside `ExecuteCommandAsync` even under `RunMode.Async`; the error reply flows
  through the callback, which waits for this request to flush — awaiting dispatch would deadlock that path for
  5 s and Discord would show "did not respond". The tests assert the < 2 s budget for both cases.
- **Root service provider — only for work that outlives the request**: the command keeps running after the
  response; `RequestServices` would be disposed underneath it. `AutoServiceScopes` creates a fresh scope per
  execution from the root. Anything used *within* the request (e.g. the Webhook Events inbox) comes from
  `http.RequestServices` instead — resolving a scoped service from the root throws under `ValidateScopes` or
  becomes a captive dependency.
- **Delivered gate**: the module's callback awaits the response flush, so `ModifyOriginalResponseAsync`
  straight after `DeferAsync` doesn't race Discord ("Unknown interaction" / "Unknown Webhook").
- **2.5 s budget** with a warning: a command that neither responds nor defers is a bug — make it defer.
  On timeout — or when Discord aborts the request — the delivered gate is cancelled, so a late `RespondAsync`
  fails fast instead of stalling 5 s; late responses are dropped (Discord has already given up).

## 4. Startup

`DiscordHttpStartup.cs`

```csharp
namespace MyApp.Interactions;

/// <summary>
/// Builds the interaction modules before Kestrel accepts requests, logs the REST client in (needed for
/// follow-ups, edits, command registration and outbound posts) and registers commands once per deployment —
/// only when this is THE process that owns the modules (app-integration.md §3: registration is a bulk overwrite).
/// </summary>
public sealed class DiscordHttpStartup(
    DiscordRestClient rest,
    InteractionService interactions,
    IServiceProvider services,
    IOptions<DiscordOptions> options,
    ILogger<DiscordHttpStartup> logger) : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        rest.Log += message => DiscordLog.Write(logger, message);
        interactions.Log += message => DiscordLog.Write(logger, message);
        interactions.InteractionExecuted += (command, context, result) =>
            InteractionErrors.HandleExecutedAsync(logger, command, context, result); // gateway-bot.md §4

        await interactions.AddModulesAsync(typeof(DiscordHttpStartup).Assembly, services);

        if (string.IsNullOrWhiteSpace(options.Value.Token))
        {
            logger.LogWarning("Discord:Token not set (Development only) — guild interactions are answered; DM interactions, follow-ups, registration and posts fail");
            return;
        }

        // DiscordRestClient.LoginAsync calls users/@me — 401 fails startup. Neither call takes a cancel token and
        // RetryMode.AlwaysRetry retries 502s, so WaitAsync keeps a Discord outage from hanging startup forever.
        await rest.LoginAsync(TokenType.Bot, options.Value.Token).WaitAsync(cancellationToken);

        // Bulk overwrite: registering from a process with no (or other) modules deletes the real commands.
        if (!options.Value.RegisterCommands || interactions.Modules.Count == 0)
        {
            logger.LogInformation("Command registration skipped (Discord:RegisterCommands={Enabled}, {Count} modules)",
                options.Value.RegisterCommands, interactions.Modules.Count);
            return;
        }

        if (options.Value.DevGuildId is { } guildId)
        {
            await interactions.RegisterCommandsToGuildAsync(guildId).WaitAsync(cancellationToken);
        }
        else
        {
            await interactions.RegisterCommandsGloballyAsync().WaitAsync(cancellationToken);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => rest.LogoutAsync();
}
```

Error replies in HTTP mode must go through the context callback while the HTTP request is still waiting:
`IDiscordInteraction.RespondAsync` on a `RestInteraction` builds the JSON and **discards it**. The shared
`InteractionErrors.HandleExecutedAsync` (gateway-bot.md §4) detects `IRestInteractionContext` and does that.

### Preconditions in HTTP mode

`ParseHttpInteractionAsync(..., _ => false)` skips the guild fetch, so `RestInteraction.Guild` is null and
`RestGuildUser.GuildPermissions` throws — **`[RequireUserPermission]`, `[RequireRole]` and other guild-based
preconditions fail every guild command** (the user sees the generic error). Options:
- Rely on `[DefaultMemberPermissions]` (Discord enforces it client-side; admins can override per role) for
  visibility, and check business rules in your app (e.g. linked account roles in your DB).
- Or pass `doApiCallOnCreation: p => true` for those commands — one REST guild fetch inside the 3 s budget.
- Discord.Net 3.20.1 doesn't expose the payload's `member.permissions`; parse it from the raw body yourself if
  you need it without the REST call.

The client must be **logged in before interactions arrive in production**: besides follow-ups and edits,
Discord.Net dereferences `CurrentUser` when it parses a DM interaction (`RestDMChannel`), which throws on an
anonymous client. Hence `Token` is required outside Development; `DiscordRestClient.LoginAsync` itself calls
`users/@me`, so a bad token fails startup.

Registering commands at startup of every replica is acceptable for a few replicas (bulk overwrite is
idempotent; unchanged commands don't count toward the 200/day create limit). With many replicas, register
from one place — a config flag on one replica or a deployment step (a one-off `--register-commands` run) —
to avoid parallel overwrites.

## 5. Modules

Same attributes as gateway modules, different base class and context. Cards, modals, custom ids and the
autocomplete handler are shared (see [rich-ui.md](rich-ui.md)).

`HttpModules.cs`

```csharp
namespace MyApp.Interactions.Modules;

// HTTP modules MUST derive from RestInteractionModuleBase: its Respond/Defer/Modal overrides hand the JSON to the
// endpoint's callback. A plain InteractionModuleBase "responds" into the void and Discord shows "did not respond".
[CommandContextType(InteractionContextType.Guild, InteractionContextType.BotDm, InteractionContextType.PrivateChannel)]
[IntegrationType(ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall)]
public sealed class GeneralModule : RestInteractionModuleBase<RestInteractionContext>
{
    [SlashCommand("about", "What is this app?")]
    public Task AboutAsync() =>
        RespondAsync(
            components: AboutCard.Build("MyApp", "1.0.0", "https://cdn.discordapp.com/embed/avatars/0.png", "https://example.com"),
            flags: MessageFlags.ComponentsV2); // REST responses do NOT auto-add the V2 flag — always pass it
}
```

`SearchModule`, `FeedbackModule` etc. are the gateway modules (gateway-bot.md §6) with the base class swapped to
`RestInteractionModuleBase<RestInteractionContext>`: `DeferAsync()` becomes the HTTP response (type 5, or 6 for
a component), the following `ModifyOriginalResponseAsync` is a real REST call (needs the logged-in client), and
every V2 response, and every edit that turns a deferred response into V2, passes `MessageFlags.ComponentsV2`.
Edits of a message that already is V2 (`PageAsync`) don't need it: Discord never removes the flag once set.

## 6. Deployment & portal setup

1. Deploy behind nginx with TLS (`noobit:nginx-deploy`); the route must accept POST from the internet and
   pass the body untouched (no request-body rewriting, no auth middleware in front of it).
2. Configure `Discord:PublicKey` (Portal → General Information) and `Discord:Token` (secret).
3. Portal → General Information → **Interactions Endpoint URL** = `https://your.host/discord/interactions`
   → Save. Discord PINGs and probes a bad signature; save fails if either answer is wrong.
4. Serverless/scale-to-zero hosting only with warm instances (min replicas ≥ 1): the 3 s deadline includes cold
   start, and a cold start that exceeds it is a "did not respond".
5. Local development: expose the dev server through a tunnel (e.g. `cloudflared tunnel --url http://localhost:5000`)
   and use a separate **development application** with `DevGuildId` set — never point the production app's
   endpoint at a laptop.
6. To switch an app back to the gateway, clear the endpoint URL.
7. Command registration: see §4 (one place when there are many replicas).
8. Document the endpoint URL, portal settings and the transport decision in `docs/` (ADR via `/noobit:new-adr`).

## 7. Gotchas specific to HTTP mode

| Symptom | Cause | Fix |
|---|---|---|
| Discord: "The application did not respond", logs fine | Module derives from `InteractionModuleBase` | `RestInteractionModuleBase<RestInteractionContext>` |
| 400 "Invalid Form Body" on V2 reply | REST responses don't auto-add the V2 flag | `flags: MessageFlags.ComponentsV2` |
| Follow-up throws "Client is not logged in" | `DiscordRestClient` never logged in | Token configured + `LoginAsync` at startup |
| Edit after defer → 404 Unknown interaction | Edit raced the HTTP response | Delivered gate in the callback (above) |
| Portal refuses the URL | PING not `{"type":1}` or bad signature not 401 | See endpoint; test both |
| "Did not respond" under load, 429s in the access log | BFF global per-IP limiter vs Discord's few egress IPs | No-limiter partition for `/discord/*` (§3) |
| `ObjectDisposedException` in commands | Executed with `RequestServices` | Root provider + `AutoServiceScopes` |
| Error handler's message never arrives | Used `interaction.RespondAsync` | Context callback with `interaction.Respond(...)` |
| 500 on some interactions | `ParseHttpInteractionAsync` returns null for types it doesn't model (e.g. PRIMARY_ENTRY_POINT) | Null guard → 400 (endpoint above) |
| DM interactions throw `NullReferenceException` | Anonymous `DiscordRestClient` (parsing reads `CurrentUser`) | Log in before serving |
