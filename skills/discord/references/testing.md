# Testing Discord integrations

General test conventions (xUnit v3 on MTP, NSubstitute, WebApplicationFactory, Testcontainers) live in
`noobit:dotnet-testing`; this file covers the Discord-specific seams. You can't (and shouldn't) hit the real
gateway in CI. Test at four seams — together they caught every real
bug found while building and reviewing this skill's reference code (invalid optional checkbox, PING parsing,
mock channel types, bad-token reconnect loop, a 5 s stall on unknown commands in HTTP mode, DM parsing on an
anonymous client, the broken premium-button helper, a webhook client whose failed construction was cached
forever, an order-dependent inbox assertion). What they can't catch — behaviour that needs a real
connection (e.g. the token check succeeding with a *valid* token) — goes into the manual dev-app smoke run.

| Seam | What it proves | Tooling |
|---|---|---|
| Pure card builders | Layout, limits (40 components, 100-char ids, 25 items), pagination edges | xUnit, no mocks |
| Routing contract | Modules build (attributes valid, DI resolvable), every custom id the cards emit hits a handler, permissions/contexts as intended | Real `InteractionService` with an unconnected client + NSubstitute for interaction data |
| HTTP endpoint end-to-end | Signature handling, PING, response JSON for commands/modals/defer/errors | `WebApplicationFactory` + real Ed25519 key pair (BouncyCastle) + raw Discord v10 payloads |
| Publishers / app services | Right channel, flags, mentions, error handling | NSubstitute on `IDiscordClient`, `ITextChannel`, `IUserMessage` |

Plus one manual smoke run against a development application/guild before release (commands appear,
buttons route, modals submit) — the only thing tests can't prove is Discord's acceptance of a payload.

Project setup (xUnit v3 on Microsoft.Testing.Platform — `global.json` needs
`{ "test": { "runner": "Microsoft.Testing.Platform" } }`):

```xml
<PackageReference Include="xunit.v3" />
<PackageReference Include="NSubstitute" />
<PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" />
<PackageReference Include="BouncyCastle.Cryptography" />  <!-- test-only: sign payloads like Discord does -->

<!-- xunit.v3 adds no global using: without this every [Fact]/Assert is CS0246 -->
<Using Include="Xunit" />
```

## Helper

`ComponentTree.cs`

```csharp
using Discord;

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

## Card tests

`CardTests.cs`

```csharp
using Discord;
using MyApp.Discord.Announcements;
using MyApp.Discord.Cards;
using MyApp.Discord.Search;

namespace MyApp.Discord.Tests;

public sealed class CardTests
{
    private static readonly IReadOnlyList<DocHit> TwelveHits =
        Enumerable.Range(1, 12).Select(i => new DocHit($"Doc {i}", $"https://example.com/{i}", "snippet")).ToArray();

    [Fact]
    public void About_card_is_a_single_accented_container_within_discord_limits()
    {
        var card = AboutCard.Build("MyApp", "1.0.0", "https://example.com/icon.png", "https://example.com");

        var container = Assert.IsType<ContainerComponent>(Assert.Single(card.Components));
        Assert.Equal(Brand.Accent, container.AccentColor);
        Assert.True(ComponentTree.Flatten(card).Count() <= 40, "Discord allows at most 40 components per V2 message");
        Assert.Contains(ComponentTree.Flatten(card).OfType<ButtonComponent>(), b => b.Style == ButtonStyle.Link);
    }

    [Fact]
    public void Search_card_first_page_disables_prev_and_links_next_page()
    {
        var card = SearchCard.Build("doc", TwelveHits, page: 0);
        var buttons = ComponentTree.Flatten(card).OfType<ButtonComponent>().Where(b => b.Style != ButtonStyle.Link).ToList();

        Assert.True(buttons[0].IsDisabled);                                  // ◀ Prev
        Assert.Equal("1 / 3", buttons[1].Label);
        Assert.Equal(CustomIds.SearchPage(1, "doc"), buttons[2].CustomId);   // Next ▶
        Assert.False(buttons[2].IsDisabled);
        Assert.Equal(SearchCard.PageSize, ComponentTree.Flatten(card).OfType<SectionComponent>().Count());
    }

