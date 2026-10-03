# Testing Discord integrations

General test conventions (xUnit v3 on MTP, NSubstitute, WebApplicationFactory, Testcontainers) live in
`noobit:dotnet-testing`; this file covers the Discord-specific seams. You can't (and shouldn't) hit the real
gateway in CI. Test at five seams — together they catch the bugs that matter here (invalid modal attributes,
PING parsing, bad-token reconnect loops, stalls on unknown commands in HTTP mode, DM parsing on an anonymous
client, a webhook client whose failed construction is cached forever). Behaviour that needs a real connection
(e.g. the token check succeeding with a *valid* token) goes into the manual dev-app smoke run.

| Seam | What it proves | Tooling |
|---|---|---|
| Pure card builders | Layout, limits (40 components, 100-char ids, 25 items), pagination edges, no split surrogates | xUnit, no mocks |
| Routing contract | Modules build (attributes valid, DI resolvable), every custom id the cards emit hits a handler, permissions/contexts as intended | Real `InteractionService` with an unconnected client + NSubstitute for interaction data |
| HTTP endpoint end-to-end | Signature handling, PING, response JSON for commands/modals/defer/errors, body cap (413), replay window | `WebApplicationFactory` + real Ed25519 key pair (BouncyCastle) + raw Discord v10 payloads |
| Publishers / app services | Right channel, flags, mentions, error handling, queue-full, error replies, fatal close codes | NSubstitute on `IDiscordClient`, `ITextChannel`, `IUserMessage`, `IDiscordInteraction` |
| Account linking (app-integration.md §6) | Session required, `state` carries the starting user, pending only for that user and this scheme, confirm is antiforgery-validated and one-shot, 409 on a taken Discord id, not on the login limiter | `WebApplicationFactory` of the BFF + `dotnet-testing`'s `TestAuthHandler` session + stubbed OAuth backchannel |

Plus one manual smoke run against a development application/guild before release (commands appear,
buttons route, modals submit) — the only thing tests can't prove is Discord's acceptance of a payload.

Project setup (xUnit v3 on Microsoft.Testing.Platform — `global.json` needs
`{ "test": { "runner": "Microsoft.Testing.Platform" } }`; versions in `Directory.Packages.props`):

```xml
<PackageReference Include="xunit.v3" />
<PackageReference Include="NSubstitute" />
<PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" />
<PackageReference Include="BouncyCastle.Cryptography" />  <!-- test-only: sign payloads like Discord does -->

<!-- xunit.v3 adds no global using: without this every [Fact]/Assert is CS0246 -->
<Using Include="Xunit" />
```

Code blocks omit `using` directives (add the System.*, Discord.*, Microsoft.Extensions.* and `MyApp.*` namespaces the
types come from); the file-scoped namespace shows which project a file belongs to.

## Card builders

`ComponentTree.cs`

```csharp
namespace MyApp.Discord.Tests;

/// <summary>Flattens a V2 component tree (containers, sections + accessories, rows) for assertions.</summary>
internal static class ComponentTree
{
    public static IEnumerable<IMessageComponent> Flatten(MessageComponent message) => message.Components.SelectMany(Flatten);

    private static IEnumerable<IMessageComponent> Flatten(IMessageComponent component)
    {
        yield return component;
        if (component is SectionComponent { Accessory: { } accessory })
        {
            yield return accessory;
        }

        if (component is INestedComponent nested)
        {
            foreach (var child in nested.Components.SelectMany(Flatten))
            {
                yield return child;
            }
        }
    }
}
```

Representative card test (repeat the pattern for pagination edges, empty results, link-only webhook cards,
the longest allowed custom id, and an emoji straddling a truncation cut):

