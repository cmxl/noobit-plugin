# Gateway bot — reference implementation

A long-running bot on the gateway with the Interaction Framework, hosted in the .NET Generic Host.
**This code compiles against Discord.Net 3.20.1 and is covered by the tests in [testing.md](testing.md)**;
a startup smoke test against Discord confirmed that a bad token fails startup instead of looping.

## Contents
1. Solution layout & packages
2. Options & secrets
3. DI registration
4. Hosted service (lifecycle, registration, error replies, fatal disconnects)
5. Log bridge
6. Modules
7. Sharding & scaling notes
8. Production checklist

## 1. Solution layout & packages

```
src/
  MyApp.Discord/        shared: options, cards (pure builders), custom ids, modals, autocomplete, announcements
  MyApp.Bot/            gateway worker: hosted service + InteractionModuleBase<SocketInteractionContext> modules
  MyApp.Interactions/   (optional) HTTP-interactions web app — see http-interactions.md
tests/
  MyApp.Discord.Tests/
```

Keeping cards, custom ids, modals and autocomplete handlers in a shared library means both hosting modes
reuse them, and the pure builders are unit-testable without Discord.

`Directory.Packages.props` (central package management — pin Discord.Net to the version you verified against,
use the latest 10.0.x patch for Microsoft.Extensions.*):

```xml
<PackageVersion Include="Discord.Net.Interactions" Version="3.20.1" />  <!-- pulls Core + Rest -->
<PackageVersion Include="Discord.Net.WebSocket" Version="3.20.1" />     <!-- gateway; only the bot project -->
<PackageVersion Include="Discord.Net.Webhook" Version="3.20.1" />       <!-- only if you post via webhook URLs -->
<PackageVersion Include="Microsoft.Extensions.Hosting" Version="10.0.12" />
<PackageVersion Include="Microsoft.Extensions.Hosting.Abstractions" Version="10.0.12" />
<PackageVersion Include="Microsoft.Extensions.Options.DataAnnotations" Version="10.0.12" />
```

Project files of the reference build (shown with versions as built; under CPM drop the `Version` attributes).
The SDK choice matters: the code relies on implicit usings — `Microsoft.NET.Sdk.Worker` brings the
`IServiceCollection`/`ILogger<T>`/hosting usings for the bot, `Microsoft.NET.Sdk.Web` adds
`StatusCodes`/`HttpContext` for the HTTP app. Keep `Program` of the worker internal so the tests'
`WebApplicationFactory<Program>` resolves to the web app's public `Program`.

`MyApp.Discord.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="Discord.Net.Interactions" Version="3.20.1" />
    <PackageReference Include="Discord.Net.Webhook" Version="3.20.1" />
    <PackageReference Include="Microsoft.Extensions.Hosting.Abstractions" Version="10.0.12" />
    <PackageReference Include="Microsoft.Extensions.Options.DataAnnotations" Version="10.0.12" />
  </ItemGroup>
</Project>
```

`MyApp.Bot.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk.Worker">
  <ItemGroup>
    <ProjectReference Include="..\MyApp.Discord\MyApp.Discord.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Discord.Net.WebSocket" Version="3.20.1" />
    <PackageReference Include="Microsoft.Extensions.Hosting" Version="10.0.12" />
  </ItemGroup>
</Project>
```

`MyApp.Interactions.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <ItemGroup>
    <ProjectReference Include="..\MyApp.Discord\MyApp.Discord.csproj" />
  </ItemGroup>
</Project>
```

Reference the granular packages, not the `Discord.Net` metapackage (it also drags in the legacy
text-command framework). `Discord.Net.WebSocket` brings `Discord.Net.Dave` (voice E2EE natives) — harmless
if you don't use voice.

`Directory.Build.props` must not enable invariant globalization:

```xml
<!-- Discord.Net builds CultureInfo from guild locales: invariant globalization breaks GUILD_AVAILABLE -->
<InvariantGlobalization>false</InvariantGlobalization>
```

Configuration conventions (options pattern, `ValidateOnStart`, Serilog) follow `noobit:aspnet-backend`.

## 2. Options & secrets

`DiscordOptions.cs`

