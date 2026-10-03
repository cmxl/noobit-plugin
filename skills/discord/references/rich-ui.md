# Rich experiences — messages, components, modals

How to make an app feel native in Discord, with verified Discord.Net 3.20.1 code. All builders here are pure
functions in the shared library: unit-testable, reused by gateway and HTTP modules.

Code blocks omit `using` directives (add the System.*, Discord.*, Microsoft.Extensions.* and `MyApp.*` namespaces the
types come from); the file-scoped namespace shows which project a file belongs to.

**Contents:** 1 Design principles · 2 Components V2 cards (about, search results with pagination, announcement) ·
3 Custom ids · 4 Modals · 5 Autocomplete · 6 Context-menu commands & profile card · 7 Embeds, polls, selects,
premium, emojis · 8 Ephemeral vs public, editing, timestamps, mentions · 9 Localization

## 1. Design principles

- **Respond in place.** Prefer editing the message a button sits on (deferred update → edit) over posting new
  messages. Pagination, toggles, "claimed by X" all edit the card.
- **Ephemeral for personal, public for shared.** Settings, errors, confirmations, profile lookups → ephemeral.
  Results others benefit from → public, optionally with a "only show me" boolean option.
- **One card, one container.** A V2 `Container` with an accent colour reads as a unit; use `Section` +
  `Thumbnail` for "avatar + text", a `Separator` before the action row, `-# small text` for metadata.
- **Buttons over instructions.** Next step = a button (or Link button to your web app), not "type /foo".
- **Never block, never go silent.** Defer slow work; every error path answers the user ephemerally.
- **Respect limits in the builder**, not at runtime: truncate text, cap list sizes (25 choices, 25 options,
  40 components, 10 gallery items), assert them in tests.
- **Accessible by default.** Alt text on every Thumbnail and MediaGallery item; never use the accent colour as
  the only status signal — pair it with a word or emoji ("🔴 Down").
- **Mobile-first text.** Sections with long text wrap badly on phones: keep TextDisplays short, put detail behind
  a "Details" button (ephemeral) or a Link button to your web app.
- **Brand assets as application emojis** (Portal → Emojis): custom icons work in every server, DM and user
  install — guild emojis don't.

### Interaction patterns

| Situation | Pattern |
|---|---|
| Several people may click the same button (Claim, Join, Vote) | Conditional update on the entity (`UPDATE … WHERE ClaimedBy IS NULL`); the winner answers with UPDATE_MESSAGE so everyone sees the new state; losers get an ephemeral "Already claimed by @x" |
| Destructive action (Delete, Close, Ban) | Two-step: ephemeral "Are you sure?" with Danger + Cancel buttons; carry the entity id in both custom ids |
| Flow finished (ticket closed, poll ended, wizard done) | Disable or remove the buttons in the final edit so stale clicks can't happen |
| Long-running job | One status card, edited as it progresses (post-then-edit, app-integration.md §2) — not a stream of follow-ups |
| Multi-step input | Button → modal → card with an "Edit" button that re-opens the modal pre-filled |
| Per-user state on a public message | Ephemeral reply to the clicker; never rewrite the shared message per user |

## 2. Components V2 cards

`Brand.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class Brand
{
    public static readonly Color Accent = new(0x58, 0x65, 0xF2), Success = new(0x57, 0xF2, 0x87), Danger = new(0xED, 0x42, 0x45);
}
```

`AboutCard.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class AboutCard
{
    public static MessageComponent Build(string appName, string version, string iconUrl, string websiteUrl) =>
        new ComponentBuilderV2()
            .WithContainer(new ContainerBuilder()
                .WithAccentColor(Brand.Accent)
                .WithSection(new SectionBuilder()
                    .WithTextDisplay($"## {appName}")
                    .WithTextDisplay($"Version `{version}`")
                    .WithAccessory(new ThumbnailBuilder(iconUrl, description: $"{appName} logo")))
                .WithSeparator()
                .WithTextDisplay("Use `/search` to find documentation and `/feedback` to tell us what you think.")
                .WithActionRow([ButtonBuilder.CreateLinkButton("Website", websiteUrl)]))
            .Build();
}
```

Paginated search results — each hit is a Section with a Link-button accessory; the nav row encodes
`page` and `query` in the custom id so the handler is stateless:

