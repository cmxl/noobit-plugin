---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Solution builds with dotnet build (0 errors)
- Webhook Events endpoint verifies Ed25519 over the raw body and returns 401 for bad or malformed signatures
- PING (type 0) and events are answered 204 with an empty body (and a Content-Type header)
- Request body is size-capped while reading (not just a Content-Length check)
- Events are stored raw with a dedupe key (unique index) and processed asynchronously; unparseable-but-signed bodies are stored, not 500
- The EF Core inbox is resolved per request (RequestServices / scoped), not from the root provider or a singleton
- OAuth2 linking validates state (e.g. via the ASP.NET Core OAuth handler) and exchanges the code server-side without retrying the single-use code POST
- The callback does not depend on the SameSite=Strict session cookie: the local user is bound when the signed-in user starts the flow (e.g. AuthenticationProperties.Items / state), and the link is persisted only by an antiforgery-validated POST, never by the GET callback alone
- Discord access/refresh tokens never reach the browser; only the Discord user id is required to be stored
- Does not turn Discord into the app's login provider (linking only; login stays with the existing BFF)
- Includes automated tests (signed webhook event requests, dedupe) that pass
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
