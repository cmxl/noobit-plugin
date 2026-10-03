---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Identifies handler subscription inside Ready as the cause of duplicate command execution
- Identifies missing defer before the slow /report query as the cause of 'did not respond'
- Explains the token-rotation behaviour (LoginAsync only checks format; Discord.Net reconnects on 4004) and the fix fails fast or stops the host
- Identifies the Trace-only log bridge and maps LogSeverity to proper log levels with the exception passed through
- Flags GatewayIntents.All (privileged intents) and reduces intents
- Flags the 25 embed-field limit in /report
- Flags that /weather builds the URL from raw user input ($"/current?city={city}") and fixes it with Uri.EscapeDataString (or an equivalent encoder/allow-list)
- Flags that /weather awaits an outbound HTTP call before responding and defers it (or otherwise guarantees the 3 s acknowledgement)
- Adds a user-facing error reply instead of only logging
- Fixed project builds with dotnet build (0 errors)
- Fixed code subscribes handlers once and registers commands at most once per process
- Ships automated tests for the fixes (e.g. fatal close-code classification, severity mapping, embed limits) that pass
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