```csharp
namespace MyApp.Discord;

public sealed class DiscordOptions
{
    public const string SectionName = "Discord";

    /// <summary>Bot token (Developer Portal → Bot). Secret: user-secrets / env var <c>Discord__Token</c>, never appsettings.</summary>
    public string Token { get; init; } = "";

    /// <summary>Hex Ed25519 public key (Developer Portal → General Information). Required for HTTP interactions only.</summary>
    public string PublicKey { get; init; } = "";

    /// <summary>When set, commands are registered to this guild only (instant updates) instead of globally.</summary>
    public ulong? DevGuildId { get; init; }

    /// <summary>Channel the application posts announcements to.</summary>
    public ulong? AnnouncementChannelId { get; init; }
}
```

```jsonc
// appsettings.json — non-secret values only
{ "Discord": { "DevGuildId": 123456789012345678, "AnnouncementChannelId": 234567890123456789 } }
```

```bash
dotnet user-secrets set "Discord:Token" "<bot token>"     # local
# container: Discord__Token from the orchestrator's secret store
```

Omit `DevGuildId` in production so commands register globally.

**Dev guild vs dev application.** Guild registration is instant, but Discord documents `contexts` and
`integration_types` as *global-only* (and guild commands never work in `BOT_DM`) — so DM, group-DM and
user-install behaviour cannot be exercised on a dev guild. For that, use a **separate development application**
(its own token/public key) with global registration. Switching one app between guild and global registration
leaves the other set registered, so commands show up twice: overwrite the old scope with an empty list
(`client.Rest.BulkOverwriteGuildCommands(Array.Empty<ApplicationCommandProperties>(), guildId)`) when you switch.

## 3. DI registration

`DiscordGatewayExtensions.cs`

```csharp
using Discord;
using Discord.Interactions;
using Discord.WebSocket;
using MyApp.Discord;
using MyApp.Discord.Announcements;
using MyApp.Discord.Search;

namespace MyApp.Bot;

public static class DiscordGatewayExtensions
{
    public static IServiceCollection AddDiscordGateway(this IServiceCollection services)
    {
        services.AddOptions<DiscordOptions>()
            .BindConfiguration(DiscordOptions.SectionName)
            .Validate(o => !string.IsNullOrWhiteSpace(o.Token), "Discord:Token is required")
            .ValidateOnStart();

        services.AddSingleton(new DiscordSocketConfig
        {
            // Least privilege: interactions need only Guilds. Add GuildMembers / MessageContent / GuildPresences
            // (privileged, portal toggle + review above 10k users) only for a feature that truly needs them.
            GatewayIntents = GatewayIntents.Guilds,
            LogLevel = LogSeverity.Info,
            MessageCacheSize = 0,
            // Stamp interactions with local receive time: a skewed host clock otherwise trips the 3 s check.
            UseInteractionSnowflakeDate = false,
        });
        services.AddSingleton(sp => new DiscordSocketClient(sp.GetRequiredService<DiscordSocketConfig>()));
        services.AddSingleton<IDiscordClient>(sp => sp.GetRequiredService<DiscordSocketClient>());
        services.AddSingleton(sp => new InteractionService(sp.GetRequiredService<DiscordSocketClient>(),
            new InteractionServiceConfig
            {
                DefaultRunMode = RunMode.Async, // never block the gateway task
                ThrowOnError = false,           // failures are handled in InteractionExecuted; don't rethrow into Task.Run
                UseCompiledLambda = true,       // faster module/modal construction
                LogLevel = LogSeverity.Info,
            }));
        services.AddHostedService<DiscordGatewayService>();

        // Application integration: app code enqueues, the publisher posts.
        services.AddSingleton<AnnouncementQueue>();
        services.AddSingleton<IAnnouncementQueue>(sp => sp.GetRequiredService<AnnouncementQueue>());
        services.AddHostedService<AnnouncementPublisher>();

        services.AddSingleton<IDocsSearch, InMemoryDocsSearch>();
        return services;
    }
}
```

`Program.cs`

```csharp
using MyApp.Bot;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddDiscordGateway();

var host = builder.Build();
await host.RunAsync();
```

Notes:
- `DiscordSocketClient`, `InteractionService` are singletons; the container owns disposal. Hosted services
  only `StopAsync`/`LogoutAsync` — never dispose a shared client yourself.
- Registering it as `IDiscordClient` lets application services (publisher, admin tools) depend on the
  interface — the same code then works with a `DiscordRestClient` in a web app and is mockable in tests.
