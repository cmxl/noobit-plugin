# Where to verify things

Discord changes something most months, and Discord.Net follows with a lag. When this skill doesn't cover a
detail, or something seems off, check these sources in order and say which one you used.

## 1. Discord's official docs (source of truth for the platform)

- Home: https://docs.discord.com/developers/intro. The docs moved to Mintlify on this domain (changelog
  2026-02-10); old `https://discord.com/developers/docs/<path>` links answer **301** to
  `https://docs.discord.com/developers/<path>` — cite the new URL, never the old one.
- Discord also offers a docs MCP server: https://docs.discord.com/mcp.
- **Full page index:** https://docs.discord.com/llms.txt
- **Raw markdown of any page:** append `.md` to its URL, e.g.
  `https://docs.discord.com/developers/components/reference.md`. This gives exact tables and limits without
  the HTML noise, so use it with WebFetch.
- **Changelog:** https://docs.discord.com/developers/change-log. Check it before claiming something is new,
  deprecated or a limit.

| Topic | Path (under `https://docs.discord.com/developers/`; all answered 200, October 2026) |
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

## 4. Verification status

Verified against Discord.Net 3.20.1 / docs.discord.com, October 2026. Not yet verified against a live guild
(valid-token startup, Discord's acceptance of each payload): run the manual smoke test on a dev application
(testing.md) before relying on it.