    [Fact]
    public void Search_card_clamps_out_of_range_page_and_disables_next_on_last_page()
    {
        var card = SearchCard.Build("doc", TwelveHits, page: 99);
        var next = ComponentTree.Flatten(card).OfType<ButtonComponent>().Last();

        Assert.True(next.IsDisabled);
        Assert.Equal(2, ComponentTree.Flatten(card).OfType<SectionComponent>().Count()); // 12 hits → last page has 2
    }

    [Fact]
    public void Search_card_without_hits_has_no_pagination()
    {
        var card = SearchCard.Build("nothing", [], page: 0);
        Assert.DoesNotContain(ComponentTree.Flatten(card), c => c is ButtonComponent);
    }

    [Fact]
    public void Custom_ids_stay_within_100_chars_for_the_longest_allowed_query()
    {
        var longest = new string('x', 80); // [MaxLength(80)] on the query option
        Assert.True(CustomIds.SearchPage(999, longest).Length <= CustomIds.MaxLength);
        Assert.Throws<ArgumentException>(() => CustomIds.SearchPage(1, new string('x', 100)));
    }

    [Fact]
    public void Announcement_card_has_ack_button_and_optional_link()
    {
        var a = new Announcement(Guid.NewGuid(), "Release 2.0", "It's out!", LinkUrl: "https://example.com/2.0");
        var buttons = ComponentTree.Flatten(AnnouncementCard.Build(a)).OfType<ButtonComponent>().ToList();

        Assert.Contains(buttons, b => b.CustomId == CustomIds.AnnouncementAck(a.Id));
        Assert.Contains(buttons, b => b.Url == "https://example.com/2.0");
    }

    [Fact]
    public void Static_announcement_card_has_only_link_buttons_for_unowned_webhooks()
    {
        var a = new Announcement(Guid.NewGuid(), "Release 2.0", "It's out!", LinkUrl: "https://example.com/2.0");
        var buttons = ComponentTree.Flatten(AnnouncementCard.BuildStatic(a)).OfType<ButtonComponent>().ToList();

        Assert.All(buttons, b => Assert.Equal(ButtonStyle.Link, b.Style));
    }

    [Fact]
    public void Premium_button_must_be_built_with_premium_style_and_sku_only()
    {
        const ulong sku = 1234567890123456789;
        var ok = new ComponentBuilderV2().WithActionRow([new ButtonBuilder(style: ButtonStyle.Premium, skuId: sku)]).Build();
        Assert.Equal(sku, ComponentTree.Flatten(ok).OfType<ButtonComponent>().Single().SkuId);

        // Characterization of a Discord.Net 3.20.1 bug: the helper creates a Success-style button without custom id.
        Assert.Throws<InvalidOperationException>(() =>
            new ComponentBuilderV2().WithActionRow([ButtonBuilder.CreatePremiumButton("Upgrade", sku)]).Build());
    }

    [Fact]
    public void Truncation_never_splits_an_emoji()
    {
        var query = new string('a', 78) + "😀😀"; // surrogate pair straddles the 80-char cut
        var card = SearchCard.Build(query, [], page: 0);
        var text = ComponentTree.Flatten(card).OfType<TextDisplayComponent>().First().Content;

        for (var i = 0; i < text.Length; i++)
        {
            if (char.IsHighSurrogate(text[i]))
            {
                Assert.True(i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]), "lone high surrogate");
            }
        }
    }
}
```

## Routing contract tests

`RoutingTests.cs`

```csharp
using Discord;
using Discord.Interactions;
using Discord.Rest;
using Discord.WebSocket;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using MyApp.Discord.Cards;
using MyApp.Discord.Search;
using NSubstitute;