- **Where the bot runs: exactly one process per token** (or one sharded client). Inside an existing ASP.NET
  Core app (same `AddDiscordGateway()` call) is fine only while that app runs a single replica — N replicas
  mean N gateway connections, every event N times and double answers ("already acknowledged"). A multi-replica
  app hosts the bot as a separate single-replica worker, or uses HTTP interactions.
- **Health:** `/health/live` stays dependency-free (`noobit:aspnet-backend`). Never put `ConnectionState` into
  liveness: a Discord outage would restart the bot, and each restart identifies again (identify budget →
  token reset). Report it on `/health/ready` or as a metric.

## 4. Hosted service

`DiscordGatewayService.cs`

```csharp
using System.Net;
using Discord;
using Discord.Interactions;
using Discord.Net;
using Discord.WebSocket;
using Microsoft.Extensions.Options;
using MyApp.Discord;

namespace MyApp.Bot;

/// <summary>
/// Owns the gateway connection lifecycle. Events are subscribed exactly once here — never inside <c>Ready</c>,
/// which fires again after every non-resumed reconnect.
/// </summary>
public sealed class DiscordGatewayService(
    DiscordSocketClient client,
    InteractionService interactions,
    IServiceProvider services,
    IOptions<DiscordOptions> options,
    IHostApplicationLifetime lifetime,
    ILogger<DiscordGatewayService> logger) : IHostedService
{
    private int _commandsRegistered;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        client.Log += message => DiscordLog.Write(logger, message);
        interactions.Log += message => DiscordLog.Write(logger, message);
        // Ready runs on the gateway task: registration is REST I/O with retries, so it runs off that task.
        client.Ready += () =>
        {
            _ = Task.Run(RegisterCommandsOnceAsync);
            return Task.CompletedTask;
        };
        client.Disconnected += StopOnFatalDisconnectAsync;
        client.InteractionCreated += HandleInteractionAsync;
        interactions.InteractionExecuted += (command, context, result) => ReplyToFailureAsync(logger, command, context, result);

        // Modules are built now (needs every module dependency registered) — fails fast on bad attributes.
        await interactions.AddModulesAsync(typeof(DiscordGatewayService).Assembly, services);

        // Socket client: LoginAsync only checks the token's *format* and takes no cancel token — WaitAsync bounds it.
        await client.LoginAsync(TokenType.Bot, options.Value.Token).WaitAsync(cancellationToken);
        // Real check before connecting: 401 fails startup instead of a reconnect loop. (Not Rest.GetCurrentUserAsync —
        // on the socket client it dereferences CurrentUser, which is null until READY, and throws on a VALID token.)
        // Pass the cancel token: RetryMode.AlwaysRetry retries 502s, so an outage would otherwise hang startup.
        await client.GetApplicationInfoAsync(new RequestOptions { CancelToken = cancellationToken });
        await client.StartAsync(); // returns immediately; heartbeat, resume and reconnect run in the background
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await client.StopAsync();
        await client.LogoutAsync();
    }

    /// <summary>
    /// Discord.Net reconnects with backoff forever, except for close codes 4006/4014. A reset token (401 / 4004) or bad
    /// intents/shard config (4010–4013) can never succeed and each attempt counts toward the invalid-request ban.
    /// </summary>
    public static bool IsFatal(Exception? exception)
    {
        for (var ex = exception; ex is not null; ex = ex.InnerException)
        {
            if (ex is HttpException { HttpCode: HttpStatusCode.Unauthorized }
                || ex is WebSocketClosedException { CloseCode: 4004 or (>= 4010 and <= 4014) })
            {
                return true;
            }
        }

        return false;
    }

    private Task StopOnFatalDisconnectAsync(Exception exception)
    {
        if (IsFatal(exception))
        {
            logger.LogCritical(exception, "Discord gateway disconnected with a non-recoverable error — stopping the host");
            // Exit non-zero and let the orchestrator alert. Restart with backoff, never in a tight loop: every restart
            // identifies again, and exhausting the daily identify limit (~1000) makes Discord reset the bot token.
            Environment.ExitCode = 2;
            lifetime.StopApplication();
        }

        return Task.CompletedTask;
    }

    private async Task RegisterCommandsOnceAsync()
    {
        if (Interlocked.Exchange(ref _commandsRegistered, 1) == 1)
        {
            return;
        }

        try
        {
            // Bulk overwrite (deleteMissing: true): Discord ends up with exactly the commands in code.
            if (options.Value.DevGuildId is { } guildId)
            {
                await interactions.RegisterCommandsToGuildAsync(guildId); // instant — use while developing
            }
            else
            {
                await interactions.RegisterCommandsGloballyAsync();
            }
        }
        catch (Exception ex)
        {
            Interlocked.Exchange(ref _commandsRegistered, 0); // retry on the next Ready
            logger.LogError(ex, "Registering application commands failed");
        }
    }

    private async Task HandleInteractionAsync(SocketInteraction interaction)
    {
        // RunMode.Async (default): returns as soon as the command is dispatched — the gateway task is never blocked.
        // Results (including precondition failures and exceptions) arrive in ReplyToFailureAsync.
        var context = new SocketInteractionContext(client, interaction);
        await interactions.ExecuteCommandAsync(context, services);
    }

    /// <summary>
    /// InteractionExecuted handler (also used by <see cref="ShardedGatewayService"/>): logs the failure and always tells
    /// the user something, privately.
    /// </summary>
    public static async Task ReplyToFailureAsync(ILogger logger, ICommandInfo? command, IInteractionContext context, IResult result)
    {
        if (result.IsSuccess)
        {
            return;
        }

        var interaction = context.Interaction;
        string userMessage;
        switch (result.Error)
        {
            case InteractionCommandError.UnmetPrecondition:
                userMessage = result.ErrorReason; // precondition messages are written for users
                break;
            case InteractionCommandError.UnknownCommand:
                logger.LogWarning("Unknown interaction {InteractionType} — stale command registration?", interaction.Type);
                userMessage = "This command is no longer available.";
                break;
            default:
                logger.LogError((result as ExecuteResult?)?.Exception,
                    "Interaction {Command} failed: {Error} {Reason}", command?.Name, result.Error, result.ErrorReason);
                userMessage = "Something went wrong. Please try again later."; // never leak exception details
                break;
        }

        if (interaction.Type == InteractionType.ApplicationCommandAutocomplete)
        {
            return; // autocomplete has no message to answer with
        }

        try
        {
            // Never "did not respond", never a public error (handles the deferred-placeholder case).
            await InteractionErrors.ReplyAsync(interaction, userMessage);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Could not deliver error message for interaction {InteractionId}", interaction.Id);
        }
    }
}
```

