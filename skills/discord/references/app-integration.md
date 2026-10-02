# Integrating your application with Discord

Your web app or worker doing things *in* Discord (posting, editing, roles), and Discord telling your app
things (installs, purchases, account links). Code below compiles against Discord.Net 3.20.1 and is covered by
[testing.md](testing.md).

## Contents
1. Outbound: queue + publisher via `IDiscordClient`
2. Post-then-edit (live status messages)
3. REST-only client in a web app
4. Channel webhooks (no bot)
5. Webhook Events (installs, entitlements)
6. OAuth2 account linking
7. Linked Roles, monetization
8. Idempotency & durability

## 1. Outbound: queue + publisher

Application code never calls Discord inline (no awaiting Discord inside HTTP requests, domain-event
handlers or `SaveChanges`): latency, rate limits and outages would leak into your app. Enqueue and return.

`Announcement.cs`

```csharp
namespace MyApp.Discord.Announcements;

public sealed record Announcement(Guid Id, string Title, string Body, string? ImageUrl = null, string? LinkUrl = null);
```

`AnnouncementQueue.cs`

```csharp
using System.Threading.Channels;

namespace MyApp.Discord.Announcements;

/// <summary>
/// In-process hand-off from application code (endpoints, domain-event handlers) to the Discord publisher.
/// Never call Discord from inside a request or SaveChanges — enqueue and return.
/// </summary>
public interface IAnnouncementQueue
{
    /// <returns><c>false</c> when the queue is full — the caller logs it, it never blocks or throws.</returns>
    bool TryEnqueue(Announcement announcement);
}

public sealed class AnnouncementQueue : IAnnouncementQueue
{
    // FullMode.Wait + TryWrite ⇒ TryWrite returns false when full (DropWrite would report true and drop silently).
    private readonly Channel<Announcement> _channel = Channel.CreateBounded<Announcement>(
        new BoundedChannelOptions(100) { FullMode = BoundedChannelFullMode.Wait, SingleReader = true });

    public bool TryEnqueue(Announcement announcement) => _channel.Writer.TryWrite(announcement);

    public IAsyncEnumerable<Announcement> ReadAllAsync(CancellationToken ct) => _channel.Reader.ReadAllAsync(ct);
}
```

`AnnouncementPublisher.cs`

```csharp
using Discord;
using Discord.Net;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using MyApp.Discord.Cards;

namespace MyApp.Discord.Announcements;

/// <summary>
/// Drains <see cref="AnnouncementQueue"/> and posts to Discord through <see cref="IDiscordClient"/> — works with
/// the gateway client (bot process) and with a logged-in <c>DiscordRestClient</c> (web app, no gateway) alike.
/// </summary>
public sealed class AnnouncementPublisher(
    AnnouncementQueue queue,
    IDiscordClient discord,
    IOptions<DiscordOptions> options,
    ILogger<AnnouncementPublisher> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (options.Value.AnnouncementChannelId is not { } channelId)
        {
            logger.LogInformation("Discord announcements disabled: no AnnouncementChannelId configured");
            return;
        }

        await foreach (var announcement in queue.ReadAllAsync(stoppingToken))
        {
            try
            {
                var messageId = await PublishAsync(channelId, announcement, stoppingToken);
                logger.LogInformation("Posted announcement {AnnouncementId} as message {MessageId}", announcement.Id, messageId);
            }
            catch (HttpException ex) when (ex.HttpCode is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.NotFound)
            {
                // 50001 Missing Access / 50013 Missing Permissions / 10003 Unknown Channel: config problem, retrying won't help.
                // 401/403/429 responses count toward Cloudflare's 10k-invalid-requests-per-10-min IP ban (404 doesn't).
                logger.LogError(ex, "Announcement {AnnouncementId} rejected by Discord ({DiscordCode}); check channel id and bot permissions",
                    announcement.Id, ex.DiscordCode);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Discord.Net already retried rate limits, timeouts and 502s (RetryMode.AlwaysRetry). If losing an
                // announcement is unacceptable, persist it (outbox) before enqueueing and mark it sent here.
                logger.LogError(ex, "Failed to post announcement {AnnouncementId}", announcement.Id);
            }
        }
    }

    public async Task<ulong> PublishAsync(ulong channelId, Announcement announcement, CancellationToken ct)
    {
        var requestOptions = new RequestOptions { CancelToken = ct };
        if (await discord.GetChannelAsync(channelId, CacheMode.AllowDownload, requestOptions) is not IMessageChannel channel)
        {
            throw new InvalidOperationException($"Channel {channelId} is not a message channel the bot can see");
        }

        var message = await channel.SendMessageAsync(
            components: AnnouncementCard.Build(announcement),
            flags: MessageFlags.ComponentsV2,               // explicit: not every send path auto-detects V2
            allowedMentions: AllowedMentions.None,          // app content must never ping @everyone by accident
            options: requestOptions);
        return message.Id;
    }
}
```