namespace MyApp.Discord.Tests;

/// <summary>
/// Contract tests: modules build (attributes valid, dependencies resolvable) and every custom id the cards emit
/// routes to a handler. No Discord connection needed — clients are constructed but never logged in.
/// </summary>
public sealed class RoutingTests
{
    private static ServiceProvider Services() => new ServiceCollection()
        .AddSingleton<IDocsSearch, InMemoryDocsSearch>()
        .AddSingleton(typeof(ILogger<>), typeof(NullLogger<>))
        .AddSingleton<MyApp.Discord.Announcements.IAnnouncementQueue, MyApp.Discord.Announcements.AnnouncementQueue>()
        .BuildServiceProvider();

    private static async Task<InteractionService> GatewayInteractions()
    {
        var service = new InteractionService(new DiscordSocketClient());
        await service.AddModulesAsync(typeof(MyApp.Bot.DiscordGatewayService).Assembly, Services());
        return service;
    }

    private static async Task<InteractionService> HttpInteractions()
    {
        var service = new InteractionService(new DiscordRestClient());
        await service.AddModulesAsync(typeof(MyApp.Interactions.DiscordHttpStartup).Assembly, Services());
        return service;
    }

    [Fact]
    public async Task Gateway_modules_expose_expected_commands()
    {
        var interactions = await GatewayInteractions();

        Assert.Equivalent(new[] { "about", "search", "feedback", "announce", "embed", "poll", "settings", "pro", "emojis" },
            interactions.SlashCommands.Select(c => c.Name).ToArray());
        Assert.Contains(interactions.ContextCommands, c => c.Name == "Show profile");
        Assert.Contains(interactions.ModalCommands, c => c.Name == CustomIds.FeedbackModal);
    }

    [Theory]
    [InlineData("search:page:1:intents")]
    [InlineData("search:page:12:with:colons")]
    [InlineData("announce:ack:0f8fad5bd9cb469fa165708355c3b5e7")]
    [InlineData("demo:theme")]
    [InlineData("demo:logchannel")]
    public async Task Gateway_custom_ids_route_to_a_component_handler(string customId)
    {
        var interactions = await GatewayInteractions();
        Assert.True(interactions.SearchComponentCommand(ComponentInteraction(customId)).IsSuccess, customId);
    }

    [Fact]
    public async Task Card_custom_ids_route_in_both_hosting_modes()
    {
        var gateway = await GatewayInteractions();
        var http = await HttpInteractions();
        var id = CustomIds.SearchPage(2, "gateway intents");

        Assert.True(gateway.SearchComponentCommand(ComponentInteraction(id)).IsSuccess);
        Assert.True(http.SearchComponentCommand(ComponentInteraction(id)).IsSuccess);
    }

    [Fact]
    public async Task Announce_command_requires_manage_guild_and_is_guild_only()
    {
        var announce = (await GatewayInteractions()).SlashCommands.Single(c => c.Name == "announce");

        Assert.Equal(GuildPermission.ManageGuild, announce.DefaultMemberPermissions);
        Assert.Equal([InteractionContextType.Guild], announce.ContextTypes);
    }

    private static IComponentInteraction ComponentInteraction(string customId)
    {
        var data = Substitute.For<IComponentInteractionData>();
        data.CustomId.Returns(customId);
        var interaction = Substitute.For<IComponentInteraction>();
        interaction.Data.Returns(data);
        return interaction;
    }
}
```

## HTTP endpoint end-to-end tests

`HttpInteractionsEndpointTests.cs`

```csharp
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Security;

namespace MyApp.Discord.Tests;

/// <summary>
/// End-to-end over HTTP exactly as Discord calls the endpoint: real Ed25519 signatures with a test key pair,
/// raw JSON payloads in Discord's v10 shape, assertions on the interaction-response JSON.
/// </summary>
public sealed class HttpInteractionsEndpointTests : IClassFixture<HttpInteractionsEndpointTests.App>
{
    private const string Endpoint = "/discord/interactions";
    private readonly App _app;