`SearchCard.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class SearchCard
{
    public const int PageSize = 5;

    public static MessageComponent Build(string query, IReadOnlyList<DocHit> hits, int page)
    {
        var pageCount = Math.Max(1, (int)Math.Ceiling(hits.Count / (double)PageSize));
        page = Math.Clamp(page, 0, pageCount - 1);

        var container = new ContainerBuilder()
            .WithAccentColor(Brand.Accent)
            .WithTextDisplay($"### Results for “{Truncate(query, 80)}”\n-# {hits.Count} hit(s)");

        if (hits.Count == 0)
        {
            container.WithTextDisplay("Nothing found. Try a shorter query.");
        }

        foreach (var hit in hits.Skip(page * PageSize).Take(PageSize))
        {
            container.WithSection(new SectionBuilder()
                .WithTextDisplay($"**{Truncate(hit.Title, 200)}**\n{Truncate(hit.Snippet, 500)}")
                .WithAccessory(ButtonBuilder.CreateLinkButton("Open", hit.Url)));
        }

        if (pageCount > 1)
        {
            container.WithSeparator()
                .WithActionRow([
                    new ButtonBuilder("◀ Prev", CustomIds.SearchPage(page - 1, query), ButtonStyle.Secondary, isDisabled: page == 0),
                    // a disabled button is the idiomatic "page x / y" indicator; it needs a unique custom id anyway
                    new ButtonBuilder($"{page + 1} / {pageCount}", "search:noop", ButtonStyle.Secondary, isDisabled: true),
                    new ButtonBuilder("Next ▶", CustomIds.SearchPage(page + 1, query), ButtonStyle.Secondary, isDisabled: page >= pageCount - 1),
                ]);
        }

        return new ComponentBuilderV2().WithContainer(container).Build();
    }

    private static string Truncate(string s, int max)
    {
        if (s.Length <= max)
        {
            return s;
        }

        var cut = max - 1;
        if (char.IsHighSurrogate(s[cut - 1]))
        {
            cut--; // don't split an emoji / surrogate pair
        }

        return s[..cut] + "…";
    }
}
```

The handler side is `SearchModule.PageAsync` in [gateway-bot.md](gateway-bot.md) §6 (deferred update → edit).
If the data is already in memory, skip the defer and edit as the response:
`await ((IComponentInteraction)Context.Interaction).UpdateAsync(m => m.Components = …)`.

Announcement card — interactive variant for bot posts, link-only variant for webhooks the app doesn't own:

`AnnouncementCard.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class AnnouncementCard
{
    /// <summary>Interactive variant — posted by the bot, so the "Got it" button routes back to the app.</summary>
    public static MessageComponent Build(Announcement a) => Compose(a, interactive: true);

    /// <summary>Link-only variant for webhooks the application doesn't own (they can't send interactive components).</summary>
    public static MessageComponent BuildStatic(Announcement a) => Compose(a, interactive: false);

    private static MessageComponent Compose(Announcement a, bool interactive)
    {
        var container = new ContainerBuilder()
            .WithAccentColor(Brand.Accent)
            .WithTextDisplay($"## 📣 {a.Title}")
            .WithTextDisplay(a.Body);

        if (a.ImageUrl is not null)
        {
            container.WithMediaGallery(new MediaGalleryBuilder().AddItem(a.ImageUrl, description: a.Title));
        }

        var buttons = new List<IMessageComponentBuilder>();
        if (interactive)
        {
            // Stateless handler + id in the custom_id ⇒ the button keeps working after restarts/deploys.
            buttons.Add(new ButtonBuilder("Got it", CustomIds.AnnouncementAck(a.Id), ButtonStyle.Success));
        }

        if (a.LinkUrl is not null)
        {
            buttons.Add(ButtonBuilder.CreateLinkButton("Read more", a.LinkUrl));
        }

        if (buttons.Count > 0)
        {
            container.WithSeparator().WithActionRow(buttons);
        }

        return new ComponentBuilderV2().WithContainer(container).Build();
    }
}
```

Sending V2:
- Gateway (`SocketInteraction`, channel sends, webhook client): the V2 flag is added automatically when a
  top-level component isn't an action row — passing it explicitly is still clearer.
- HTTP interaction responses and **every edit of a deferred response**: set
  `flags`/`m.Flags = MessageFlags.ComponentsV2` yourself.
- Converting an existing legacy message to V2 on edit: `m.Flags = (msg.Flags ?? MessageFlags.None) | MessageFlags.ComponentsV2`
  and clear `m.Content`/`m.Embeds`. It can't be converted back.
