# How Discord works (platform reference)

Verified 2026-10-02 against https://docs.discord.com/developers (raw markdown: append `.md` to any page URL).
API version **v10**. Values marked *(2025+)* changed recently — older blog posts and LLM memory get them wrong.

## Contents
1. App model & installation
2. Gateway (WebSocket)
3. Intents
4. HTTP interactions endpoint
5. Interactions & callbacks
6. Application commands
7. Components & limits
8. Rate limits
9. Recent and upcoming changes

---

## 1. App model & installation

- **Application** = the thing in the Developer Portal (id, public key, icon, install settings).
  **Bot user** = optional user account the app acts as (token in *Bot* tab). An app can run commands
  without being a guild member (user installs).
- **Installation contexts** (`integration_types`):
  - `GUILD_INSTALL` (0) — a member with Manage Server adds it; visible to all members; has a bot role and
    permissions.
  - `USER_INSTALL` (1) — a user adds it to their account; their commands work in every server, DM and group
    DM *for that user only*; responses must respect that user's permissions there and are **forced ephemeral**
    where the server denies `USE_EXTERNAL_APPS`; max 5 follow-ups per interaction when not also guild-installed.
  - New apps are guild-install only → enable user install in Portal → *Installation*.
- **Interaction contexts** (`contexts` on a command): `GUILD` (0), `BOT_DM` (1), `PRIVATE_CHANNEL` (2 —
  group DMs and DMs between other users; user installs only). `dm_permission` is deprecated.
- **Install link**: Portal → Installation → "Discord Provided Link" (`https://discord.com/oauth2/authorize?client_id=…`)
  with default install settings per context: guild install `applications.commands` + `bot` (+ a permissions
  integer), user install `applications.commands` only. Request only the permissions you use.
- **Permissions** are a big-integer bitfield serialized as a string (already > 52 bits). Since 2026-02-23 these
  are split out and must be requested explicitly: `PIN_MESSAGES` (1<<51, was Manage Messages),
  `CREATE_GUILD_EXPRESSIONS` (1<<43, creating emoji/stickers), `CREATE_EVENTS` (1<<44). `BYPASS_SLOWMODE`
  (1<<52) exists too, but bots aren't subject to slowmode, so apps don't need it.
  `USE_EXTERNAL_APPS` (1<<50) decides whether user-installed apps may post publicly in a server.
- Every interaction carries **`app_permissions`** (Discord.Net: `Context.Interaction.Permissions`) — check it
  before attempting an action instead of eating 403s. Resolved channels carry their own `app_permissions`
  *(2026-07)*.
- `authorizing_integration_owners` tells you which installation(s) authorized the interaction
  (`"0"` → guild id, `"1"` → user id). Branch on it when guild and user installs behave differently.

## 2. Gateway (WebSocket)

Discord.Net's `DiscordSocketClient` implements all of this — you need the model to read its logs and choose
settings, not to reimplement it.

- `GET /gateway/bot` → url, recommended `shards`, `session_start_limit` (typically 1000 identifies/24 h,
  `max_concurrency` identifies per 5 s). Connect `wss://gateway.discord.gg/?v=10&encoding=json`.
- Flow: Hello (op 10, `heartbeat_interval`) → Identify (op 2, token + intents + shard) → READY (`session_id`,
  `resume_gateway_url`) → dispatches (op 0) with sequence numbers. Heartbeat (op 1) every interval; missing ACK
  (op 11) = zombie connection → reconnect & Resume (op 6) to `resume_gateway_url`; missed events replay.
- **READY fires again after any reconnect that could not resume** — never subscribe handlers or do one-time
  setup in it without a guard.
- **Close codes that must not reconnect**: 4004 auth failed, 4010 invalid shard, 4011 sharding required,
  4012 invalid API version, 4013 invalid intents, 4014 disallowed (privileged, not enabled) intents.
  Discord.Net only stops on 4006/4014 by itself — stop the host on the others (gateway-bot.md), and restart
  only with backoff: exhausting the daily identify limit terminates all sessions and **resets the bot token**.