Registration (both hosting modes register the same three lines):

```csharp
services.AddSingleton<AnnouncementQueue>();
services.AddSingleton<IAnnouncementQueue>(sp => sp.GetRequiredService<AnnouncementQueue>());
services.AddHostedService<AnnouncementPublisher>();
```

- `IDiscordClient` is the `DiscordSocketClient` in a bot process and a logged-in `DiscordRestClient` in a web
  app — the publisher doesn't care. `GetChannelAsync(id, CacheMode.AllowDownload)` falls back to REST before
  the gateway cache is ready.
- In-process `Channel<T>` loses queued items on restart. When a message **must** arrive (billing events,
  moderation logs), write an outbox row in the same transaction as the business change and let the publisher
  drain the outbox (see `noobit:rabbitmq-messaging` for the outbox pattern; RabbitMQ when another service
  owns the Discord integration).
- **Multiple replicas each run this publisher.** An in-process queue is fine (each replica posts what *it*
  enqueued), but an outbox drained by every replica double-posts unless rows are claimed: `FOR UPDATE SKIP
  LOCKED` (`noobit:postgres`) / `UPDLOCK, READPAST` (`noobit:mssql`), marking the row sent inside the claiming
  transaction — the rule in `noobit:rabbitmq-messaging` ("Multiple publisher instances must claim rows").
  Store the returned message id with the row so a retry edits instead of re-posting.
- Microservices: the service owning the Discord token consumes domain events from RabbitMQ and is the only
  one talking to Discord — other services never hold the bot token.

## 2. Post-then-edit (live status messages)

For "deployment running → finished", "stream live → ended", "ticket open → closed": post once, store the
message id with your entity, edit later instead of posting again.

```csharp
// sketch — StatusCard and job are your types; the Discord.Net calls are the real API
var message = await channel.SendMessageAsync(components: StatusCard.Running(job), flags: MessageFlags.ComponentsV2,
    allowedMentions: AllowedMentions.None);
job.SetDiscordMessage(channel.Id, message.Id);              // persist both ids (snowflakes: ulong / string(20))
// later
await channel.ModifyMessageAsync(job.DiscordMessageId, m => m.Components = StatusCard.Finished(job));
```

Handle `HttpException` with `DiscordCode == DiscordErrorCode.UnknownMessage` (someone deleted it): post a new
one or give up, don't retry.

## 3. REST-only client in a web app

No gateway needed to post or manage things:

```csharp
// excerpt — the full version is DiscordHttpExtensions/DiscordHttpStartup in http-interactions.md
services.AddSingleton(_ => new DiscordRestClient(new DiscordRestConfig { LogLevel = LogSeverity.Info }));
services.AddSingleton<IDiscordClient>(sp => sp.GetRequiredService<DiscordRestClient>());
// IHostedService.StartAsync: await rest.LoginAsync(TokenType.Bot, token); // REST login validates the token (401 throws)
```

One singleton per process (it owns the rate-limit buckets). Never `new DiscordRestClient()` per request.

## 4. Channel webhooks (no bot)

`WebhookAnnouncer.cs`