Why it's built this way:
- **Handlers subscribed once in `StartAsync`.** `Ready` fires after every non-resumed reconnect; subscribing
  there multiplies handlers.
- **Registration once per process**, guarded, and retried on the next `Ready` if it failed. Bulk overwrite
  means renamed/removed commands disappear from Discord automatically. It runs via `Task.Run` because `Ready`
  executes on the gateway task — awaiting REST there blocks heartbeats and every other event.
- **`GetApplicationInfoAsync` after login**: the socket client's `LoginAsync` only validates the token *format*
  (and only warns); without a REST call a revoked token produces an endless reconnect loop of 401s. Don't use
  `client.Rest.GetCurrentUserAsync()` for this — on the socket client it dereferences `CurrentUser`, which is
  null until READY, and throws on a *valid* token. (A plain `DiscordRestClient.LoginAsync` does validate.)
- **`StopOnFatalDisconnectAsync`**: Discord.Net retries every close code except 4006/4014 forever (backoff
  1 s doubling to 60 s with jitter). Stopping the host with a non-zero exit code turns a silent loop into a
  visible failure. Configure restarts **with backoff and a cap** (Docker `restart: on-failure:5`, Kubernetes
  CrashLoopBackOff) and alert — each restart identifies again, and exhausting the daily identify limit
  (`session_start_limit`, typically 1000/24 h) terminates all sessions and **resets the bot token**.
- **`ExecuteCommandAsync` under `RunMode.Async`** returns as soon as a known command is dispatched; unknown
  commands return an error immediately after raising `InteractionExecuted` inline. All outcomes are handled in
  `ReplyToFailureAsync`, which always tells the user something and never publicly (`InteractionErrors` below:
  a follow-up right after a public "thinking…" defer would *edit* that public placeholder — deprecated
  Discord behaviour that ignores the ephemeral flag). `ThrowOnError = false` because failures are handled there.
- `AutoServiceScopes` (default `true`) creates one DI scope per execution, so scoped services such as
  `DbContext` are safe to inject into **modules** (built per execution). Don't start background work from a
  module that captures them.
