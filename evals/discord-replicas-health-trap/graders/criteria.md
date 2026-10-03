---
type: llm
weight: 3
focus: trace
---

Judge the whole session (code written, commands run, final answer). PASS only if every point holds:
- Explains that running the gateway bot in all 3 replicas causes multiple connections and duplicate/failed answers
- Chooses a fitting topology: separate single-replica bot worker, or HTTP interactions endpoint in the API
- Does not put Discord connection state into /health/live; uses /health/ready or a metric and explains the restart/identify risk
- /stats defers before the database query
- Database access is scoped per interaction (module constructor injection with AutoServiceScopes or IServiceScopeFactory), not a captured DbContext
- Solution builds with dotnet build (0 errors) and includes passing tests
Build/test claims count only if the trace shows the command and its successful output.
FAIL if any point is missing or contradicted.
