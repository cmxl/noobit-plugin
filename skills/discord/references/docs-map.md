# Where to verify things

Discord changes something most months, and Discord.Net follows with a lag. When this skill doesn't cover a
detail, or something seems off, check these sources in order and say which one you used.

## 1. Discord's official docs (source of truth for the platform)

- Home: https://docs.discord.com/developers/intro. The docs moved to Mintlify on this domain (changelog
  2026-02-10); old `discord.com/developers/docs/...` links redirect.
- Discord also offers a docs MCP server: https://docs.discord.com/mcp.
- **Full page index:** https://docs.discord.com/llms.txt
- **Raw markdown of any page:** append `.md` to its URL, e.g.
  `https://docs.discord.com/developers/components/reference.md`. This gives exact tables and limits without
  the HTML noise, so use it with WebFetch.
- **Changelog:** https://docs.discord.com/developers/change-log. Check it before claiming something is new,
  deprecated or a limit.

| Topic | Path (under `/developers/`) |
|---|---|
| Interactions: receive, respond, callback types, HTTP endpoint | `interactions/receiving-and-responding` |
| Application commands, limits, permissions, contexts | `interactions/application-commands` |
| Component reference (V2, modals, all limits) | `components/reference`, `components/using-message-components`, `components/using-modal-components` |
| Message object, embeds, flags, allowed mentions, uploads | `resources/message`, `reference` |
| Gateway, intents, sharding, close codes | `events/gateway`, `events/gateway-events`, `topics/opcodes-and-status-codes` |
| Privileged intents policy | `events/gateway#privileged-intents`, guide "you might not need a privileged intent" |
| Webhook Events | `events/webhook-events` |
| OAuth2, scopes | `topics/oauth2` |
| Permissions bitfield | `topics/permissions` |
| Rate limits | `topics/rate-limits` |
| Application object, installation contexts | `resources/application` |
| Monetization (SKUs, entitlements, subscriptions) | `monetization/overview`, `resources/entitlement`, `resources/sku` |
| Linked Roles metadata | `resources/application-role-connection-metadata` |
| Polls, emojis, threads, scheduled events | `resources/poll`, `resources/emoji`, `topics/threads`, `resources/guild-scheduled-event` |

## 2. Discord.Net (source of truth for the library)

- Repo: https://github.com/discord-net/Discord.Net. The default branch is `dev` and carries unreleased
  changes; read the **release tag** you're on. Verify the checkout: `git describe --tags` must print the tag
  (3.20.1 = commit `f63bed0`, "meta-3.20.1"). A plain `git clone` gives you `dev`.
- NuGet: https://www.nuget.org/packages/Discord.Net.Interactions (check the latest version before upgrading).
- Hosted docs: https://docs.discordnet.dev.

| Need | Look at |
|---|---|
| Breaking changes per version | `docs/guides/breakings/v3.18.md` (Components V2), `v3.19.md` (net8+ only, modal refactor), `v3.20.md` |
| Interaction Framework guides | `docs/guides/int_framework/` (`intro`, `modals`, `autocompletion`, `preconditions`, `typeconverters`, `post-execution`, `permissions`) |
| Components V2 guide and samples | `docs/guides/components_v2/` |
| Exact builder APIs | `src/Discord.Net.Core/Entities/Interactions/MessageComponents/Builders/` (`ComponentContainerExtensions.cs` has all the `With…` helpers) |
| Modal attributes | `src/Discord.Net.Interactions/Attributes/Modals/` |
| HTTP interaction parsing | `src/Discord.Net.Rest/DiscordRestClient.cs` (`IsValidHttpInteraction`, `ParseHttpInteractionAsync`), `src/Discord.Net.Interactions/RestInteractionModuleBase.cs` |
| Socket config defaults | `src/Discord.Net.WebSocket/DiscordSocketConfig.cs`, `src/Discord.Net.Core/DiscordConfig.cs` |
| Reconnect behaviour | `src/Discord.Net.WebSocket/ConnectionManager.cs` |
| RunMode semantics | `src/Discord.Net.Interactions/Info/Commands/CommandInfo.cs` |
| Samples | `samples/InteractionFramework`, `samples/ShardedClient`, `samples/WebhookClient`. These target 3.18 and include a MediatR sample that isn't our pattern. |

Ways to check fast:
- Read the package's XML docs in the local NuGet cache (`dotnet nuget locals global-packages -l` →
  `discord.net.core/<ver>/lib/net9.0/Discord.Net.Core.xml`) and grep type and member names.
- Or shallow-clone the tag: `git clone --depth 1 --branch 3.20.1 https://github.com/discord-net/Discord.Net`
  into a **fresh** directory (an existing clone is not re-checked-out — this is how a review of this skill once
  ended up reading `dev`).
- If you're still unsure, write the snippet into the project and compile it. A compiler error is cheaper
  than a wrong claim.

## 3. Known gaps between Discord and Discord.Net 3.20.1

- `ModalFileTypeAttribute` / `file_types` filters (Discord 2026-08) exist only on Discord.Net's `dev` branch.
- The gateway `capabilities` field (channel-obfuscation test flag) and `zstd-stream` compression aren't
  exposed.
- Webhook Events have no typed support. Handle them as raw JSON (see app-integration.md).
- If Discord has a feature the library doesn't expose yet, call the REST endpoint yourself through
  `IHttpClientFactory`, using the bot token and a `DiscordBot (url, version)` User-Agent. Rate limits are
  then your responsibility: parse the `X-RateLimit-*` headers.

## 4. Verification log

- 2026-10-02: Discord docs (Mintlify, `.md` sources) and Discord.Net **3.20.1** (tag source and NuGet).
  Reference code compiled on .NET SDK 10.0.400. 37 tests passed (cards, routing, signed HTTP end-to-end
  including error-path timing, webhook events, publisher, gateway lifecycle). A startup smoke test against
  discord.com confirmed that a bad token now fails startup.
- 2026-10-02 (independent review against the 3.20.1 tag): fixed a 5 s stall on unknown commands in HTTP mode, a
  token check that threw on valid tokens, the premium-button helper bug, public error leaks after public
  defers, the HTTP-mode precondition limitation, and DM parsing on an anonymous client; eval round 2 then
  surfaced the blocking `DiscordWebhookClient` constructor (now created off-thread on first use).
- 2026-10-03 (second review round, Discord.Net 3.20.1 tag + docs repo): health checks kept dependency-free,
  webhook client no longer caches a failed construction, autocomplete handlers resolve scoped services per call,
  bounded body reads (chunked) on both signed endpoints, ±5 min replay check on interactions, Content-Type on
  Webhook Events 204s, inbox resolved from `RequestServices`, request-abort handling, cancellable startup,
  registration off the gateway task, sharded variant with error replies and fatal-close stop, order-independent
  inbox test. Every `File.cs` block re-extracted into one solution (.NET 10, xunit.v3 4.0.1, NSubstitute 6.2.0):
  **0 errors, 0 warnings, 49/49 tests pass.** Not yet verified against a live guild: the valid-token startup
  path and real Discord acceptance of each payload. Run the manual smoke test on a dev application before
  relying on it.