- **Autocomplete handlers, type converters and precondition attributes are singletons**: the Interaction
  Framework builds each once (autocomplete handlers with the provider passed to `AddModulesAsync`) and caches
  it. Give them no scoped constructor dependencies — resolve per call from the `services` argument, which *is*
  the per-execution scope (see `DocsAutocomplete` in rich-ui.md).

Error reply helper (shared by gateway and HTTP mode):

`InteractionErrors.cs`

```csharp
using Discord;

namespace MyApp.Discord;

/// <summary>
/// Delivers an error message for a failed interaction without ever leaking it into a public message.
/// </summary>
public static class InteractionErrors
{
    /// <param name="sendInitialResponse">
    /// HTTP mode only: the endpoint callback that turns <c>RestInteraction.Respond(...)</c> JSON into the HTTP response.
    /// </param>
    public static async Task ReplyAsync(IDiscordInteraction interaction, string message,
        Func<IDiscordInteraction, string, Task>? sendInitialResponse = null)
    {
        if (!interaction.HasResponded)
        {
            if (sendInitialResponse is not null)
            {
                await sendInitialResponse(interaction, message);
            }
            else
            {
                await interaction.RespondAsync(message, ephemeral: true, allowedMentions: AllowedMentions.None);
            }

            return;
        }

        // After DEFERRED_CHANNEL_MESSAGE ("thinking…") the first follow-up *edits* that placeholder and ignores the
        // ephemeral flag (deprecated Discord behaviour) — a public defer would turn into a public error.
        var original = await interaction.GetOriginalResponseAsync();
        var flags = original.Flags ?? MessageFlags.None;
        if (flags.HasFlag(MessageFlags.Loading))
        {
            if (flags.HasFlag(MessageFlags.Ephemeral))
            {
                await interaction.ModifyOriginalResponseAsync(m =>
                {
                    m.Content = message;
                    m.AllowedMentions = AllowedMentions.None;
                });
                return;
            }

            await interaction.DeleteOriginalResponseAsync(); // drop the public placeholder, then answer privately
        }

        await interaction.FollowupAsync(message, ephemeral: true, allowedMentions: AllowedMentions.None);
    }
}
```

## 5. Log bridge

`DiscordLog.cs`

```csharp
using Discord;
using Microsoft.Extensions.Logging;

namespace MyApp.Discord;

/// <summary>Bridges Discord.Net's <see cref="LogMessage"/> to <see cref="ILogger"/> with real severity mapping.</summary>
public static class DiscordLog
{
    public static Task Write(ILogger logger, LogMessage message)
    {
        var level = message.Severity switch
        {
            LogSeverity.Critical => LogLevel.Critical,
            LogSeverity.Error => LogLevel.Error,
            LogSeverity.Warning => LogLevel.Warning,
            LogSeverity.Info => LogLevel.Information,
            LogSeverity.Verbose => LogLevel.Debug,
            LogSeverity.Debug => LogLevel.Trace,
            _ => LogLevel.Information,
        };

        // Message is null for some exception-only entries; the gateway's reconnects arrive as Warning + exception.
        logger.Log(level, message.Exception, "[{DiscordSource}] {DiscordMessage}",
            message.Source, message.Message ?? message.Exception?.Message);
        return Task.CompletedTask;
    }
}
```

Discord.Net logs reconnects as `Warning` with an exception — expected occasionally. Alert on `Critical`,
and on handler-blocking warnings ("A … handler is blocking the gateway task"), which mean someone awaited
slow work inside a gateway event.

## 6. Modules

Modules are transient (one instance per execution) with constructor injection. Keep them thin: parse →
call an application service → build a card → respond.

`GeneralModule.cs`

```csharp
using Discord;
using Discord.Interactions;
using MyApp.Discord.Cards;

namespace MyApp.Bot.Modules;

// Usable everywhere: server installs, user installs, DMs and group DMs.
[CommandContextType(InteractionContextType.Guild, InteractionContextType.BotDm, InteractionContextType.PrivateChannel)]
[IntegrationType(ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall)]
public sealed class GeneralModule : InteractionModuleBase<SocketInteractionContext>
{
    [SlashCommand("about", "What is this app?")]
    public Task AboutAsync() =>
        RespondAsync(components: AboutCard.Build("MyApp", "1.0.0",
            iconUrl: Context.Client.CurrentUser.GetDisplayAvatarUrl(),
            websiteUrl: "https://example.com"));

    // Context-menu command: right-click a user → Apps → "Show profile". Names may contain spaces and capitals.
    [UserCommand("Show profile")]
    public Task ProfileAsync(IUser user) =>
        RespondAsync(components: ProfileCard.Build(user), ephemeral: true, allowedMentions: AllowedMentions.None);
}
```

