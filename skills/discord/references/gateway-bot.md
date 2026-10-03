# Gateway bot — reference implementation

A long-running bot on the gateway with the Interaction Framework, hosted in the .NET Generic Host.
Code under a `File.cs` heading targets Discord.Net 3.20.1; `// excerpt` blocks are illustrations. Tests:
[testing.md](testing.md).

Code blocks omit `using` directives (add the System.*, Discord.*, Microsoft.Extensions.* and `MyApp.*` namespaces the
types come from); the file-scoped namespace shows which project a file belongs to.

**Contents:** 1 Solution layout & packages · 2 Options & secrets · 3 DI registration · 4 Hosted service
(lifecycle, registration, error replies, fatal disconnects) · 5 Log bridge · 6 Modules · 7 Sharding & scaling
notes · 8 Production checklist

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

Central package management (`noobit:aspnet-backend`): versions live only in `Directory.Packages.props` — pin
Discord.Net to the version you verified against, use the latest 10.0.x patch for Microsoft.Extensions.*:

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Discord.Net.Interactions" Version="3.20.1" />  <!-- pulls Core + Rest -->
    <PackageVersion Include="Discord.Net.WebSocket" Version="3.20.1" />     <!-- gateway; only the bot project -->
    <PackageVersion Include="Discord.Net.Webhook" Version="3.20.1" />       <!-- only if you post via webhook URLs -->
    <PackageVersion Include="Microsoft.Extensions.Hosting" Version="10.0.12" />
    <PackageVersion Include="Microsoft.Extensions.Hosting.Abstractions" Version="10.0.12" />
    <PackageVersion Include="Microsoft.Extensions.Options" Version="10.0.12" />  <!-- [OptionsValidator] generator -->
  </ItemGroup>
</Project>
```

Project files reference packages without versions. The SDK choice matters: the code relies on implicit usings —
`Microsoft.NET.Sdk.Worker` brings the `IServiceCollection`/`ILogger<T>`/hosting usings for the bot,
`Microsoft.NET.Sdk.Web` adds `StatusCodes`/`HttpContext` for the HTTP app. Keep `Program` of the worker internal
so the tests' `WebApplicationFactory<Program>` resolves to the web app's public `Program`.

```xml
<!-- MyApp.Discord.csproj (Sdk="Microsoft.NET.Sdk") -->
<ItemGroup>
  <PackageReference Include="Discord.Net.Interactions" />
  <PackageReference Include="Discord.Net.Webhook" />
  <PackageReference Include="Microsoft.Extensions.Hosting.Abstractions" />
  <PackageReference Include="Microsoft.Extensions.Options" />
</ItemGroup>

<!-- MyApp.Bot.csproj (Sdk="Microsoft.NET.Sdk.Worker") -->
<ItemGroup>
  <ProjectReference Include="..\MyApp.Discord\MyApp.Discord.csproj" />
  <PackageReference Include="Discord.Net.WebSocket" />
  <PackageReference Include="Microsoft.Extensions.Hosting" />
</ItemGroup>

<!-- MyApp.Interactions.csproj (Sdk="Microsoft.NET.Sdk.Web"): only the ProjectReference to MyApp.Discord -->
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

    /// <summary>Bot token (Developer Portal → Bot). Secret: user-secrets (dev), secret file <c>/run/secrets/Discord__Token</c> (prod), never appsettings.
    /// Required or not depends on the hosting mode — checked at registration (SKILL.md "Stack fit").</summary>
    public string Token { get; init; } = "";

    /// <summary>Hex Ed25519 public key (Developer Portal → General Information). Needed by every endpoint Discord signs
    /// (HTTP interactions, Webhook Events) — required by those registrations; empty passes here.</summary>
    [RegularExpression("^[0-9a-fA-F]{64}$", ErrorMessage = "Discord:PublicKey must be the 64-char hex public key")]
    public string PublicKey { get; init; } = "";

    /// <summary>OAuth2 client id (Portal → OAuth2) — account linking only (app-integration.md §6); empty passes here.</summary>
    [RegularExpression("^[0-9]{17,20}$", ErrorMessage = "Discord:ClientId must be the application's snowflake id")]
    public string ClientId { get; init; } = "";

    /// <summary>OAuth2 client secret — a secret like <see cref="Token"/>; account linking only.</summary>
    public string ClientSecret { get; init; } = "";

    /// <summary>When set, commands are registered to this guild only (instant updates) instead of globally.</summary>
    public ulong? DevGuildId { get; init; }

    /// <summary>Registration is a bulk overwrite: only ONE process per application — the one owning the interaction
    /// modules — may register. Set <c>false</c> on any other module-owning process (app-integration.md §3).</summary>
    public bool RegisterCommands { get; init; } = true;

    /// <summary>Channel the application posts announcements to.</summary>
    public ulong? AnnouncementChannelId { get; init; }
}

