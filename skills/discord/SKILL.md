---
name: discord
description: 'Use when a .NET app talks to Discord via Discord.Net: gateway bots or HTTP interaction endpoints (slash/context commands, buttons, modals, autocomplete, Components V2), posting from an API/worker to channels/webhooks, Webhook Events, entitlements, Linked Roles, OAuth2 account linking, or errors ("did not respond", "already acknowledged", 4004/4014, 429). Not for discord.js/discord.py, voice bots, Activities, Slack/Teams bots or "Sign in with Discord" (bff-security).'
---

# Discord apps with Discord.Net

## Overview

A Discord **application** optionally has a **bot user**. Users reach it through **interactions** (commands,
buttons, selects, modals, autocomplete), received *either* over the **gateway** WebSocket *or* at an **HTTP
interactions endpoint**. You respond within **3 s** (or defer, then edit for 15 min). Everything else is REST
or gateway events.

Library: **Discord.Net 3.20.x** (`net8.0`/`net9.0`/`net10.0`), with `Discord.Net.Interactions` (Interaction
Framework) for all command/component/modal handling — never a hand-rolled `SlashCommandExecuted` dispatcher.

Verified against Discord.Net 3.20.1 / docs.discord.com, October 2026 — not yet against a live guild; when a
detail is missing or doubtful, check [references/docs-map.md](references/docs-map.md) instead of guessing.

## When to use

- Building or fixing a Discord bot/app in .NET: slash, user and message commands, buttons, selects, modals,
  autocomplete, Components V2 cards, embeds, polls.
- Choosing the gateway (`DiscordSocketClient`, intents, sharding) vs the HTTP interactions endpoint
  (`X-Signature-Ed25519`, PING), or a REST-only client / channel webhook for posting from an API or worker.
- Webhook Events (`APPLICATION_AUTHORIZED`, `ENTITLEMENT_CREATE`), user-installable apps, entitlements, Linked
  Roles, linking a user's Discord account via OAuth2.
- Symptoms: "The application did not respond", "Unknown interaction", "already been acknowledged", commands
  running twice, close code 4004/4014, 429s or a reset bot token, empty message content.

Out of scope: voice/music bots, Activities (Embedded App SDK), non-.NET libraries, and Discord as the app's
login provider (`noobit:bff-security`).

## Reference files — read the one you need

| File | Read when |
|---|---|
| [references/platform.md](references/platform.md) | You need how Discord works: install contexts, intents, gateway vs HTTP, callback types, **all limits and rate limits**, recent breaking changes |
| [references/gateway-bot.md](references/gateway-bot.md) | Building a gateway bot: packages, DI, hosted service, error replies, command registration, modules, sharding, where it runs, health |
| [references/http-interactions.md](references/http-interactions.md) | Building the Interactions Endpoint URL variant: signature + replay checks, dispatch, REST modules, deployment |
| [references/rich-ui.md](references/rich-ui.md) | Designing messages: Components V2 cards, pagination, modals, selects, autocomplete, embeds, polls, emojis, premium buttons |
| [references/app-integration.md](references/app-integration.md) | Your API/worker posting to Discord, channel webhooks, Webhook Events, OAuth2 account linking, Linked Roles, outbox/idempotency |
| [references/testing.md](references/testing.md) | Testing without Discord: cards, routing contracts, signed HTTP end-to-end, NSubstitute on Discord.Net interfaces |
| [references/docs-map.md](references/docs-map.md) | Verifying anything: official docs (raw `.md`), Discord.Net source paths, known library gaps |

## Choose the connection

| Need | Use |
|---|---|
| Commands/buttons/modals **and** guild events (members, messages, reactions, presence) | **Gateway bot** — `DiscordSocketClient` in a hosted service |
| Only interactions; app already runs scaled-out or serverless | **HTTP interactions endpoint** — `DiscordRestClient` + minimal API |
| App posts/edits messages, manages roles/channels, no incoming interactions | **REST only** — logged-in `DiscordRestClient` singleton behind `IDiscordClient` |
| Notifications into one channel, no bot at all | **Channel webhook** (no interactive components) |
| User installs / deauthorizations | **Webhook Events** endpoint — webhook-only, any hosting mode; needs `Discord:PublicKey` (a gateway-mode app adds that rule + the inbox itself, app-integration.md §5). `ENTITLEMENT_*` come here *and* on the gateway (shard 0) |