`SearchModule.cs`

```csharp
using Discord;
using Discord.Interactions;
using MyApp.Discord.Cards;
using MyApp.Discord.Search;

namespace MyApp.Bot.Modules;

[CommandContextType(InteractionContextType.Guild, InteractionContextType.BotDm, InteractionContextType.PrivateChannel)]
[IntegrationType(ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall)]
public sealed class SearchModule(IDocsSearch search) : InteractionModuleBase<SocketInteractionContext>
{
    [SlashCommand("search", "Search the documentation")]
    public async Task SearchAsync(
        [Summary(description: "What are you looking for?"), MinLength(2), MaxLength(80), Autocomplete<DocsAutocomplete>]
        string query,
        [Summary(description: "Only show the results to me")] bool hidden = false)
    {
        // Ack inside 3 s; the token then stays valid for 15 min. Ephemeral is decided HERE, not on the edit.
        await DeferAsync(ephemeral: hidden);

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var hits = await search.SearchAsync(query, timeout.Token);

        // A deferred response accepts only the Ephemeral flag — the V2 flag goes on the edit.
        await ModifyOriginalResponseAsync(m =>
        {
            m.Components = SearchCard.Build(query, hits, page: 0);
            m.Flags = MessageFlags.ComponentsV2;
            m.AllowedMentions = AllowedMentions.None;
        });
    }

    // Wildcards bind in order: "search:page:2:intents" → page = 2, query = "intents". Stateless ⇒ survives restarts.
    [ComponentInteraction(CustomIds.SearchPagePattern)]
    public async Task PageAsync(int page, string query)
    {
        await DeferAsync(); // component defer = DEFERRED_UPDATE_MESSAGE: no "thinking…", then edit the same message

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var hits = await search.SearchAsync(query, timeout.Token);
        await ModifyOriginalResponseAsync(m => m.Components = SearchCard.Build(query, hits, page));
    }
}
```

`FeedbackModule.cs`

```csharp
using Discord;
using Discord.Interactions;
using MyApp.Discord.Cards;
using MyApp.Discord.Modals;

namespace MyApp.Bot.Modules;

[CommandContextType(InteractionContextType.Guild, InteractionContextType.BotDm, InteractionContextType.PrivateChannel)]
[IntegrationType(ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall)]
public sealed class FeedbackModule(ILogger<FeedbackModule> logger) : InteractionModuleBase<SocketInteractionContext>
{
    // A modal must be the FIRST response — no defer before it, and no slow work either (3 s still applies).
    [SlashCommand("feedback", "Send feedback to the team")]
    public Task FeedbackAsync() => RespondWithModalAsync<FeedbackModal>(CustomIds.FeedbackModal);

    [ModalInteraction(CustomIds.FeedbackModal)]
    public async Task SubmitAsync(FeedbackModal feedback)
    {
        // Store the body in your app (it's user content, possibly personal data) — log only metadata.
        logger.LogInformation("Feedback from {UserId} ({Topic}, {Length} chars)",
            Context.User.Id, string.Join(",", feedback.Topic), feedback.Body.Length);

        await RespondAsync(components: FeedbackCard.Thanks(feedback), ephemeral: true,
            allowedMentions: AllowedMentions.None); // echoing user input — never let it ping
    }
}
```

`AnnouncementModule.cs`