```csharp
using Discord;
using Discord.Webhook;
using MyApp.Discord.Cards;

namespace MyApp.Discord.Announcements;

/// <summary>
/// Simplest outbound path: post through a channel webhook URL (Channel settings → Integrations → Webhooks).
/// No bot, no token, no gateway — but webhooks the app doesn't own cannot carry interactive components,
/// so this card variant has link buttons only. Call it from a background publisher, not from request code.
/// </summary>
public sealed class WebhookAnnouncer : IAsyncDisposable
{
    private readonly Func<DiscordWebhookClient> _createClient;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DiscordWebhookClient? _client;

    public WebhookAnnouncer(string webhookUrl) : this(() => new DiscordWebhookClient(webhookUrl)) { }

    /// <param name="createClient">Client factory — the seam tests use to simulate a failing construction.</param>
    public WebhookAnnouncer(Func<DiscordWebhookClient> createClient) => _createClient = createClient;

    public async Task<ulong> PostAsync(Announcement a, CancellationToken ct)
    {
        var client = await GetClientAsync(ct);
        return await client.SendMessageAsync(
            components: AnnouncementCard.BuildStatic(a),
            flags: MessageFlags.ComponentsV2,
            allowedMentions: AllowedMentions.None,
            username: "MyApp",
            options: new RequestOptions { CancelToken = ct });
    }

    // DiscordWebhookClient's constructor performs blocking HTTP calls (login + GET webhook) and throws for an
    // unknown/deleted webhook or during an outage — never construct it in DI/startup or on a request thread.
    // Build it off-thread on first use and cache only a SUCCESS: a cached failure (Lazy<Task<T>>) would stop all
    // alerts until the process restarts.
    private async Task<DiscordWebhookClient> GetClientAsync(CancellationToken ct)
    {
        if (Volatile.Read(ref _client) is { } existing)
        {
            return existing;
        }

        await _gate.WaitAsync(ct);
        try
        {
            if (_client is null)
            {
                var created = await Task.Run(_createClient, ct); // throws → nothing cached, the next post retries
                Volatile.Write(ref _client, created);
            }

            return _client!;
        }
        finally
        {
            _gate.Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        _client?.Dispose();
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}
```

- **`DiscordWebhookClient`'s constructor makes blocking HTTP calls** (login + fetch webhook) and throws for an
  unknown or deleted webhook. Never construct it in DI registration, startup, or on a request thread — create it
  off-thread on first use, and **don't cache a failed construction** (as above), or one Discord blip silences
  every later alert.
- **Raw-HTTP alternative** (no Discord.Net.Webhook dependency): `POST {webhookUrl}?with_components=true` via a
  typed `IHttpClientFactory` client with source-generated System.Text.Json. Without `with_components=true`
  Discord **ignores the `components` field** on webhooks the app doesn't own (Discord.Net adds the parameter
  for you). Send `"flags": 32768` (IS_COMPONENTS_V2) and `"allowed_mentions": {"parse": []}`; retries/429s are
  then yours (`AddStandardResilienceHandler`, honour `Retry-After`).
- Webhook URL = secret (anyone with it can post). Store like a token; keep it out of logs (HttpClient logging
  prints request URLs).
- Webhooks not created by your application can't send interactive components (link buttons are fine).
  Webhooks created *by* the app (`channel.CreateWebhookAsync` with the bot) can.
- Stop using a webhook after a 404 (deleted) — Discord asks you to; 401/403/429 responses count toward the
  invalid-request ban.

## 5. Webhook Events

Discord → your app over HTTP: `APPLICATION_AUTHORIZED` (someone installed the app — guild or **user** install)
and `APPLICATION_DEAUTHORIZED` exist **only** here; `ENTITLEMENT_CREATE/UPDATE/DELETE` arrive here *and* as
gateway events (shard 0) — HTTP-only apps use this endpoint for them.
Configure Portal → Webhooks → Endpoint URL + event types.

`DiscordWebhookEventsEndpoint.cs`