- **Sharding**: required at 2,500 guilds per shard (4011 otherwise). `shard_id = (guild_id >> 22) % num_shards`.
  DMs and entitlement events go to shard 0. Use `DiscordShardedClient` + `ShardedInteractionContext`; register
  commands once on the first `ShardReady`. Large bots (150k+ guilds) must use a multiple of the assigned count
  and, since *2026-09-15*, pass `shard` to Get Current User Guilds.
- Gateway send limit: **120 events / 60 s per connection** (presence updates, member requests…).
  Requesting *all* members of a guild (op 8, empty query) is limited to once per guild per 30 s *(2025)*.
- Message cache is opt-in in Discord.Net (`MessageCacheSize = 0` default): delete/update events give ids only.

## 3. Intents

| Intent | Privileged | Needed for |
|---|---|---|
| `Guilds` | no | Guild/channel/role cache, `GuildAvailable` — enough for interactions + posting |
| `GuildMessages` / `DirectMessages` | no | `MessageReceived` events (content still needs `MessageContent`) |
| `GuildMessageReactions` | no | Reaction events |
| `GuildVoiceStates` | no | Voice state, music bots |
| `GuildScheduledEvents` | no | Scheduled event events |
| `GuildMessagePolls` / `DirectMessagePolls` | no | Poll vote events |
| **`GuildMembers`** | **yes** | Member join/leave/update events, full member lists, `AlwaysDownloadUsers` |
| **`GuildPresences`** | **yes** | `PresenceUpdated` (no HTTP alternative) |
| **`MessageContent`** | **yes** | `content`/`embeds`/`attachments`/`components`/`poll` of other users' messages — over gateway *and* REST |

- Without `MessageContent` you still get content for: DMs with the bot, messages mentioning the bot, the
  bot's own messages, and the target of a **message context-menu command**. Prefer that over the intent.
- Privileged intents: toggle in Portal → Bot. *(2026-06)* Apps reaching **10,000 users** must apply; access is
  reviewed and renewed **annually**. Requesting an un-enabled privileged intent → close code 4014.

## 4. HTTP interactions endpoint

- Portal → General Information → **Interactions Endpoint URL** (public HTTPS). Saving it sends a PING; the URL
  is only accepted if you (a) reply `200 {"type":1}` and (b) reject a bad signature with **401**.
- Each POST carries `X-Signature-Ed25519` (hex) and `X-Signature-Timestamp`. Verify Ed25519 over
  `timestamp + raw body` with the app's **Public Key**. Discord sends deliberate bad-signature probes; failing
  them removes your URL (email + system DM).
- Respond **in the HTTP response body** (interaction response JSON) within 3 s. If you instead call
  `POST /interactions/{id}/{token}/callback`, answer the original HTTP request with 202 and no body.
- Interactions now never arrive over the gateway for this app.
- The interaction endpoints (initial callback, get/edit/delete `@original`, follow-ups) are exempt from the
  global rate limit.

## 5. Interactions & callbacks

| Interaction type | Value | Allowed responses |
|---|---|---|
| PING | 1 | PONG (1) — HTTP endpoint only |
| APPLICATION_COMMAND | 2 | 4, 5, 9 (modal), 12 (launch activity) |
| MESSAGE_COMPONENT | 3 | 4, 5, 6, 7, 9 |
| APPLICATION_COMMAND_AUTOCOMPLETE | 4 | 8 only (≤ 25 choices), no defer |
| MODAL_SUBMIT | 5 | 4, 5, 6, 7 — **not** another modal |

| Callback | Value | Meaning |
|---|---|---|
| CHANNEL_MESSAGE_WITH_SOURCE | 4 | Reply now |
| DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE | 5 | "Thinking…"; edit `@original` later. **Only the EPHEMERAL flag** is honoured here — V2 goes on the edit |
| DEFERRED_UPDATE_MESSAGE | 6 | Silent ack of a component; edit the message later |
| UPDATE_MESSAGE | 7 | Edit the message the component is on, as the response |
| APPLICATION_COMMAND_AUTOCOMPLETE_RESULT | 8 | Suggestions |
| MODAL | 9 | Must be the first response; cannot be deferred |
| PREMIUM_REQUIRED | 10 | **Deprecated** — use a Premium button (style 6) |
| LAUNCH_ACTIVITY | 12 | Activities apps |