```csharp
// excerpt — CardTests.cs
[Fact]
public void Search_card_first_page_disables_prev_and_links_next_page()
{
    var hits = Enumerable.Range(1, 12).Select(i => new DocHit($"Doc {i}", $"https://example.com/{i}", "snippet")).ToArray();
    var card = SearchCard.Build("doc", hits, page: 0);
    var buttons = ComponentTree.Flatten(card).OfType<ButtonComponent>().Where(b => b.Style != ButtonStyle.Link).ToList();

    Assert.True(ComponentTree.Flatten(card).Count() <= 40, "Discord allows at most 40 components per V2 message");
    Assert.True(buttons[0].IsDisabled);                                  // ◀ Prev
    Assert.Equal("1 / 3", buttons[1].Label);
    Assert.Equal(CustomIds.SearchPage(1, "doc"), buttons[2].CustomId);   // Next ▶
}
```

## Routing contract

No Discord connection needed — clients are constructed but never logged in:

```csharp
// excerpt — RoutingTests.cs
private static async Task<InteractionService> GatewayInteractions()
{
    var services = new ServiceCollection()
        .AddSingleton<IDocsSearch>(Substitute.For<IDocsSearch>())
        .AddSingleton(typeof(ILogger<>), typeof(NullLogger<>))
        .AddSingleton<IAnnouncementQueue, AnnouncementQueue>()
        .BuildServiceProvider();
    var service = new InteractionService(new DiscordSocketClient()); // HTTP modules: new DiscordRestClient()
    await service.AddModulesAsync(typeof(MyApp.Bot.DiscordGatewayService).Assembly, services);
    return service;
}

[Theory]
[InlineData("search:page:1:intents")]
[InlineData("search:page:12:with:colons")]
[InlineData("announce:ack:0f8fad5bd9cb469fa165708355c3b5e7")]
public async Task Custom_ids_route_to_a_component_handler(string customId)
{
    var data = Substitute.For<IComponentInteractionData>();
    data.CustomId.Returns(customId);
    var interaction = Substitute.For<IComponentInteraction>();
    interaction.Data.Returns(data);

    Assert.True((await GatewayInteractions()).SearchComponentCommand(interaction).IsSuccess, customId);
}

[Fact]
public async Task Announce_command_requires_manage_guild_and_is_guild_only()
{
    var announce = (await GatewayInteractions()).SlashCommands.Single(c => c.Name == "announce");

    Assert.Equal(GuildPermission.ManageGuild, announce.DefaultMemberPermissions);
    Assert.Equal([InteractionContextType.Guild], announce.ContextTypes);
}
```

Also assert the expected command list (`SlashCommands`, `ContextCommands`, `ModalCommands`) and that card
custom ids route in **both** hosting modes.

## HTTP endpoint end-to-end

The fixture generates a real Ed25519 key pair and signs requests exactly as Discord does. It sets no token —
no login, no registration:

```csharp
// HttpInteractionsEndpointTests.cs (usings: Org.BouncyCastle.Crypto.{Generators,Parameters,Signers}, Org.BouncyCastle.Security,
// Microsoft.AspNetCore.TestHost, Microsoft.Extensions.DependencyInjection.Extensions, System.Text.Json.Nodes)
public sealed class App : WebApplicationFactory<Program>
{
    public Ed25519PrivateKeyParameters PrivateKey { get; }
    public string PublicKeyHex { get; }
    public FakeWebhookEventInbox Inbox { get; } = new();

    public App()
    {
        var generator = new Ed25519KeyPairGenerator();
        generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
        var pair = generator.GenerateKeyPair();
        PrivateKey = (Ed25519PrivateKeyParameters)pair.Private;
        PublicKeyHex = Convert.ToHexStringLower(((Ed25519PublicKeyParameters)pair.Public).GetEncoded());
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("Discord:PublicKey", PublicKeyHex);
        // The EF inbox needs a database: swap it, or ValidateOnBuild fails on the missing DbContext.
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IWebhookEventInbox>();
            services.AddSingleton<IWebhookEventInbox>(Inbox);
        });
    }
}

/// <summary>Unique-index semantics of the real inbox: the same dedupe key is stored once.</summary>
public sealed class FakeWebhookEventInbox : IWebhookEventInbox
{
    public ConcurrentDictionary<string, (string EventType, byte[] Body)> Events { get; } = new();

    public Task StoreAsync(string eventType, string dedupeKey, byte[] rawBody, CancellationToken ct)
    {
        Events.TryAdd(dedupeKey, (eventType, rawBody));
        return Task.CompletedTask;
    }
}

public sealed class HttpInteractionsEndpointTests(App app) : IClassFixture<App>
{
    [Fact]
    public async Task Unknown_command_gets_an_ephemeral_error_within_budget()
    {
        var started = DateTimeOffset.UtcNow;
        var (_, json) = await PostSignedAsync(SlashCommand("does-not-exist"));

        Assert.Equal(4, json!["type"]!.GetValue<int>());                          // CHANNEL_MESSAGE_WITH_SOURCE
        Assert.Equal(1 << 6, json["data"]!["flags"]!.GetValue<int>() & (1 << 6)); // EPHEMERAL
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2), "error reply must beat Discord's 3 s deadline");
    }

    // Raw v10 guild APPLICATION_COMMAND payload — see the payload notes below for why each field is there.
    private static string SlashCommand(string name, string options = "[]") => $$"""
        {
          "type": 2, "id": "{{Snowflake()}}", "application_id": "100000000000000001", "token": "test-token", "version": 1,
          "channel_id": "100000000000000002", "guild_id": "100000000000000006",
          "channel": { "id": "100000000000000002", "type": 0, "guild_id": "100000000000000006", "name": "general", "nsfw": false, "flags": 0 },
          "context": 0, "locale": "en-US", "app_permissions": "0", "authorizing_integration_owners": { "0": "0" }, "entitlements": [],
          "member": { "user": { "id": "100000000000000003", "username": "tester", "discriminator": "0", "global_name": "Tester", "avatar": null },
                      "roles": [], "joined_at": "2025-01-01T00:00:00+00:00", "deaf": false, "mute": false, "permissions": "0" },
          "data": { "id": "100000000000000004", "name": "{{name}}", "type": 1, "options": {{options}} }
        }
        """;

    private static ulong Snowflake() => (ulong)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 1420070400000L) << 22;

    private async Task<(HttpStatusCode Status, JsonNode? Json)> PostSignedAsync(string body, string endpoint = "/discord/interactions")
    {
        using var request = Request(body, endpoint: endpoint);
        using var response = await app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        return (response.StatusCode, text.Length > 0 ? JsonNode.Parse(text) : null);
    }

    private HttpRequestMessage Request(string body, string? signature = null, string endpoint = "/discord/interactions",
        string? timestamp = null)
    {
        timestamp ??= DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
        signature ??= Sign(timestamp + body);
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        request.Headers.Add("X-Signature-Ed25519", signature);
        request.Headers.Add("X-Signature-Timestamp", timestamp);
        return request;
    }

    private string Sign(string message)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, app.PrivateKey);
        var bytes = Encoding.UTF8.GetBytes(message);
        signer.BlockUpdate(bytes, 0, bytes.Length);
        return Convert.ToHexStringLower(signer.GenerateSignature());
    }
}
```

Cases to cover with the same helpers: PING → `{"type":1}`; bad signature, missing headers and malformed hex →
401 (never 500); stale timestamp with a valid signature → 401; V2 reply (type 4, flag `1 << 15`, first
component type 17); modal (type 9, every top-level component a Label, type 18); slow command → type 5 within
2 s; stale button from an old deploy → ephemeral error within 2 s; page button → type 6; unsupported type
(`PRIMARY_ENTRY_POINT`) → 400; body over 1 MiB → 413, also without Content-Length (call
`DiscordSignedRequest.ReadBodyAsync` on a `DefaultHttpContext` whose body is a `MemoryStream`); Webhook Events
PING → 204 with Content-Type, the same event twice → stored once (`app.Inbox.Events`, or the real EF inbox
under Testcontainers), unexpected JSON → 204, bad signature → 401, a signed PING in an app that registers no `DiscordRestClient` (gateway mode) → 204; a signed body that isn't JSON on the
interactions endpoint → 400.