**Where a gateway bot runs: exactly one process per bot token** (or one sharded client). Two connections both
receive every event and both answer ("already acknowledged"). Inside an API only while it has one replica;
otherwise a separate single-replica worker, or HTTP interactions.

Unsure? Gateway for a team/internal bot; HTTP when the app already runs scaled-out. One interaction transport
per application.

## Core rules

1. **Interactions, not message parsing.** `MessageContent`, `GuildMembers`, `GuildPresences` are privileged
   (portal toggle; review + annual renewal above 10,000 users). Start with `GatewayIntents.Guilds`, add an
   intent only for a feature that needs it. Never `GatewayIntents.All` (4014 when not enabled).
2. **Acknowledge within 3 s.** Anything doing I/O: `DeferAsync()` first, then `ModifyOriginalResponseAsync` /
   `FollowupAsync`. Modals and autocomplete **cannot** be deferred. Ephemerality is fixed by the first
   response; a deferred response takes only the ephemeral flag — set `MessageFlags.ComponentsV2` on the edit.
3. **Subscribe once, register once.** Wire handlers in `StartAsync`, never inside `Ready` (it fires after every
   non-resumed reconnect → commands run N times). Register from `Ready` behind an `Interlocked` guard, off the
   gateway task: guild registration while developing, global in production (both bulk-overwrite — so only the ONE
   process that owns the modules registers; a REST-only API never does, app-integration.md §3). Contexts and
   integration types only apply globally — test DM/user installs on a separate dev application.
4. **`RunMode.Async` + `InteractionExecuted`.** Failures, unmet preconditions and unknown commands arrive in
   `InteractionExecuted`; answer the user ephemerally every time (after a public defer, delete the placeholder
   first). Never "The application did not respond". `ThrowOnError = false`.
5. **Stateless handlers.** Encode state in the `custom_id` (≤ 100 chars, `feature:action:arg`, wildcard-bound)
   or store it keyed by a short id. One `CustomIds` class for builders and handlers.
6. **Components V2 for new rich messages** (≤ 40 components, no `content`/`embeds`/`poll`). Socket responses add
   the flag; **HTTP-mode interaction responses don't — pass `MessageFlags.ComponentsV2`.** Embeds stay valid.
7. **`AllowedMentions.None`** whenever a message echoes user input or app data.
8. **Never call Discord inside a request or `SaveChanges`.** Enqueue (bounded `Channel<T>`); a
   `BackgroundService` publishes through `IDiscordClient`. Must-not-lose → outbox; with several replicas the
   outbox rows must be **claimed** or every replica posts them (app-integration.md §1).
9. **No second retry layer around Discord.Net.** It queues per rate-limit bucket and retries 429/502/timeouts
   itself. 401/403 are config errors — log, don't retry (401/403/429 feed Cloudflare's 10,000-per-10-min IP
   ban); drop a webhook after 404.
10. **Fail fast on a bad token; stop on fatal close codes.** Socket `LoginAsync` only checks the format: call
    `client.GetApplicationInfoAsync(new RequestOptions { CancelToken = ct })` after login. Discord.Net reconnects
    forever except on 4006/4014 — stop the host on 401 / 4004 / 4006 / 4010–4014 (non-zero exit) and restart only
    with backoff: burning the daily identify limit makes Discord **reset the token**.
11. **Liveness never depends on Discord.** `/health/live` stays dependency-free; `ConnectionState` goes to
    `/health/ready` or a metric. Otherwise an outage restarts the bot, and restarts re-identify (rule 10).
12. **HTTP endpoint contract:** bounded raw-body read (never model-bind), Ed25519 over `timestamp + body` plus a
    ±5-minute timestamp check → **401** on failure (Discord probes with bad signatures), PING → `{"type":1}`,
    modules derive from `RestInteractionModuleBase<RestInteractionContext>`, the client is logged in before
    serving, and `/discord/*` is exempt from the BFF's per-IP global rate limiter (Discord's few egress IPs
    would hit 429 → "did not respond"). Serverless only with warm instances.
13. **Declare where commands work.** Every module: `[CommandContextType]` + `[IntegrationType]`; admin commands:
    `[DefaultMemberPermissions]`. Guild preconditions need the guild fetched in HTTP mode.
14. **Mind DI lifetimes.** Modules get a scope per execution; **autocomplete handlers and preconditions are
    cached singletons** — resolve scoped services from the `services` argument, never the constructor. Code
    that outlives the request uses the root provider; code finishing inside it uses `RequestServices`.
