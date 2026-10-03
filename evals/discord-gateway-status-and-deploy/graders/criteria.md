---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Solution builds with dotnet build (0 errors)
- Uses Discord.Net InteractionService modules instead of a hand-rolled SlashCommandExecuted dispatcher
- Event handlers are subscribed once (not inside Ready) and command registration is guarded to run once per process
- Gateway intents are minimal (no GatewayIntents.All / privileged intents)
- Status card uses Components V2 (ComponentBuilderV2 / ContainerBuilder) with the V2 flag on deferred edits
- Refresh button edits the same message (UpdateAsync or deferred update + ModifyOriginalResponseAsync) and works after a restart (stateless custom id)
- /status defers before awaiting the health reporter
- Deployment endpoint enqueues for a background publisher; does not await Discord inline
- Posted deployment message uses AllowedMentions.None
- A rejected/rotated token fails startup (REST check after LoginAsync) and fatal gateway close codes (4004, 4010-4014) stop the host
- Pipeline retries of the same deployment id do not post twice
- Failed interactions get a user-facing reply (InteractionExecuted handler)
- Automated tests cover the Discord-facing code (cards/routing/publisher), not only the HTTP endpoint
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