Payload notes: interaction ids must be **current snowflakes** (`(unixMs - 1420070400000) << 22`) — Discord.Net
derives `CreatedAt` from them and refuses to respond to "old" interactions (3 s check) unless
`UseInteractionSnowflakeDate = false`. Mirror real payloads: Discord always sends the partial `channel` object
(Discord.Net reads `ChannelId` only from it, not from `channel_id`) — a *partial* channel (`id`, `type`,
`guild_id`, `name`, `nsfw`, `flags`); Discord doesn't send `permission_overwrites` or `position` there. Guild
interactions carry `member` + `guild_id`; DM interactions carry `user` and need a **logged-in** client
(Discord.Net reads `CurrentUser`), so offline tests use guild payloads. Assert timing (`< 2 s`) on error paths —
a correct JSON answer that arrives after 3 s is still a failure. The fixture (and its inbox) is shared by every
test in the class: assert the delta, never Single() on shared state.

## Account linking

Run the real flow against the BFF's own `Program`: the session comes from `dotnet-testing`'s header-driven
`TestAuthHandler` (default authenticate + challenge scheme), discord.com is a stub `HttpMessageHandler`
answering `/api/oauth2/token` and `/api/v10/users/@me`, and the client is the cookie-BFF client
(`https://localhost`, `AllowAutoRedirect = false`) so `__Host-external`, the correlation cookie and `XSRF-TOKEN`
round-trip for real.

```csharp
// excerpt — DiscordLinkTests.cs (fixture: WebApplicationFactory<Program>, ConfigureWebHost)
builder.UseSetting("Discord:ClientId", "100000000000000001");
builder.UseSetting("Discord:ClientSecret", "test-secret");
builder.ConfigureTestServices(services =>
{
    services.AddAuthentication(o => { o.DefaultAuthenticateScheme = "Test"; o.DefaultChallengeScheme = "Test"; })
        .AddScheme<AuthenticationSchemeOptions, TestAuthHandler>("Test", _ => { }); // X-Test-User → signed in
    services.Configure<OAuthOptions>(DiscordLink.Scheme, o => o.BackchannelHttpHandler = new FakeDiscordApi());
    services.RemoveAll<IDiscordLinkStore>();
    services.AddSingleton<IDiscordLinkStore>(Links);   // fake with unique-index semantics per Discord id
});

// start → 302 to discord.com → callback with that `state`: leaves the real External cookie in the client
public static async Task StartLinkAsync(HttpClient client, CancellationToken ct)
{
    using var start = await client.GetAsync("/api/account/discord/start", ct);
    var state = HttpUtility.ParseQueryString(start.Headers.Location!.Query)["state"]!;
    using var callback = await client.GetAsync(
        $"/api/auth/callback/discord-link?code=test-code&state={Uri.EscapeDataString(state)}", ct);
    Assert.Equal("/account/discord/confirm", callback.Headers.Location!.OriginalString);
}

[Fact]
public async Task Confirm_links_and_clears_the_external_cookie()
{
    var user = Guid.NewGuid().ToString("N");
    var client = app.Client(user);                    // https base address + X-Test-User
    await StartLinkAsync(client, Ct);
    await AddXsrfHeaderAsync(client, Ct);              // any /api GET mints XSRF-TOKEN → X-XSRF-TOKEN

    using var confirm = await client.PostAsync("/api/account/discord/confirm", null, Ct);

    Assert.Equal(HttpStatusCode.NoContent, confirm.StatusCode);
    Assert.Equal(user, app.Links.UserByDiscordId[FakeDiscordApi.DiscordUserId]);
    Assert.Contains(confirm.Headers.GetValues("Set-Cookie"),
        c => c.StartsWith("__Host-external=;", StringComparison.Ordinal) && c.Contains("expires=Thu, 01 Jan 1970"));
}
```