- Images in V2 come from URLs or uploaded attachments referenced as `attachment://file.png`
  (`RespondWithFileAsync` / `SendFileAsync` + `MediaGalleryBuilder().AddItem("attachment://file.png")`).
  Unreferenced attachments are not displayed on V2 messages.

## 3. Custom ids

`CustomIds.cs`

```csharp
namespace MyApp.Discord.Cards;

/// <summary>Single source of truth; handlers bind the same patterns with <c>*</c> wildcards (routing test catches typos).</summary>
public static class CustomIds
{
    public const int MaxLength = 100;

    public const string FeedbackModal = "feedback:submit";

    // [ComponentInteraction("search:page:*:*")] → (int page, string query)
    public const string SearchPagePattern = "search:page:*:*";
    public static string SearchPage(int page, string query) => Checked($"search:page:{page}:{query}");

    // [ComponentInteraction("announce:ack:*")] → (string announcementId) — wildcard binding supports IConvertible types, not Guid
    public const string AnnouncementAckPattern = "announce:ack:*";
    public static string AnnouncementAck(Guid id) => Checked($"announce:ack:{id:N}");

    private static string Checked(string id) => id.Length <= MaxLength
        ? id
        : throw new ArgumentException($"custom_id exceeds {MaxLength} chars: {id}", nameof(id));
}
```

Rules: `feature:action:args`; ≤ 100 chars (validate when building); wildcard parameters bind through type
readers for `IConvertible` types (string, int, ulong, enum…) — for `Guid` bind as `string` or register
`interactions.AddTypeReader<Guid>(…)`. If state doesn't fit, store
it (FusionCache — `noobit:fusioncache-redis` — or the DB) under a short key and put the key in the custom id; handle "expired" gracefully.
Who may click? Anyone who can see a public message. Restrict by putting the owner's user id in the custom id
and checking `Context.User.Id` in the handler (or a precondition).

## 4. Modals

Declare the modal as an `IModal` class — Discord.Net produces the current Label-based layout:

`FeedbackModal.cs`

```csharp
namespace MyApp.Discord.Modals;

public sealed class FeedbackModal : IModal
{
    public string Title => "Send feedback";

    [InputLabel("Topic", "What is this about?")]
    [ModalSelectMenu("topic")]
    [ModalSelectMenuOption("Bug report", "bug")]
    [ModalSelectMenuOption("Feature idea", "idea")]
    [ModalSelectMenuOption("Something else", "other")]
    public string[] Topic { get; set; } = [];

    [InputLabel("Your feedback")]
    [ModalTextInput("body", TextInputStyle.Paragraph, placeholder: "Tell us more…", minLength: 10, maxLength: 1000)]
    public string Body { get; set; } = "";

    [InputLabel("Contact me about this")]
    // no [RequiredInput(false)]: Discord.Net throws at module build — a checkbox has no "required" (always true/false)
    [ModalCheckbox("contact")]
    public bool MayContact { get; set; }
}
```

Opened and handled by `FeedbackModule` in [gateway-bot.md](gateway-bot.md) §6: `RespondWithModalAsync<FeedbackModal>(id)`
as the first response; `[ModalInteraction(id)]` receives the bound class.

`FeedbackCard.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class FeedbackCard
{
    public static MessageComponent Thanks(FeedbackModal feedback) =>
        new ComponentBuilderV2()
            .WithContainer(new ContainerBuilder()
                .WithAccentColor(Brand.Success)
                .WithTextDisplay("### ✅ Thanks for your feedback!")
                // user input is echoed inside a quote; allowed_mentions on the response prevents pings
                .WithTextDisplay($"> {feedback.Body.ReplaceLineEndings("\n> ")}")
                .WithTextDisplay($"-# Topic: {string.Join(", ", feedback.Topic)} · " +
                                 (feedback.MayContact ? "we may contact you" : "we won't contact you")))
            .Build();
}
```

Modal facts:
- Available inputs (each inside a Label, ≤ 5 per modal): text input (`[ModalTextInput]`), string select
  (`[ModalSelectMenu]` + `[ModalSelectMenuOption]`, binds `string[]`), user/role/channel/mentionable selects,
  file upload (`[ModalFileUpload]`, 0–10 files), radio group, checkbox group, single checkbox
  (`[ModalCheckbox]`, `bool`), plus static `[ModalTextDisplay]` text.
- `[RequiredInput(false)]` makes an input optional — **not on a checkbox**: Discord.Net throws at module build
  (a checkbox has no `required` field; it always submits true/false).