- Initial response ≤ 3 s; token valid 15 min for `PATCH/DELETE /webhooks/{app}/{token}/messages/@original`
  and follow-ups `POST /webhooks/{app}/{token}`.
- An existing message's ephemerality cannot change. A follow-up right after a defer acting as "edit" is
  deprecated behaviour — edit the original explicitly.
- `locale` (user; all interactions except PING) and `guild_locale` (guild interactions) — localize responses
  with them.
- `entitlements` on every interaction: cheap premium gating.
- `attachment_size_limit` tells you the real upload limit for this context.

## 6. Application commands

- Types: CHAT_INPUT (slash, 1), USER (2), MESSAGE (3), PRIMARY_ENTRY_POINT (4, Activities).
- Names: slash 1–32 chars, lowercase, `^[-_\p{L}\p{N}…]{1,32}$`; user/message commands may use spaces and
  capitals ("Show profile"). Description 1–100.
- Limits: 100 global slash; **15 user + 15 message** context commands *(raised 2026-03)*; 25 options;
  25 choices; one nesting level (command → group → subcommand; a command with subcommands isn't itself
  invocable); 8000 chars combined name/description/choices; **200 command creates per day per guild**.
- Registration is REST: `PUT /applications/{app}/commands` (global) or `…/guilds/{guild}/commands` bulk-
  overwrites *all* commands of all types. Guild commands update instantly; global ones may take a moment to
  show up in clients. Workflow: guild commands while developing, global in production.
- `contexts` and `integration_types` apply to **global commands only**; guild commands never work in `BOT_DM`.
  Test DM/user-install behaviour with a separate dev application registered globally.
- `default_member_permissions` (string bitset; `"0"` = admins only) is the code-side gate. Per-role/channel
  overrides are set by server admins (Server Settings → Integrations) and can only be edited via API with a
  *user* Bearer token — a bot token cannot.
- Autocomplete: partial options with `focused: true`; values aren't constrained to suggestions (validate on
  submit). Mutually exclusive with `choices`.
- Option types: STRING 3, INTEGER 4, BOOLEAN 5, USER 6, CHANNEL 7, ROLE 8, MENTIONABLE 9, NUMBER 10,
  ATTACHMENT 11 (with `file_types` filter *(2026-08)*). String options accept multiline input *(2026-09)*.
- Localization: `name_localizations` / `description_localizations`; interactions always carry default names.

## 7. Components & limits

**Components V2** *(2025-04)* — message flag `IS_COMPONENTS_V2` (1<<15):

| Component | Type | Notes |
|---|---|---|
| Container | 17 | Card with optional `accent_color`, `spoiler`; holds rows, text, sections, galleries, separators, files |
| Section | 9 | 1–3 Text Displays + one accessory (Button or Thumbnail) |
| Text Display | 10 | Markdown; mentions obey `allowed_mentions` |
| Thumbnail | 11 | Section accessory; alt text ≤ 1024 |
| Media Gallery | 12 | 1–10 images/videos with alt text |
| File | 13 | `attachment://name` only |
| Separator | 14 | Divider and/or spacing (small/large) |
| Action Row | 1 | ≤ 5 buttons **or** 1 select |

- ≤ **40 components per message** (nested ones count), no top-level cap. (Discord.Net additionally caps a
  TextDisplay at 4000 chars in its builder.) A V2 message cannot have `content`,
  `embeds`, `poll` or stickers; attachments only show when a component references them. The flag cannot be
  removed once set. Legacy (non-V2) messages are not deprecated.
- Buttons: Primary/Secondary/Success/Danger need `custom_id`; **Link** (5) needs `url`, sends no interaction;
  **Premium** (6) needs `sku_id`, no label/custom id. Label ≤ 80.
- `custom_id`: 1–100 chars, unique among the components of one message/modal.
- Selects: string (3, ≤ 25 options), user (5), role (6), mentionable (7), channel (8, `channel_types`);
  `min_values` 0–25, `max_values` 1–25, placeholder ≤ 150.