```csharp
using System.Text.Json;
using Discord.Rest;
using Microsoft.Extensions.Options;
using MyApp.Discord;

namespace MyApp.Interactions;

/// <summary>
/// Discord "Webhook Events" (Developer Portal → Webhooks): APPLICATION_AUTHORIZED / _DEAUTHORIZED (the only way to
/// learn about user installs), ENTITLEMENT_CREATE/UPDATE/DELETE. Same Ed25519 signing as interactions, but the
/// contract differs: answer PING (type 0) and events with 204 and an empty body, within 3 s.
/// Delivery is retried, unordered and not guaranteed — persist raw, dedupe, process out of band.
/// </summary>
public static class DiscordWebhookEventsEndpoint
{
    private const int MaxBodyBytes = 256 * 1024; // events are a few KB; cap what unauthenticated callers can make us buffer

    public static IEndpointConventionBuilder MapDiscordWebhookEvents(this IEndpointRouteBuilder app, string pattern) =>
        app.MapPost(pattern, HandleAsync)
            .DisableAntiforgery()   // authenticated by signature, not cookies
            .ExcludeFromDescription();   // optionally .RequireRateLimiting(...) per IP, as for the interactions endpoint

    private static async Task HandleAsync(HttpContext http)
    {
        // Everything here finishes inside the request → RequestServices. The inbox is typically a scoped DbContext;
        // resolving it from the root provider would throw under ValidateScopes or create a captive dependency.
        var services = http.RequestServices;
        var rest = services.GetRequiredService<DiscordRestClient>();
        var publicKey = services.GetRequiredService<IOptions<DiscordOptions>>().Value.PublicKey;
        var inbox = services.GetRequiredService<IWebhookEventInbox>();

        var signature = http.Request.Headers["X-Signature-Ed25519"].ToString();
        var timestamp = http.Request.Headers["X-Signature-Timestamp"].ToString();
        var body = await DiscordSignedRequest.ReadBodyAsync(http.Request, MaxBodyBytes, http.RequestAborted);
        if (body is null)
        {
            http.Response.StatusCode = StatusCodes.Status413PayloadTooLarge;
            return;
        }

        // Same Ed25519 scheme as interactions. No freshness check here: Discord retries a delivery for ~10 min and
        // the docs don't promise a fresh timestamp per retry — the dedupe key makes replays harmless instead.
        if (!DiscordSignedRequest.IsValidSignature(rest, publicKey, signature, timestamp, body))
        {
            http.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        var (isPing, eventType) = Peek(body);
        if (!isPing)
        {
            // Store first, think later: the raw bytes go to a durable inbox — even if the JSON is unexpected —
            // and a background job interprets them. A 500 here would only trigger Discord's retries.
            var dedupeKey = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(body));
            await inbox.StoreAsync(eventType, dedupeKey, body, http.RequestAborted);
        }

        http.Response.StatusCode = StatusCodes.Status204NoContent;
        http.Response.ContentType = "application/json"; // Discord requires a valid Content-Type even on the empty 204
    }

    private static (bool IsPing, string EventType) Peek(byte[] body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return (false, "UNPARSEABLE");
            }

            var isPing = root.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.Number && type.GetInt32() == 0;
            var eventType = root.TryGetProperty("event", out var evt) && evt.ValueKind == JsonValueKind.Object
                            && evt.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String
                ? t.GetString()!
                : "UNKNOWN";
            return (isPing, eventType);
        }
        catch (JsonException)
        {
            return (false, "UNPARSEABLE"); // signed by Discord but not JSON we understand — keep it for inspection
        }
    }
}

public interface IWebhookEventInbox
{
    /// <param name="dedupeKey">Hash of the raw body — retries of the same delivery are identical.</param>
    Task StoreAsync(string eventType, string dedupeKey, byte[] rawBody, CancellationToken ct);
}

/// <summary>Sample only — use a DB table with a unique index on the dedupe key.</summary>
public sealed class InMemoryWebhookEventInbox(ILogger<InMemoryWebhookEventInbox> logger) : IWebhookEventInbox
{
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte[]> _events = new();

    public IReadOnlyCollection<byte[]> Events => _events.Values.ToArray();

    public Task StoreAsync(string eventType, string dedupeKey, byte[] rawBody, CancellationToken ct)
    {
        if (_events.TryAdd(dedupeKey, rawBody))
        {
            logger.LogInformation("Stored Discord webhook event {EventType}", eventType);
        }

        return Task.CompletedTask;
    }
}
```

Malformed-but-signed bodies are stored as `UNPARSEABLE` and acknowledged — a 500 would only start Discord's
retry loop.

