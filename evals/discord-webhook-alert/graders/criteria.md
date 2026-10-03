---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Solution builds with dotnet build (0 errors)
- Uses a channel webhook (DiscordWebhookClient or webhook URL POST) - no bot token, no DiscordSocketClient
- Webhook URL comes from configuration/secrets, not code, and is treated as a secret (not logged)
- Posting happens off the job's critical path (queue/background) and a Discord outage cannot fail the job
- Message uses AllowedMentions.None (or equivalent) so error text cannot ping
- Only link buttons / plain links - no interactive components on a webhook the app doesn't own
- Error summary is truncated to Discord limits
- Includes automated tests that pass
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