/// <summary>Source-generated, reflection-free validator for the DataAnnotations above.</summary>
[OptionsValidator]
public sealed partial class DiscordOptionsValidator : IValidateOptions<DiscordOptions>;
```

```jsonc
// appsettings.json — non-secret values only
{ "Discord": { "DevGuildId": 123456789012345678, "AnnouncementChannelId": 234567890123456789 } }
```

```bash
dotnet user-secrets set "Discord:Token" "<bot token>"     # local
# container: compose `secrets:` → /run/secrets/Discord__Token, read by
# builder.Configuration.AddKeyPerFile("/run/secrets", optional: true) — not a compose `environment:` value
# (leaks via docker inspect; aspnet-backend references/configuration-secrets.md)
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
namespace MyApp.Bot;

public static class DiscordGatewayExtensions
{
    public static IServiceCollection AddDiscordGateway(this IServiceCollection services)
    {
        services.AddOptions<DiscordOptions>()
            .BindConfiguration(DiscordOptions.SectionName)
            .Validate(o => !string.IsNullOrWhiteSpace(o.Token), "Discord:Token is required") // mode-specific rule
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<DiscordOptions>, DiscordOptionsValidator>(); // DataAnnotations rules

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

        services.AddSingleton<IDocsSearch, DocsSearch>(); // your implementation (rich-ui.md §5)
        return services;
    }
}
```

`Program.cs` is `Host.CreateApplicationBuilder(args)` + `builder.Services.AddDiscordGateway()` + `RunAsync()`.

Notes:
- `DiscordSocketClient`, `InteractionService` are singletons; the container owns disposal. Hosted services
  only `StopAsync`/`LogoutAsync` — never dispose a shared client yourself.
- Registering it as `IDiscordClient` lets application services (publisher, admin tools) depend on the
  interface — the same code then works with a `DiscordRestClient` in a web app and is mockable in tests.
- **Where it runs** and **health**: SKILL.md "Choose the connection" and rule 11. Inside an existing ASP.NET
  Core app the same `AddDiscordGateway()` call works — only while that app has one replica.

## 4. Hosted service

`DiscordGatewayService.cs`

```csharp
namespace MyApp.Bot;

/// <summary>Owns the gateway lifecycle. Events are subscribed exactly once here — never inside <c>Ready</c>.</summary>
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
        interactions.InteractionExecuted += (command, context, result) =>
            InteractionErrors.HandleExecutedAsync(logger, command, context, result);

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

    /// <summary>401 / 4004 / 4010–4014 can never succeed (each retry counts toward the invalid-request ban); on 4006
    /// Discord.Net stops reconnecting by itself, so the process would sit disconnected — restart it instead.</summary>
    public static bool IsFatal(Exception? exception)
    {
        for (var ex = exception; ex is not null; ex = ex.InnerException)
        {
            if (ex is HttpException { HttpCode: HttpStatusCode.Unauthorized }
                || ex is WebSocketClosedException { CloseCode: 4004 or 4006 or (>= 4010 and <= 4014) })
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
            Environment.ExitCode = 2; // non-zero: the orchestrator alerts and restarts with backoff (SKILL.md rule 10)
            lifetime.StopApplication();
        }

        return Task.CompletedTask;
    }

    private async Task RegisterCommandsOnceAsync()
    {
        // Bulk overwrite: only the one process that owns the modules registers (app-integration.md §3).
        if (!options.Value.RegisterCommands || Interlocked.Exchange(ref _commandsRegistered, 1) == 1)
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

    // RunMode.Async: returns once dispatched; all outcomes (failures, preconditions) arrive in InteractionExecuted.
    private Task HandleInteractionAsync(SocketInteraction interaction) =>
        interactions.ExecuteCommandAsync(new SocketInteractionContext(client, interaction), services);
}
```

Why it's built this way (beyond SKILL.md rules 3, 4, 10):
- **Registration** is retried on the next `Ready` if it failed; bulk overwrite makes renamed/removed commands
  disappear. `Task.Run` because `Ready` executes on the gateway task — awaiting REST there blocks heartbeats.
- **Token check**: don't use `client.Rest.GetCurrentUserAsync()` — on the socket client it dereferences
  `CurrentUser` (null until READY) and throws on a *valid* token. (A plain `DiscordRestClient.LoginAsync` does
  validate.)
- **Fatal disconnects**: Discord.Net's backoff is 1 s doubling to 60 s with jitter, forever. Configure restarts
  **with backoff and a cap** (Docker `restart: on-failure:5`, Kubernetes CrashLoopBackOff) and alert.
- **Error replies** never go public: a follow-up right after a public "thinking…" defer would *edit* that
  placeholder (deprecated Discord behaviour that ignores the ephemeral flag) — hence `InteractionErrors` below.
- `AutoServiceScopes` (default `true`) creates one DI scope per execution, so scoped services such as
  `DbContext` are safe to inject into **modules** (built per execution). Don't start background work from a
  module that captures them.
- **Autocomplete handlers, type converters and precondition attributes are singletons** (built once, cached):
  resolve scoped services per call from the `services` argument — the per-execution scope (`DocsAutocomplete`
  in rich-ui.md).

Error replies (shared library; the HTTP host subscribes the same handler):

`InteractionErrors.cs`

```csharp
namespace MyApp.Discord;