**Deliberately different from `noobit:paypal`:** PayPal webhooks are stored first and verified later in the
processor, because verifying needs a remote call (postback API or certificate download) that can fail
transiently — and a rejected delivery is a lost event. Discord's Ed25519 check is local, deterministic and
cheap, so Discord requests are verified **at ingress** and
unsigned bodies never reach the inbox — the ingress option `noobit:bff-security` allows for webhooks. What both
share: raw bytes, body cap, dedupe, out-of-band processing.

Differences from the interactions endpoint: PING is `type: 0` and both PING and events are answered with
**204 empty body**; deliveries are retried with backoff for ~10 min when you don't answer within 3 s, and
can arrive out of order — store raw, dedupe, process asynchronously. If Discord stops delivering
(`event_webhooks_status = 3`, "disabled by Discord", usually for inactivity) it emails you — monitor it.

## 6. OAuth2 account linking

Link a Discord user to your app's account (e.g. "connect Discord" on the profile page):

1. Browser hits your BFF endpoint `/account/discord/link` → generate `state` (random, store in the session /
   a short-lived HttpOnly cookie) → redirect to
   `https://discord.com/oauth2/authorize?response_type=code&client_id=…&scope=identify&redirect_uri=…&state=…`
   (add `prompt=none` only when re-linking an already-consented user — it skips the consent screen).
2. Callback `/account/discord/callback?code=…&state=…`: verify `state`, then **server-side** POST
   `https://discord.com/api/oauth2/token` (`application/x-www-form-urlencoded`: `grant_type=authorization_code`,
   `code`, `redirect_uri`; client id/secret via Basic auth) using `IHttpClientFactory`. The code is single-use:
   don't let the resilience handler retry this POST
   (`AddStandardResilienceHandler(o => o.Retry.DisableForUnsafeHttpMethods())`).
3. `GET https://discord.com/api/v10/users/@me` with `Authorization: Bearer <access_token>` → store the Discord
   user id (snowflake) on the account. Discard the tokens unless you need ongoing access (then store them
   encrypted server-side; refresh with `grant_type=refresh_token`, access tokens live 7 days).
4. Tokens never reach the browser — this is the cookie-BFF rule (`noobit:bff-security`). Discord is an
   *external* identity being linked, not your login provider.

**"Sign in with Discord"** (Discord as the app's login) is out of scope here: it is an authentication design
decision for `noobit:bff-security` (external OAuth behind the cookie BFF). This section only links an
already-signed-in user's Discord account.

Scopes: `identify` (id, username, avatar) is enough for linking; `guilds.members.read` to read their member
data in a guild; `role_connections.write` for Linked Roles; `applications.commands` to install the app.
Discord.Net's `DiscordRestClient.LoginAsync(TokenType.Bearer, accessToken)` can call user-scoped endpoints with
the user's token if you prefer typed models over raw HTTP — that is a **short-lived client per user operation**
(create, use, dispose), separate from the bot's singleton client.

## 7. Linked Roles, monetization

- **Linked Roles**: register up to 5 metadata fields (`PUT /applications/{id}/role-connections/metadata`),
  users authorize with `role_connections.write`, you `PUT /users/@me/applications/{id}/role-connection` with
  their values; server admins create roles requiring e.g. "level ≥ 10". Set the Portal's *Linked Roles
  Verification URL* to your BFF link endpoint.
- **Monetization**: SKUs in Portal → Monetization. Gate features with `Context.Interaction.Entitlements`,
  upsell with a Premium button — `new ButtonBuilder(style: ButtonStyle.Premium, skuId: id)`, **not**
  `ButtonBuilder.CreatePremiumButton` (3.20.1 builds it with the wrong style and it fails validation);
  PREMIUM_REQUIRED is deprecated —
  sync state from `ENTITLEMENT_*` webhook events or gateway events (shard 0). Test with
  `client.CreateTestEntitlementAsync`.

## 8. Idempotency & durability

- Discord may deliver events "never, once, or several times" — interaction handlers with side effects should
  be idempotent on `interaction.Id`; webhook events dedupe on their body/ids.
- Interaction tokens expire after 15 min: long jobs (> 15 min) should finish by posting a *channel* message
  (bot permission needed) or DM, not by editing the original response.
- Discord.Net's REST retry covers 429/502/timeouts. Wrap nothing else around it; for "must arrive" use an
  outbox, for "must arrive once" store the message id and edit instead of re-posting.