Cases: start without a session → 401; `/pending` → 404 when another user's session reads the External cookie,
when the ticket has no `link:user`, when it was issued by **another scheme** (a GitHub link or
bff-security's external login sharing the cookie), and without an External cookie; confirm without
`X-XSRF-TOKEN` → 400; confirm when the Discord id belongs to another user → 409; `/pending` after a confirm →
404 (one-shot); six link calls in a row → none 429 (the `/api/auth` 5/min budget is untouched). Tickets the OAuth
handler can't produce (other scheme, no `link:user`) come from a test-only `IStartupFilter` middleware that
calls `SignInAsync(ExternalScheme.Name, …)` with hand-set `Items` — via `app.Use` + a path check, not
`app.Map`: `Map` moves the path into `PathBase` and the cookie gets `path=/test/…`.

## Publishers, error replies, lifecycle

```csharp
// excerpt — AnnouncementPublisherTests.cs
[Fact]
public async Task Publishes_components_v2_card_without_mentions_to_configured_channel()
{
    var message = Substitute.For<IUserMessage>();
    message.Id.Returns(42UL);
    var channel = Substitute.For<ITextChannel>();
    channel.SendMessageAsync(Arg.Any<string>(), Arg.Any<bool>(), Arg.Any<Embed>(), Arg.Any<RequestOptions>(),
            Arg.Any<AllowedMentions>(), Arg.Any<MessageReference>(), Arg.Any<MessageComponent>(), Arg.Any<ISticker[]>(),
            Arg.Any<Embed[]>(), Arg.Any<MessageFlags>(), Arg.Any<PollProperties>())
        .Returns(message);
    var discord = Substitute.For<IDiscordClient>();
    discord.GetChannelAsync(1234UL, CacheMode.AllowDownload, Arg.Any<RequestOptions>()).Returns(channel);
    var publisher = new AnnouncementPublisher(new AnnouncementQueue(), discord,
        Options.Create(new DiscordOptions { AnnouncementChannelId = 1234 }), NullLogger<AnnouncementPublisher>.Instance);

    Assert.Equal(42UL, await publisher.PublishAsync(1234, new Announcement(Guid.NewGuid(), "Hello", "World"),
        TestContext.Current.CancellationToken));
    await channel.Received(1).SendMessageAsync(
        Arg.Any<string>(), Arg.Any<bool>(), Arg.Any<Embed>(), Arg.Any<RequestOptions>(),
        Arg.Is<AllowedMentions>(m => m == AllowedMentions.None),
        Arg.Any<MessageReference>(), Arg.Is<MessageComponent>(c => c.Components.Single().Type == ComponentType.Container),
        Arg.Any<ISticker[]>(), Arg.Any<Embed[]>(), MessageFlags.ComponentsV2, Arg.Any<PollProperties>());
}
```

Further cases: a non-message channel (`ICategoryChannel`) → clear `InvalidOperationException`; a webhook client
factory that throws twice → two construction attempts (a cached `Lazy<Task<T>>` would fail forever after the
first); 101 enqueues → the last `TryEnqueue` returns false. `InteractionErrors`: not yet responded → ephemeral
`RespondAsync`; HTTP mode → the callback, never `RespondAsync`; public deferral (`MessageFlags.Loading`) →
`DeleteOriginalResponseAsync` + ephemeral follow-up; ephemeral deferral → `ModifyOriginalResponseAsync` in
place; already answered → ephemeral follow-up only. `DiscordGatewayService.IsFatal`: 4004/4006/4013/4014 (also
wrapped as inner exception) fatal; 1001, 4000 and 4009 (resumable) and a plain `TimeoutException` not.

Mocking notes: NSubstitute needs *all* optional parameters spelled out with `Arg.Any<T>()` for Discord.Net's
long signatures. `IVoiceChannel` **is** an `IMessageChannel` (text-in-voice) — use `ICategoryChannel` for a
non-message channel. `AllowedMentions.None` is a singleton; compare by reference.

What not to do: mocking `DiscordSocketClient` (sealed-ish concrete type, events), asserting on log output
instead of behaviour, or running tests against a production application/guild.