/// <summary>
/// Error replies for both hosting modes: always tell the user something, never publicly, never leak details.
/// </summary>
public static class InteractionErrors
{
    /// <summary><c>InteractionExecuted</c> handler — gateway, sharded and HTTP hosts subscribe the same method.</summary>
    public static async Task HandleExecutedAsync(ILogger logger, ICommandInfo? command, IInteractionContext context, IResult result)
    {
        if (result.IsSuccess)
        {
            return;
        }

        var interaction = context.Interaction;
        string message;
        switch (result.Error)
        {
            case InteractionCommandError.UnmetPrecondition:
                message = result.ErrorReason; // precondition messages are written for users
                break;
            case InteractionCommandError.UnknownCommand:
                logger.LogWarning("Unknown interaction {InteractionType} — stale command registration?", interaction.Type);
                message = "This command is no longer available.";
                break;
            default:
                logger.LogError((result as ExecuteResult?)?.Exception,
                    "Interaction {Command} failed: {Error} {Reason}", command?.Name, result.Error, result.ErrorReason);
                message = "Something went wrong. Please try again later."; // never leak exception details
                break;
        }

        if (interaction.Type == InteractionType.ApplicationCommandAutocomplete)
        {
            return; // autocomplete has no message to answer with
        }

        // HTTP mode: the initial response must go through the endpoint callback — Respond() only builds JSON, and
        // IDiscordInteraction.RespondAsync on a RestInteraction silently discards it. Later replies are REST calls.
        var callback = (context as IRestInteractionContext)?.InteractionResponseCallback;
        Func<IDiscordInteraction, string, Task>? sendInitial = callback is not null && interaction is RestInteraction rest
            ? (_, text) => callback(rest.Respond(text, ephemeral: true, allowedMentions: AllowedMentions.None))
            : null;
        try
        {
            await ReplyAsync(interaction, message, sendInitial);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Could not deliver error message for interaction {InteractionId}", interaction.Id);
        }
    }

    /// <param name="sendInitialResponse">HTTP mode only: turns <c>RestInteraction.Respond(...)</c> JSON into the HTTP response.</param>
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
namespace MyApp.Discord;

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
        // No V2 flag needed: this edits a message that already is V2, and Discord never removes that flag.
        await ModifyOriginalResponseAsync(m => m.Components = SearchCard.Build(query, hits, page));
    }
}
```

`FeedbackModule.cs` and `AnnouncementModule.cs`

```csharp
namespace MyApp.Bot.Modules;

[CommandContextType(InteractionContextType.Guild, InteractionContextType.BotDm, InteractionContextType.PrivateChannel)]
[IntegrationType(ApplicationIntegrationType.GuildInstall, ApplicationIntegrationType.UserInstall)]
public sealed class FeedbackModule(ILogger<FeedbackModule> logger) : InteractionModuleBase<SocketInteractionContext>
{
    // A modal must be the FIRST response — no defer before it, and no slow work either (3 s still applies).
    [SlashCommand("feedback", "Send feedback to the team")]
    public Task FeedbackAsync() => RespondWithModalAsync<FeedbackModal>(CustomIds.FeedbackModal);

    [ModalInteraction(CustomIds.FeedbackModal)]
    public Task SubmitAsync(FeedbackModal feedback)
    {
        // User content, possibly personal data: store it in your app, log only metadata.
        logger.LogInformation("Feedback from {UserId} ({Length} chars)", Context.User.Id, feedback.Body.Length);
        return RespondAsync(components: FeedbackCard.Thanks(feedback), ephemeral: true, allowedMentions: AllowedMentions.None);
    }
}