- Pre-fill values for an "edit" flow: `RespondWithModalAsync<T>(customId, modalInstance)` or
  `modifyModal: b => b.UpdateTextInput("body", t => t.Value = current)`.
- A modal can't be opened from a modal submit, and the submit can't open another modal; chain with a button.
- Put the entity id in the modal's custom id (`"ticket:edit:*"`) when the submit must know what it edits.

## 5. Autocomplete

`DocsAutocomplete.cs`

```csharp
namespace MyApp.Discord.Search;

/// <summary>Shared by gateway and HTTP modules. Cached singleton: no constructor dependencies (see below).</summary>
public sealed class DocsAutocomplete : AutocompleteHandler
{
    public override Task<AutocompletionResult> GenerateSuggestionsAsync(
        IInteractionContext context, IAutocompleteInteraction autocompleteInteraction,
        IParameterInfo parameter, IServiceProvider services)
    {
        var search = services.GetRequiredService<IDocsSearch>(); // scoped deps (DbContext) are safe this way
        var typed = autocompleteInteraction.Data.Current.Value as string ?? "";
        var choices = search.Suggest(typed, 25)
            .Select(title => new AutocompleteResult(title.Length <= 100 ? title : title[..100], title));
        return Task.FromResult(AutocompletionResult.FromSuccess(choices));
    }
}
```

Attach with `[Autocomplete<DocsAutocomplete>]` on the parameter. **Handlers are cached singletons**
(`InteractionService` builds each type once): constructor-injecting a scoped `DbContext` would capture it for
the process lifetime — resolve from `services` per call as above. Autocomplete can't be deferred: serve from
memory/cache (FusionCache, `noobit:fusioncache-redis`) or an indexed query with a hard timeout. Autocomplete values are suggestions —
validate the submitted value in the command.

`IDocsSearch.cs`

```csharp
namespace MyApp.Discord.Search;

public sealed record DocHit(string Title, string Url, string Snippet);

public interface IDocsSearch
{
    /// <summary>Fast prefix lookup for autocomplete — must answer well inside Discord's 3 s budget.</summary>
    IReadOnlyList<string> Suggest(string prefix, int max);

    /// <summary>Potentially slow full search (DB, HTTP) — callers defer the interaction first.</summary>
    Task<IReadOnlyList<DocHit>> SearchAsync(string query, CancellationToken ct);
}
```

## 6. Context-menu commands & profile card

```csharp
// excerpt — add to GeneralModule (gateway-bot.md §6); the message command appears only here
[UserCommand("Show profile")]   // right-click user → Apps → Show profile
public Task ProfileAsync(IUser user) =>
    RespondAsync(components: ProfileCard.Build(user), ephemeral: true, allowedMentions: AllowedMentions.None);

[MessageCommand("Summarize")]   // right-click message → Apps — the target's content is readable without MessageContent
public Task SummarizeAsync(IMessage message) =>
    RespondAsync($"{message.Content.Length} characters", ephemeral: true);
```

`ProfileCard.cs`

```csharp
namespace MyApp.Discord.Cards;

public static class ProfileCard
{
    public static MessageComponent Build(IUser user) =>
        new ComponentBuilderV2()
            .WithContainer(new ContainerBuilder()
                .WithAccentColor(Brand.Accent)
                .WithSection(new SectionBuilder()
                    .WithTextDisplay($"### {user.GlobalName ?? user.Username}")
                    // <t:unix:R> renders in each viewer's locale and timezone ("3 years ago")
                    .WithTextDisplay($"{user.Mention} · joined Discord <t:{user.CreatedAt.ToUnixTimeSeconds()}:R>")
                    .WithAccessory(new ThumbnailBuilder(user.GetDisplayAvatarUrl(size: 256), description: "Avatar"))))
            .Build();
}
```

## 7. Embeds, polls, selects, premium, emojis