    public HttpInteractionsEndpointTests(App app) => _app = app;

    public sealed class App : WebApplicationFactory<Program>
    {
        public Ed25519PrivateKeyParameters PrivateKey { get; }
        public string PublicKeyHex { get; }

        public App()
        {
            var generator = new Ed25519KeyPairGenerator();
            generator.Init(new Ed25519KeyGenerationParameters(new SecureRandom()));
            var pair = generator.GenerateKeyPair();
            PrivateKey = (Ed25519PrivateKeyParameters)pair.Private;
            PublicKeyHex = Convert.ToHexStringLower(((Ed25519PublicKeyParameters)pair.Public).GetEncoded());
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder) =>
            builder.UseSetting("Discord:PublicKey", PublicKeyHex); // no token: no login, no registration
    }

    [Fact]
    public async Task Ping_is_acknowledged_with_pong()
    {
        var (status, json) = await PostSignedAsync("""{"type":1,"id":"1","application_id":"2","token":"t","version":1}""");

        Assert.Equal(HttpStatusCode.OK, status);
        Assert.Equal(1, json!["type"]!.GetValue<int>());
    }

    [Fact]
    public async Task Invalid_signature_is_rejected_with_401()
    {
        using var request = Request("""{"type":1}""", signature: new string('0', 128));
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Missing_or_malformed_signature_headers_are_401_not_500()
    {
        var client = _app.CreateClient();
        var noHeaders = await client.PostAsync(Endpoint, new StringContent("{}"), TestContext.Current.CancellationToken);
        using var badHex = Request("{}", signature: new string('z', 128));
        var malformed = await client.SendAsync(badHex, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, noHeaders.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, malformed.StatusCode);
    }

    [Fact]
    public async Task About_responds_with_components_v2_message()
    {
        var (status, json) = await PostSignedAsync(SlashCommand("about"));

        Assert.Equal(HttpStatusCode.OK, status);
        Assert.Equal(4, json!["type"]!.GetValue<int>());                          // CHANNEL_MESSAGE_WITH_SOURCE
        Assert.Equal(1 << 15, json["data"]!["flags"]!.GetValue<int>() & (1 << 15)); // IS_COMPONENTS_V2
        Assert.Equal(17, json["data"]!["components"]![0]!["type"]!.GetValue<int>()); // Container
    }

    [Fact]
    public async Task Feedback_opens_a_modal_built_from_labels()
    {
        var (_, json) = await PostSignedAsync(SlashCommand("feedback"));

        Assert.Equal(9, json!["type"]!.GetValue<int>()); // MODAL
        Assert.Equal("feedback:submit", json["data"]!["custom_id"]!.GetValue<string>());
        var types = json["data"]!["components"]!.AsArray().Select(c => c!["type"]!.GetValue<int>());
        Assert.All(types, t => Assert.Equal(18, t)); // every input wrapped in a Label (ActionRow+TextInput is deprecated)
    }

    [Fact]
    public async Task Slow_command_is_deferred_within_budget()
    {
        var started = DateTimeOffset.UtcNow;
        var (_, json) = await PostSignedAsync(SlashCommand("search", """[{"name":"query","type":3,"value":"intents"}]"""));

        Assert.Equal(5, json!["type"]!.GetValue<int>()); // DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task Unknown_command_gets_an_ephemeral_error_within_budget()
    {
        var started = DateTimeOffset.UtcNow;
        var (_, json) = await PostSignedAsync(SlashCommand("does-not-exist"));

        Assert.Equal(4, json!["type"]!.GetValue<int>());
        Assert.Equal(1 << 6, json["data"]!["flags"]!.GetValue<int>() & (1 << 6)); // EPHEMERAL
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2), "error reply must beat Discord's 3 s deadline");
    }