```csharp
using Discord;
using Discord.Interactions;
using MyApp.Discord.Announcements;
using MyApp.Discord.Cards;

namespace MyApp.Bot.Modules;

// Server-only, hidden from members without Manage Server (admins can override per role in Server Settings → Integrations).
[CommandContextType(InteractionContextType.Guild)]
[IntegrationType(ApplicationIntegrationType.GuildInstall)]
public sealed class AnnouncementModule(IAnnouncementQueue queue) : InteractionModuleBase<SocketInteractionContext>
{
    [SlashCommand("announce", "Post an announcement to the announcement channel")]
    [DefaultMemberPermissions(GuildPermission.ManageGuild)]
    public Task AnnounceAsync(
        [MaxLength(200)] string title,
        [MaxLength(2000)] string body,
        [Summary(description: "Optional link for a 'Read more' button")] string? link = null)
    {
        // Link buttons need an http(s) URL — anything else is rejected by Discord when the card is posted.
        if (link is not null && !(Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http"))
        {
            return RespondAsync("That link must be an absolute http(s) URL.", ephemeral: true);
        }

        var accepted = queue.TryEnqueue(new Announcement(Guid.NewGuid(), title, body, LinkUrl: link));
        return RespondAsync(accepted ? "Queued — it will appear in a moment." : "Too many announcements queued, try again shortly.",
            ephemeral: true);
    }

    [ComponentInteraction(CustomIds.AnnouncementAckPattern)]
    public Task AcknowledgeAsync(string announcementId) =>
        RespondAsync("Thanks for reading! ✅", ephemeral: true);
}
```

The cards, modal, custom ids and autocomplete handler these use are in [rich-ui.md](rich-ui.md); the queue
and publisher in [app-integration.md](app-integration.md).