- **Modals** *(reworked 2025-08 → 2026-02)*: title ≤ 45, 1–5 top-level components which must be **Label**
  (18) or **Text Display**. A Label (label ≤ 45, description ≤ 100) wraps exactly one of: Text Input (≤ 4000),
  any select, **File Upload** (19, 0–10 files), **Radio Group** (21), **Checkbox Group** (22), **Checkbox**
  (23). Action Row + Text Input in modals is **deprecated**; `disabled` on a select in a modal is an error.
- **Embeds** (legacy): title 256, description 4096, ≤ 25 fields (name 256, value 1024), footer 2048, author
  256, **6000 total across all embeds**, ≤ 10 embeds/message. Content ≤ 2000.
- Markdown extras that make messages feel native: `<t:unix:R>` (relative time, viewer's locale), `<t:unix:F>`,
  `<@id>` / `<#id>` / `<@&id>` mentions, `</command:id>` clickable command mention, `-# small text`, headings
  `#`/`##`/`###`, `> quote`, spoilers `||x||`.

## 8. Rate limits

- Per-route buckets keyed by method + route + top-level resource (channel/guild/webhook). Headers
  `X-RateLimit-Limit/Remaining/Reset/Reset-After/Bucket`; on 429 `Retry-After` + `X-RateLimit-Scope`.
  Never hard-code limits — Discord.Net reads the headers and queues per bucket.
- **Global**: 50 requests/s per bot (all interaction endpoints — callback, `@original`, follow-ups — exempt).
- **Invalid request limit**: 10,000 responses with 401/403/429 per 10 min per IP (429s with
  `X-RateLimit-Scope: shared` excluded) → temporary Cloudflare ban of the whole IP (all apps on that host).
  Causes: bad token loops, missing permissions. Stop using a webhook after it returns 404.
- Emoji routes are rate-limited per guild and the reported quota can be inaccurate.

## 9. Recent and upcoming changes (watch list)

| When | Change | Impact |
|---|---|---|
| 2024-03 | User-installable apps, `contexts`/`integration_types` | Declare both on every command |
| 2024-06 | Premium button; PREMIUM_REQUIRED deprecated | Upsell with a button |
| 2024-07 | Application emojis (2000/app) | Use them for button icons — work everywhere |
| 2024-10 | Webhook Events | Only way to see user installs |
| 2025-04 | Components V2 | Default for new rich messages |
| 2025-08 → 2026-02 | Label, selects, file upload, radio, checkbox in modals | Old ActionRow modals deprecated |
| 2026-02-23 | Permission splits enforced (pins, slowmode bypass, expressions, events) | Update install permissions |
| 2026-03-01 | Voice requires DAVE end-to-end encryption | Discord.Net ≥ 3.19 + libdave native |
| 2026-06 | Privileged intents threshold = 10,000 users, annual renewal | Avoid privileged intents |
| 2026-09-03 | Default upload limit 20 MiB | Use `attachment_size_limit` |
| 2026-04-14 | Forwarding a message requires being able to read its content (error 160014) | Check before forwarding |
| 2026-05-05 | `premium_type` on users needs the `identify.premium` scope | Request it only if used |
| 2026-07-16 | Resolved channels in interactions include `app_permissions` | Check per target channel |
| 2026-08-05 | `file_types` filter on ATTACHMENT options and File Upload components | Discord.Net 3.20.1: not yet (dev branch) |
| 2026-09-11 | Multiline string options; fuzzy autocomplete picker | — |
| 2026-09-15 | Large-bot sharding: `shard` param required on Get Current User Guilds | Only 150k+ guild bots |
| 2026-09-17/22 | Custom status hidden by profile privacy; age-assurance rollout | Don't rely on presence/custom status |
| **2026-11-16** | **Channel obfuscation mandatory** (gateway): channels the bot can't view arrive with name `___hidden___`, nulled fields, a single @everyone VIEW_CHANNEL deny overwrite and flag `CHANNEL_OBFUSCATED` (1<<17); `GET /guilds/{id}/channels` omits them (the HTTP API never sets the flag); interaction payloads are not obfuscated; full data arrives via `CHANNEL_UPDATE` when access is gained | Detect via the flag, never the name; don't rely on seeing every channel. Test early via the Portal toggle or Identify `capabilities` (1<<15) — the latter isn't exposed by Discord.Net 3.20.1 |