[CommandContextType(InteractionContextType.Guild)]
[IntegrationType(ApplicationIntegrationType.GuildInstall)]
public sealed class AnnouncementModule(IAnnouncementQueue queue) : InteractionModuleBase<SocketInteractionContext>
{
    [SlashCommand("announce", "Post an announcement to the announcement channel")]
    [DefaultMemberPermissions(GuildPermission.ManageGuild)] // hidden from non-admins; admins can override per role
    public Task AnnounceAsync([MaxLength(200)] string title, [MaxLength(2000)] string body, string? link = null)
    {
        // Link buttons need an http(s) URL — anything else is rejected by Discord when the card is posted.
        if (link is not null && !(Uri.TryCreate(link, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http"))
        {
            return RespondAsync("That link must be an absolute http(s) URL.", ephemeral: true);
        }

        var accepted = queue.TryEnqueue(new Announcement(Guid.NewGuid(), title, body, LinkUrl: link)); // never await Discord here
        return RespondAsync(accepted ? "Queued — it will appear in a moment." : "Too many announcements queued, try again shortly.",
            ephemeral: true);
    }

    [ComponentInteraction(CustomIds.AnnouncementAckPattern)] // "announce:ack:*" → string (wildcards don't bind Guid)
    public Task AcknowledgeAsync(string announcementId) => RespondAsync("Thanks for reading! ✅", ephemeral: true);
}
```

The cards, modal, custom ids and autocomplete handler these use are in [rich-ui.md](rich-ui.md); the queue
and publisher in [app-integration.md](app-integration.md).

Custom precondition (reusable attribute; the error text is shown to the user; `IAccountLinks` is your service).
Preconditions are cached singletons — resolve services from the `services` argument:

```csharp
// excerpt
public sealed class RequireLinkedAccountAttribute : PreconditionAttribute
{
    public override async Task<PreconditionResult> CheckRequirementsAsync(
        IInteractionContext context, ICommandInfo commandInfo, IServiceProvider services) =>
        await services.GetRequiredService<IAccountLinks>().IsLinkedAsync(context.User.Id)
            ? PreconditionResult.FromSuccess()
            : PreconditionResult.FromError("Link your account first with `/link`.");
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

Before 2,500 guilds per shard, switch to `DiscordShardedClient` (`TotalShards` null → Discord's recommended
count; identifies respect `max_concurrency`) with `new InteractionService(shardedClient, …)`. A
`ShardedGatewayService` is `DiscordGatewayService` with these differences:

```csharp
// excerpt — ShardedGatewayService.cs: a copy of DiscordGatewayService with DiscordShardedClient injected instead
// of DiscordSocketClient. Only the event wiring in StartAsync changes; the log bridge, AddModulesAsync,
// login + GetApplicationInfoAsync, StopAsync and the private members (_commandsRegistered,
// StopOnFatalDisconnectAsync, RegisterCommandsOnceAsync) are copied unchanged (omitted here).
client.ShardReady += shard => // named on purpose: with "_ =>", "_ = Task.Run(...)" below assigns to the parameter
{
    _ = Task.Run(RegisterCommandsOnceAsync); // fires once per shard; the Interlocked guard registers once per process
    return Task.CompletedTask;
};
client.ShardDisconnected += (exception, _) => StopOnFatalDisconnectAsync(exception); // same IsFatal check
client.InteractionCreated += interaction =>
    interactions.ExecuteCommandAsync(new ShardedInteractionContext(client, interaction), services);
interactions.InteractionExecuted += (command, context, result) =>
    InteractionErrors.HandleExecutedAsync(logger, command, context, result); // same error replies
```

- Still one sharded client per token (SKILL.md "Choose the connection"). DMs and entitlement events arrive on
  shard 0 only.
- Need horizontal scale for interaction handling only? HTTP interactions scale like any web app.
- `AlwaysDownloadUsers = true` requires `GuildMembers` and costs startup time and memory — fetch members on
  demand (`GetUserAsync`) instead.

## 8. Production checklist

SKILL.md core rules 1–15 and "Stack fit" are the checklist; additionally:
- [ ] DM / user-install contexts verified on a separate dev application with global registration
- [ ] Logs carry interaction id + command name; alerts on `Critical` and gateway-blocking warnings
- [ ] A Worker-SDK bot has no HTTP endpoint: rely on the exit code + the orchestrator's restart policy with backoff
- [ ] `docs/` updated in the same change: portal setup, intents and why, command list, which transport and why
      (an ADR via `/noobit:new-adr` for the gateway-vs-HTTP decision)
