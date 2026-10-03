---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Solution builds with dotnet build (0 errors)
- Uses an HTTP interactions endpoint (no DiscordSocketClient / gateway connection)
- Verifies Ed25519 signature over the raw request body and returns 401 on failure, including malformed headers
- Answers PING with type 1
- Initial responses are returned in the HTTP body (RestInteractionModuleBase or direct Respond JSON) - no plain InteractionModuleBase whose responses are discarded
- Unknown commands / stale buttons are answered within 3 s (dispatch not awaited on the request path, or equivalent)
- When V2 components are used over REST, MessageFlags.ComponentsV2 is set explicitly
- Modal uses Label-based inputs (IModal attributes / AddTextInput), not deprecated ActionRow+TextInput rows
- Priority is constrained to low/medium/high (select menu/choice/enum), not free text
- Concurrent Claim presses on different replicas have exactly one winner (conditional update on shared store or equivalent), loser gets an ephemeral notice
- Claim updates the ticket card in place (UPDATE_MESSAGE) and shows who claimed it
- Setup guide covers Interactions Endpoint URL, Public Key, and single-runner command registration
- Includes signed end-to-end HTTP tests that pass
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