Precondition example (custom rule, reusable as an attribute; `IAccountLinks` is your app's service):

`RequireLinkedAccountAttribute.cs`

```csharp
using Discord;
using Discord.Interactions;
using Microsoft.Extensions.DependencyInjection;

namespace MyApp.Discord.Preconditions;

public interface IAccountLinks
{
    Task<bool> IsLinkedAsync(ulong discordUserId, CancellationToken ct = default);
}

/// <summary>Custom precondition: usable on modules or methods; the error text is shown to the user.</summary>
public sealed class RequireLinkedAccountAttribute : PreconditionAttribute
{
    public override async Task<PreconditionResult> CheckRequirementsAsync(
        IInteractionContext context, ICommandInfo commandInfo, IServiceProvider services)
    {
        var accounts = services.GetRequiredService<IAccountLinks>();
        return await accounts.IsLinkedAsync(context.User.Id)
            ? PreconditionResult.FromSuccess()
            : PreconditionResult.FromError("Link your account first with `/link`.");
    }
}
```

Interaction Framework attribute cheat sheet:

| Attribute | Purpose |
|---|---|
| `[SlashCommand("name", "desc")]`, `[Group("name", "desc")]` | Slash command / subcommand group (max 2 group levels) |
| `[UserCommand("Name")]`, `[MessageCommand("Name")]` | Context-menu commands (`IUser` / `IMessage` parameter) |
| `[ComponentInteraction("feature:action:*")]` | Button/select handler; `*` captures bind to parameters in order; select values = last `string[]`/`IUser[]`/… parameter; inside a `[Group]` ids are prefixed unless `ignoreGroupNames: true` |
| `[ModalInteraction("id")]` | Modal submit handler taking the `IModal` class |
| `[Summary]`, `[Choice]`, `[MinValue]/[MaxValue]`, `[MinLength]/[MaxLength]`, `[ChannelTypes]` | Option metadata — enums with ≤ 25 values become choices automatically |
| `[Autocomplete<THandler>]` | Attach an `AutocompleteHandler` |
| `[CommandContextType]`, `[IntegrationType]` | Where the command exists (module or method level; parents propagate since 3.20) |
| `[DefaultMemberPermissions]` | Hide from members lacking the permission |
| `[RequireUserPermission]`, `[RequireBotPermission]`, `[RequireContext]`, `[RequireOwner]`, `[RequireRole]` | Runtime preconditions |
| `[DontAutoRegister]` | Exclude a module from `Register*Async` (e.g. guild-specific admin modules) |

Renamed/obsolete: `[EnabledInDm]`, `[DefaultPermission]` (use the context/permission attributes),
`SelectMenuOptionAttribute` → `EnumOptionAttribute` (3.20).

## 7. Sharding & scaling notes

`ShardedGatewayService.cs`

```csharp
using Discord;
using Discord.Interactions;
using Discord.WebSocket;
using Microsoft.Extensions.Options;
using MyApp.Discord;

namespace MyApp.Bot;

/// <summary>
/// Variant for bots approaching 2,500 guilds per shard. Register instead of DiscordGatewayService, with
/// <c>new DiscordShardedClient(config)</c> as the client and <c>new InteractionService(shardedClient, …)</c>.
/// Differences: ShardReady fires per shard (register once), and contexts are ShardedInteractionContext.
/// </summary>
public sealed class ShardedGatewayService(
    DiscordShardedClient client,
    InteractionService interactions,
    IServiceProvider services,
    IOptions<DiscordOptions> options,
    IHostApplicationLifetime lifetime,
    ILogger<ShardedGatewayService> logger) : IHostedService
{
    private int _commandsRegistered;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        client.Log += message => DiscordLog.Write(logger, message);
        interactions.Log += message => DiscordLog.Write(logger, message);
        client.ShardReady += shard =>
        {
            _ = Task.Run(() => RegisterCommandsOnceAsync(shard)); // off the gateway task
            return Task.CompletedTask;
        };
        client.ShardDisconnected += StopOnFatalDisconnectAsync;
        client.InteractionCreated += interaction =>
            interactions.ExecuteCommandAsync(new ShardedInteractionContext(client, interaction), services);
        interactions.InteractionExecuted += (command, context, result) =>
            DiscordGatewayService.ReplyToFailureAsync(logger, command, context, result); // same error replies

        await interactions.AddModulesAsync(typeof(ShardedGatewayService).Assembly, services);
        await client.LoginAsync(TokenType.Bot, options.Value.Token).WaitAsync(cancellationToken);
        // Real token check before identifying N shards.
        await client.GetApplicationInfoAsync(new RequestOptions { CancelToken = cancellationToken });
        await client.StartAsync(); // TotalShards null → Discord's recommended count; identifies respect max_concurrency
    }

    private Task StopOnFatalDisconnectAsync(Exception exception, DiscordSocketClient shard)
    {
        if (DiscordGatewayService.IsFatal(exception)) // same fatal close codes as the single-connection service
        {
            logger.LogCritical(exception, "Shard {ShardId} disconnected with a non-recoverable error — stopping the host", shard.ShardId);
            Environment.ExitCode = 2;
            lifetime.StopApplication();
        }

        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await client.StopAsync();
        await client.LogoutAsync();
    }

    private async Task RegisterCommandsOnceAsync(DiscordSocketClient shard)
    {
        if (Interlocked.Exchange(ref _commandsRegistered, 1) == 1)
        {
            return; // ShardReady fires for every shard — register once
        }

        try
        {
            // sharded = production-sized: register globally (DevGuildId is for the single-shard dev setup above)
            await interactions.RegisterCommandsGloballyAsync();
        }
        catch (Exception ex)
        {
            Interlocked.Exchange(ref _commandsRegistered, 0);
            logger.LogError(ex, "Registering application commands failed (shard {ShardId})", shard.ShardId);
        }
    }
}
```


- One process per token unless sharded: two instances with the same token both receive every event and both
  answer interactions (the second fails with "already acknowledged").
- Before 2,500 guilds per shard: switch to the sharded variant above (`TotalShards` or Discord's
  recommendation). DMs and entitlement events arrive on shard 0 only.
- Need horizontal scale for interaction handling only? HTTP interactions scale like any web app.
- `AlwaysDownloadUsers = true` requires `GuildMembers` and costs startup time and memory — fetch members on
  demand (`GetUserAsync`) instead.

## 8. Production checklist

- [ ] Intents minimal; privileged intents justified and enabled in the portal
- [ ] Token from secret store; startup fails on a bad token; host stops on fatal disconnect; restarts back off
- [ ] DM / user-install contexts verified on a separate dev application with global registration
- [ ] Commands: contexts + integration types declared; admin commands gated; guild registration only in dev
- [ ] Every slow command defers; every failure answered ephemerally; logs carry interaction id + command name
- [ ] Custom ids centralised, ≤ 100 chars, handlers stateless
- [ ] `AllowedMentions.None` on app/user content
- [ ] Exactly one process per token (or sharded) for the gateway worker
- [ ] `/health/live` dependency-free (a Discord outage must not restart the bot — restarts re-identify);
      `client.ConnectionState` only on `/health/ready` or as a metric. A Worker-SDK bot has no HTTP endpoint:
      rely on the exit code + the orchestrator's restart policy with backoff
- [ ] Container image keeps ICU (no invariant globalization); not AOT-published
- [ ] `docs/` updated in the same change: portal setup, intents and why, command list, which transport and why
      (an ADR via `/noobit:adr` for the gateway-vs-HTTP decision)