```csharp
// excerpt — smaller building blocks inside an InteractionModuleBase<SocketInteractionContext>
// Classic embed: still right for `content` + card together, link-preview style output, CI-style status.
var embed = new EmbedBuilder()
    .WithTitle("Deployment finished").WithUrl("https://example.com/deployments/42")
    .WithDescription("Version **2.4.1** is live.")
    .AddField("Duration", "3m 12s", inline: true)
    .WithColor(Brand.Success).WithCurrentTimestamp()
    .Build(); // throws if limits are exceeded (title 256, description 4096, 25 fields, 6000 total)
await RespondAsync("Heads up:", embed: embed, allowedMentions: AllowedMentions.None);

// Native poll: Discord renders voting and results. Not combinable with Components V2.
await RespondAsync(poll: new PollProperties
{
    Question = new PollMediaProperties { Text = question },
    Answers = [new PollMediaProperties { Text = "Yes" }, new PollMediaProperties { Text = "No" }],
    Duration = 24, // hours, max 768 (32 days)
});

// Selects: a string select with fixed options and an auto-populated channel select.
var components = new ComponentBuilderV2()
    .WithActionRow([new SelectMenuBuilder("settings:theme", placeholder: "Theme").AddOption("Light", "light").AddOption("Dark", "dark")])
    .WithActionRow([new SelectMenuBuilder("settings:logchannel", placeholder: "Log channel", type: ComponentType.ChannelSelect)
        .WithChannelTypes(ChannelType.Text)])
    .Build();

// Select handlers take the selected values as the LAST parameter; typed arrays for auto-populated selects.
[ComponentInteraction("settings:logchannel")]
public Task LogChannelAsync(IChannel[] channels) => RespondAsync($"Logging to <#{channels[0].Id}>.", ephemeral: true);

// Monetization: entitlements arrive on every interaction — gate cheaply, upsell with a Premium button (style 6).
// Premium buttons carry only the SKU: no label, emoji, url or custom_id; Discord renders name and price.
// Build it with the constructor, never ButtonBuilder.CreatePremiumButton (SKILL.md "Common mistakes").
if (!Context.Interaction.Entitlements.Any(e => e.SkuId == PremiumSkuId))
{
    await RespondAsync(ephemeral: true, components: new ComponentBuilderV2()
        .WithTextDisplay("This is a premium feature.")
        .WithActionRow([new ButtonBuilder(style: ButtonStyle.Premium, skuId: PremiumSkuId)])
        .Build());
}

// Application emojis (Developer Portal → Emojis, up to 2000): usable everywhere, even by user-installed apps.
// Fetch once at startup and cache (Context.Client.GetApplicationEmotesAsync()) — not per interaction.
```

When to use which:

| Want | Use |
|---|---|
| Structured card, inline images, buttons inside the card, > 10 "blocks" | Components V2 container |
| Text + a card in one message, link-preview look, quick CI-style status | Classic embed (+ legacy action row) |
| Voting | Native poll (`PollProperties`) — not combinable with V2 |
| Pick from ≤ 25 known values | String select or slash-command choices/enum |
| Pick a user/role/channel | Auto-populated select (`ComponentType.UserSelect` …) or a typed command option |
| Long free text, several fields | Modal |
| Search-as-you-type over many values | Autocomplete |

## 8. Ephemeral vs public, editing, timestamps, mentions

- `DeferAsync(ephemeral: true)` decides the ephemerality of the original response; a later
  `FollowupAsync(ephemeral: …)` creates a *new* message with its own setting.
- To turn an ephemeral preview into a public post: respond ephemerally with a "Post publicly" button whose
  handler calls `FollowupAsync(...)` (public). Avoid `Context.Channel.SendMessageAsync(...)` for this — in
  user-install contexts the bot isn't a member there and gets 403; follow-ups work everywhere.
- Check what the app may do in this channel before trying: `Context.Interaction.Permissions` (the payload's
  `app_permissions`), e.g. `EmbedLinks`, `AttachFiles`, `SendPolls`.
- Ephemeral messages can be edited (deferred update + `ModifyOriginalResponseAsync`) but not by other users.
- Timestamps: `TimestampTag.FromDateTimeOffset(dto, TimestampTagStyles.Relative)` or `$"<t:{unix}:R>"` —
  rendered in each viewer's timezone and language.
- Mentions: `user.Mention`, `MentionUtils.MentionChannel(id)`, `MentionUtils.MentionRole(id)`; a mention
  only pings if `allowedMentions` permits it — so you can show `<@id>` safely with `AllowedMentions.None`.
- Clickable command mention: `</search:COMMAND_ID>` (id from registration result).
- `flags: MessageFlags.SuppressNotification` (`@silent`) for low-priority posts.

## 9. Localization

- Commands: `InteractionServiceConfig.LocalizationManager = new JsonLocalizationManager("Locales", "commands")`
  (or `ResxLocalizationManager`) supplies `name_localizations`/`description_localizations` at registration.
- Responses: use `Context.Interaction.UserLocale` (fallback `GuildLocale`) with your normal .NET
  localization (`IStringLocalizer`). Command names in handlers are always the default names.