15. **Secrets:** bot token, OAuth2 client secret and webhook URLs via user-secrets in development and compose
    secret files in production (`/run/secrets/Discord__Token` + `AddKeyPerFile`, never compose `environment:`),
    never in appsettings or logs. The public key is not secret.

## Stack fit (deliberate deviations)

Intentional departures from sibling skills — don't "fix" them in review:

- **No Polly around Discord.Net** (vs `noobit:aspnet-backend`: Polly v8 around external SDKs). It already
  retries per rate-limit bucket; a second layer double-posts and stacks retries against 429s (IP-ban fuel).
  Raw `HttpClient` calls to Discord keep the standard resilience handler; the OAuth code exchange runs in the
  ASP.NET Core OAuth handler's backchannel, which never retries the single-use code.
- **`Task.Run` in the HTTP interactions handler and gateway events** (vs aspnet-backend: no `Task.Run` in
  handlers). The command outlives the response (it edits after the deferral is flushed), and unknown commands
  answer through a callback that waits for that flush — awaiting would stall 5 s. Gateway events run on the
  gateway task, so slow work (registration) moves off it.
- **Verify at ingress, not store-first** (vs `noobit:paypal`). Ed25519 is local and cheap and Discord expects
  401 for bad signatures; PayPal's check needs a remote call, so it verifies later. `noobit:bff-security`
  allows both.
- **Discord login is not ours.** OAuth2 here only *links* a Discord account to a signed-in user; "Sign in with
  Discord" is an external-login decision for `noobit:bff-security` (OAuth behind the cookie BFF).
- **Newtonsoft.Json** is a transitive dependency of Discord.Net — accepted for the library only; your code stays
  on source-generated System.Text.Json.
- **No Native AOT / trimming; `InvariantGlobalization=false`** (guild locales build `CultureInfo`). Chiseled
  images need the ICU ("extra") variant, Alpine `icu-libs` (`noobit:docker`).
- **Own `IHostedService`** (`Discord.Addons.Hosting` is stale); `LogMessage` → `ILogger` with real severities.
- **No mediator:** modules *are* the handlers (ignore the Discord.Net MediatR sample).
- **One or two `.Validate(...)` lambdas per hosting mode on top of the generated options validator** (vs
  aspnet-backend: DataAnnotations + `[OptionsValidator]` only). `DiscordOptions` is shared by both hosting modes; format rules are DataAnnotations,
  but "token required" depends on the hosting mode (and, in HTTP mode, on the environment), which attributes
  on a shared class can't express (gateway-bot.md §2, http-interactions.md §2).

## Quick reference

| Thing | Value |
|---|---|
| Deadlines | 3 s initial response · 15 min for edits and follow-ups |
| Callback types | 4 message · 5 deferred message · 6 deferred update · 7 update · 8 autocomplete · 9 modal |
| Flags (`MessageFlags`) | `Ephemeral` 1<<6 · `SuppressNotification` 1<<12 · `ComponentsV2` 1<<15 |
| Limits, rate limits | platform.md §6–§8 (components, embeds, modals, commands, global/invalid-request limits) |

## Common mistakes

Mistakes not already covered by a core rule:

| Mistake | Consequence | Fix |
|---|---|---|
| `ButtonBuilder.CreatePremiumButton(...)` | Throws "must have a custom id" (3.20.1 bug) | `new ButtonBuilder(style: ButtonStyle.Premium, skuId: id)` |
| `new DiscordWebhookClient(url)` in DI/startup, or cached in a `Lazy` | Blocking HTTP at construction; a failure stops alerts until restart | Build off-thread on first use, cache only success (app-integration.md §4) |
| `[RequireUserPermission]` in HTTP mode with `doApiCall: false` | Every guild command fails | `[DefaultMemberPermissions]` + app checks, or fetch the guild |
| `[RequiredInput(false)]` on a modal checkbox | Module build fails | Checkboxes always submit true/false |
| `IResult` in a web project | CS0104 ambiguity | `using IResult = Discord.Interactions.IResult;` |
| Disposing the shared client in a hosted service | Other consumers break on shutdown | DI owns the singleton; services only Stop/Logout |
| Logging modal/free-text bodies | Personal data in logs | Log ids, lengths, topics |
| Hard-coded channel/guild ids | Breaks per environment | Options (`Discord:AnnouncementChannelId`) |
| More than 25 embed fields / choices from data | 400 at runtime | Clamp in the builder; unit-test limits |
| Raw webhook POST without `?with_components=true` | Components silently ignored | Add the query parameter (Discord.Net does) |