    [Fact]
    public async Task Stale_button_from_an_old_deploy_gets_an_ephemeral_error_within_budget()
    {
        var started = DateTimeOffset.UtcNow;
        var (_, json) = await PostSignedAsync(ButtonClick("gone:button"));

        Assert.Equal(4, json!["type"]!.GetValue<int>());
        Assert.Equal(1 << 6, json["data"]!["flags"]!.GetValue<int>() & (1 << 6));
        Assert.True(DateTimeOffset.UtcNow - started < TimeSpan.FromSeconds(2));
    }

    [Fact]
    public async Task Search_page_button_is_acknowledged_as_deferred_update()
    {
        var (_, json) = await PostSignedAsync(ButtonClick(MyApp.Discord.Cards.CustomIds.SearchPage(1, "start")));

        Assert.Equal(6, json!["type"]!.GetValue<int>()); // DEFERRED_UPDATE_MESSAGE
    }

    [Fact]
    public async Task Unsupported_interaction_type_is_400_not_500()
    {
        var entryPoint = SlashCommand("launch").Replace("\"type\": 1, \"options\"", "\"type\": 4, \"options\"");
        using var request = Request(entryPoint);
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Oversized_body_is_rejected_before_buffering()
    {
        using var request = Request(new string(' ', 1024 * 1024 + 1));
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task Stale_timestamp_is_rejected_even_with_a_valid_signature()
    {
        var old = DateTimeOffset.UtcNow.AddMinutes(-10).ToUnixTimeSeconds().ToString();
        using var request = Request("""{"type":1}""", timestamp: old); // correctly signed, but a replay
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Body_limit_holds_without_content_length()
    {
        var http = new DefaultHttpContext();
        http.Request.Body = new MemoryStream(new byte[1024 * 1024 + 1]); // chunked-style: ContentLength is null

        Assert.Null(await MyApp.Interactions.DiscordSignedRequest.ReadBodyAsync(http.Request, 1024 * 1024,
            TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Webhook_event_ping_is_204_and_events_are_stored_once()
    {
        var client = _app.CreateClient();
        var inbox = (MyApp.Interactions.InMemoryWebhookEventInbox)_app.Services.GetRequiredService<MyApp.Interactions.IWebhookEventInbox>();
        var before = inbox.Events.Count; // the fixture (and its inbox) is shared by every test in this class
        const string evt = """
            {"version":1,"application_id":"1","type":1,"event":{"type":"APPLICATION_AUTHORIZED","timestamp":"2026-10-02T10:00:00Z",
             "data":{"integration_type":1,"scopes":["applications.commands"],"user":{"id":"3","username":"u"}}}}
            """;

        using var ping = Request("""{"version":1,"application_id":"1","type":0}""", endpoint: "/discord/events");
        var pong = await client.SendAsync(ping, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.NoContent, pong.StatusCode);
        Assert.Equal("application/json", pong.Content.Headers.ContentType?.MediaType); // Discord requires a Content-Type

        for (var attempt = 0; attempt < 2; attempt++) // Discord retries deliveries — the second one must be a no-op
        {
            using var request = Request(evt, endpoint: "/discord/events");
            var response = await client.SendAsync(request, TestContext.Current.CancellationToken);
            Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        }

        Assert.Equal(before + 1, inbox.Events.Count); // assert the delta, never Single() on shared state
    }

    [Fact]
    public async Task Webhook_event_with_unexpected_json_is_still_stored_and_acknowledged()
    {
        using var request = Request("""{"version":1,"type":1,"event":"not-an-object"}""", endpoint: "/discord/events");
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode); // never 500 → no retry storm
    }

    [Fact]
    public async Task Webhook_event_with_bad_signature_is_401()
    {
        using var request = Request("""{"type":0}""", signature: new string('0', 128), endpoint: "/discord/events");
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    private static string SlashCommand(string name, string options = "[]") => $$"""
        {
          "type": 2, "id": "{{Snowflake()}}", "application_id": "100000000000000001", "token": "test-token", "version": 1,
          "channel_id": "100000000000000002", "guild_id": "100000000000000006", "channel": { "id": "100000000000000002", "type": 0, "guild_id": "100000000000000006", "name": "general", "nsfw": false, "flags": 0 }, "context": 0, "locale": "en-US", "app_permissions": "0",
          "authorizing_integration_owners": { "0": "0" }, "entitlements": [],
          "member": { "user": { "id": "100000000000000003", "username": "tester", "discriminator": "0", "global_name": "Tester", "avatar": null },
                      "roles": [], "joined_at": "2025-01-01T00:00:00+00:00", "deaf": false, "mute": false, "permissions": "0" },
          "data": { "id": "100000000000000004", "name": "{{name}}", "type": 1, "options": {{options}} }
        }
        """;

    private static string ButtonClick(string customId) => $$"""
        {
          "type": 3, "id": "{{Snowflake()}}", "application_id": "100000000000000001", "token": "test-token", "version": 1,
          "channel_id": "100000000000000002", "guild_id": "100000000000000006", "channel": { "id": "100000000000000002", "type": 0, "guild_id": "100000000000000006", "name": "general", "nsfw": false, "flags": 0 }, "context": 0, "locale": "en-US", "app_permissions": "0",
          "authorizing_integration_owners": { "0": "0" }, "entitlements": [],
          "member": { "user": { "id": "100000000000000003", "username": "tester", "discriminator": "0", "global_name": "Tester", "avatar": null },
                      "roles": [], "joined_at": "2025-01-01T00:00:00+00:00", "deaf": false, "mute": false, "permissions": "0" },
          "message": { "id": "100000000000000005", "channel_id": "100000000000000002", "type": 0, "content": "", "flags": 32768,
                       "author": { "id": "100000000000000001", "username": "bot", "discriminator": "0", "avatar": null },
                       "timestamp": "2026-10-02T10:00:00+00:00", "edited_timestamp": null, "tts": false, "mention_everyone": false,
                       "mentions": [], "mention_roles": [], "attachments": [], "embeds": [], "pinned": false, "components": [] },
          "data": { "custom_id": "{{customId}}", "component_type": 2 }
        }
        """;

    private static ulong Snowflake() => (ulong)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - 1420070400000L) << 22;

    private async Task<(HttpStatusCode Status, JsonNode? Json)> PostSignedAsync(string body)
    {
        using var request = Request(body);
        var response = await _app.CreateClient().SendAsync(request, TestContext.Current.CancellationToken);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        return (response.StatusCode, text.Length > 0 ? JsonNode.Parse(text) : null);
    }

    private HttpRequestMessage Request(string body, string? signature = null, string endpoint = Endpoint, string? timestamp = null)
    {
        timestamp ??= DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
        signature ??= Sign(timestamp + body);
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
        request.Headers.Add("X-Signature-Ed25519", signature);
        request.Headers.Add("X-Signature-Timestamp", timestamp);
        return request;
    }

    private string Sign(string message)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, _app.PrivateKey);
        var bytes = Encoding.UTF8.GetBytes(message);
        signer.BlockUpdate(bytes, 0, bytes.Length);
        return Convert.ToHexStringLower(signer.GenerateSignature());
    }
}
```

Payload notes: interaction ids must be **current snowflakes** (`(unixMs - 1420070400000) << 22`) — Discord.Net
derives `CreatedAt` from them and refuses to respond to "old" interactions (3 s check) unless
`UseInteractionSnowflakeDate = false`. Mirror real payloads: Discord always sends the partial `channel` object
(Discord.Net reads `ChannelId` only from it, not from `channel_id`) — a *partial* channel (`id`, `type`,
`guild_id`, `name`, `nsfw`, `flags`); Discord doesn't send `permission_overwrites` or `position` there. Guild interactions carry `member` + `guild_id`; DM interactions carry `user` and need a
**logged-in** client (Discord.Net reads `CurrentUser`), so offline tests use guild payloads. Assert timing
(`< 2 s`) on error paths — a correct JSON answer that arrives after 3 s is still a failure.

## Publisher tests

`AnnouncementPublisherTests.cs`

```csharp
using Discord;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using MyApp.Discord.Announcements;
using NSubstitute;

namespace MyApp.Discord.Tests;

public sealed class AnnouncementPublisherTests
{
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

        var id = await publisher.PublishAsync(1234, new Announcement(Guid.NewGuid(), "Hello", "World"), TestContext.Current.CancellationToken);

        Assert.Equal(42UL, id);
        await channel.Received(1).SendMessageAsync(
            Arg.Any<string>(), Arg.Any<bool>(), Arg.Any<Embed>(), Arg.Any<RequestOptions>(),
            Arg.Is<AllowedMentions>(m => m == AllowedMentions.None),
            Arg.Any<MessageReference>(), Arg.Is<MessageComponent>(c => c.Components.Single().Type == ComponentType.Container),
            Arg.Any<ISticker[]>(), Arg.Any<Embed[]>(), MessageFlags.ComponentsV2, Arg.Any<PollProperties>());
    }

    [Fact]
    public async Task Non_message_channel_is_a_clear_error()
    {
        var discord = Substitute.For<IDiscordClient>();
        discord.GetChannelAsync(Arg.Any<ulong>(), Arg.Any<CacheMode>(), Arg.Any<RequestOptions>())
            .Returns(Substitute.For<ICategoryChannel>());
        var publisher = new AnnouncementPublisher(new AnnouncementQueue(), discord,
            Options.Create(new DiscordOptions()), NullLogger<AnnouncementPublisher>.Instance);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            publisher.PublishAsync(1, new Announcement(Guid.NewGuid(), "t", "b"), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task Failed_webhook_client_construction_is_retried_on_the_next_post()
    {
        var attempts = 0;
        await using var announcer = new WebhookAnnouncer(() =>
        {
            attempts++;
            throw new HttpRequestException("Discord unavailable"); // what the blocking constructor throws in an outage
        });
        var announcement = new Announcement(Guid.NewGuid(), "t", "b");

        await Assert.ThrowsAsync<HttpRequestException>(() => announcer.PostAsync(announcement, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<HttpRequestException>(() => announcer.PostAsync(announcement, TestContext.Current.CancellationToken));
        Assert.Equal(2, attempts); // a cached Lazy<Task<T>> would fail forever after the first attempt
    }

    [Fact]
    public void Queue_reports_full_instead_of_dropping_silently()
    {
        var queue = new AnnouncementQueue();
        var results = Enumerable.Range(0, 101).Select(_ => queue.TryEnqueue(new Announcement(Guid.NewGuid(), "t", "b"))).ToList();

        Assert.All(results.Take(100), Assert.True);
        Assert.False(results[100]);
    }
}
```

Mocking notes: NSubstitute needs *all* optional parameters spelled out with `Arg.Any<T>()` for Discord.Net's
long signatures. `IVoiceChannel` **is** an `IMessageChannel` (text-in-voice) — use `ICategoryChannel` for a
non-message channel. `AllowedMentions.None` is a singleton; compare by reference.

## Error reply tests

`InteractionErrorsTests.cs`

```csharp
using Discord;
using NSubstitute;

namespace MyApp.Discord.Tests;

public sealed class InteractionErrorsTests
{
    [Fact]
    public async Task Not_yet_responded_answers_ephemerally()
    {
        var interaction = Substitute.For<IDiscordInteraction>();

        await InteractionErrors.ReplyAsync(interaction, "boom");

        await interaction.Received(1).RespondAsync("boom", Arg.Any<Embed[]>(), Arg.Any<bool>(), true,
            Arg.Any<AllowedMentions>(), Arg.Any<MessageComponent>(), Arg.Any<Embed>(), Arg.Any<RequestOptions>(),
            Arg.Any<PollProperties>(), Arg.Any<MessageFlags>());
    }

    [Fact]
    public async Task Http_mode_uses_the_initial_response_callback()
    {
        var interaction = Substitute.For<IDiscordInteraction>();
        string? sent = null;

        await InteractionErrors.ReplyAsync(interaction, "boom", (_, text) => { sent = text; return Task.CompletedTask; });

        Assert.Equal("boom", sent);
        await interaction.DidNotReceiveWithAnyArgs().RespondAsync();
    }

    [Fact]
    public async Task Public_deferral_is_deleted_and_error_sent_privately()
    {
        var interaction = Deferred(MessageFlags.Loading);

        await InteractionErrors.ReplyAsync(interaction, "boom");

        await interaction.Received(1).DeleteOriginalResponseAsync(Arg.Any<RequestOptions>());
        await ReceivedEphemeralFollowup(interaction);
    }

    [Fact]
    public async Task Ephemeral_deferral_is_edited_in_place()
    {
        var interaction = Deferred(MessageFlags.Loading | MessageFlags.Ephemeral);

        await InteractionErrors.ReplyAsync(interaction, "boom");

        await interaction.Received(1).ModifyOriginalResponseAsync(Arg.Any<Action<MessageProperties>>(), Arg.Any<RequestOptions>());
        await interaction.DidNotReceiveWithAnyArgs().DeleteOriginalResponseAsync();
    }

    [Fact]
    public async Task Already_answered_gets_an_ephemeral_followup()
    {
        var interaction = Deferred(MessageFlags.None); // real response already sent, e.g. a card

        await InteractionErrors.ReplyAsync(interaction, "boom");

        await interaction.DidNotReceiveWithAnyArgs().DeleteOriginalResponseAsync();
        await ReceivedEphemeralFollowup(interaction);
    }

    private static IDiscordInteraction Deferred(MessageFlags originalFlags)
    {
        var original = Substitute.For<IUserMessage>();
        original.Flags.Returns(originalFlags);
        var interaction = Substitute.For<IDiscordInteraction>();
        interaction.HasResponded.Returns(true);
        interaction.GetOriginalResponseAsync(Arg.Any<RequestOptions>()).Returns(original);
        return interaction;
    }

    private static Task<IUserMessage> ReceivedEphemeralFollowup(IDiscordInteraction interaction) =>
        interaction.Received(1).FollowupAsync("boom", Arg.Any<Embed[]>(), Arg.Any<bool>(), true,
            Arg.Any<AllowedMentions>(), Arg.Any<MessageComponent>(), Arg.Any<Embed>(), Arg.Any<RequestOptions>(),
            Arg.Any<PollProperties>(), Arg.Any<MessageFlags>());
}
```

## Gateway lifecycle tests

`GatewayLifecycleTests.cs`

```csharp
using Discord.Net;
using MyApp.Bot;

namespace MyApp.Discord.Tests;

public sealed class GatewayLifecycleTests
{
    [Theory]
    [InlineData(4004)] // authentication failed (token reset)
    [InlineData(4013)] // invalid intents
    [InlineData(4014)] // disallowed (privileged, not enabled) intents
    public void Non_recoverable_close_codes_are_fatal(int closeCode) =>
        Assert.True(DiscordGatewayService.IsFatal(new Exception("wrapper", new WebSocketClosedException(closeCode))));

    [Theory]
    [InlineData(1001)]
    [InlineData(4000)] // unknown error — resumable
    [InlineData(4009)] // session timed out — resumable
    public void Recoverable_close_codes_are_not_fatal(int closeCode) =>
        Assert.False(DiscordGatewayService.IsFatal(new WebSocketClosedException(closeCode)));

    [Fact]
    public void Plain_network_errors_are_not_fatal() =>
        Assert.False(DiscordGatewayService.IsFatal(new TimeoutException()));
}
```

What not to do: mocking `DiscordSocketClient` (sealed-ish concrete type, events), asserting on log output
instead of behaviour, or running tests against a production application/guild.
