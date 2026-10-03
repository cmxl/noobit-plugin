# Configuration & secrets

Verified against official documentation, October 2026 (learn.microsoft.com: configuration, app secrets, Key Vault configuration provider, Azure App Configuration .NET provider, data redaction, logging source generation). Extends `SKILL.md` → Configuration & DI (options pattern with `[OptionsValidator]` + `ValidateOnStart()` — not repeated here).

## Where each value lives

| Value | Development | Production (compose host) | Production (Azure) |
|---|---|---|---|
| Non-secret settings | `appsettings.json` / `appsettings.Development.json` | `appsettings.json` + environment variables | same, or Azure App Configuration |
| Secrets (connection strings with passwords, API keys, OAuth client secrets, signing certs) | **user-secrets** | **compose secrets** (files under `/run/secrets`) read with `AddKeyPerFile` — never environment variables, which leak via `docker inspect` | **Key Vault** (directly or via App Configuration Key Vault references), managed identity |

`appsettings*.json` and the repository never contain a secret — not even a "dev" one that happens to work against a shared environment.

Default `WebApplication` source order (later wins): `appsettings.json` → `appsettings.{Environment}.json` → user secrets (Development only) → environment variables → command line. Environment variables use `__` for `:` (`ConnectionStrings__Default`).

## Development — user secrets

```
dotnet user-secrets init --project src/App.Api
dotnet user-secrets set "ConnectionStrings:Default" "Host=localhost;Database=app;Username=app;Password=..." --project src/App.Api
```

Stored as plain JSON in the user profile (not encrypted) — a convenience for keeping secrets out of the repo, not a vault. Loaded automatically only when `Environment == Development`.

## Docker / compose — secrets as files

Compose `secrets:` mount each secret as a file under `/run/secrets/<name>`. Read them with the key-per-file provider instead of copying them into environment variables (which leak through `docker inspect`, crash dumps and child processes):

```csharp
// Microsoft.Extensions.Configuration.KeyPerFile ships in the ASP.NET Core shared framework —
// no PackageReference in a web app (adding one triggers NU1510)
// file name = key; "__" in the file name = section separator: ConnectionStrings__Default
builder.Configuration.AddKeyPerFile("/run/secrets", optional: true);
```

Add it after the defaults so the secret files override `appsettings`. Compose and image hardening: `docker`.

## Azure — Key Vault and App Configuration

```csharp
// Azure.Extensions.AspNetCore.Configuration.Secrets + Azure.Identity
// secret "ConnectionStrings--Default" becomes key "ConnectionStrings:Default"
if (!builder.Environment.IsDevelopment())
    builder.Configuration.AddAzureKeyVault(
        new Uri($"https://{builder.Configuration["KeyVaultName"]}.vault.azure.net/"),
        new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned));
```

- Production uses a **managed identity** (`ManagedIdentityCredential`); `DefaultAzureCredential` is the dev/test convenience (the docs recommend the explicit credential in production).
- One vault per app **and** environment — the docs advise against sharing a vault across apps or dev/prod via name prefixes.
- Secrets are cached for the app lifetime unless `AzureKeyVaultConfigurationOptions.ReloadInterval` is set; rotated secrets need a reload interval or a restart.
- Azure App Configuration (`AddAzureAppConfiguration(o => o.Connect(new Uri(endpoint), credential).ConfigureKeyVault(kv => kv.SetCredential(credential)))`) when many services share settings or need feature flags/dynamic refresh; secrets stay in Key Vault as Key Vault references.
- ASP.NET Core Data Protection keys are not configuration — they persist to the database and are protected with a certificate/Key Vault key (`bff-security`).

## Never log secrets or PII

Order of defenses — the first one carries the weight:

1. **Don't pass them to the logger.** Message templates name exactly what is logged (`"User {UserId} logged in"`); never log request/response bodies of auth endpoints, connection strings, tokens, `IConfiguration` dumps, or whole options objects.
2. **No `{@Destructured}` objects that may carry secrets.** Serilog's `@` serializes every public property. Log a projection (`{OrderId}`), or exclude sensitive types at the source: `.Destructure.ByTransforming<LoginRequest>(r => new { r.Email })`. Keep `ToString()` of options/credential types free of secret values.
3. **Framework logging stays redacted**: EF Core 10 redacts inlined constants by default — keep `EnableSensitiveDataLogging()` off outside local debugging; don't enable header/body logging (`AddHttpLogging`) for auth-relevant headers (`Cookie`, `Authorization`, `X-XSRF-TOKEN`).
4. **Classification + redaction** (`Microsoft.Extensions.Compliance.Redaction` + `Microsoft.Extensions.Telemetry`): annotate `[LoggerMessage]` parameters with data-classification attributes, register redactors with `services.AddRedaction(...)` and call `builder.Logging.EnableRedaction()`. This is documented for the Microsoft.Extensions.Logging pipeline; whether it still applies once Serilog replaces the logger factory (`AddSerilog`) is not documented — prove it with a test (`FakeLogger`/captured sink) before relying on it, and keep 1–2 as the guarantee.
5. **Telemetry**: span attributes and metric tags follow the same rule — no tokens, emails or ids in tag values (`observability.md`).

Exception messages count too: the global `IExceptionHandler` returns a generic ProblemDetails title; provider exceptions can embed connection details — log them server-side only.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Secret in `appsettings.Production.json` / committed `.env` | Key Vault, or compose `secrets:` files (kept outside the repo) + `AddKeyPerFile` |
| Secrets as plain compose `environment:` values | `secrets:` files + `AddKeyPerFile` |
| `DefaultAzureCredential` in production | `ManagedIdentityCredential` (explicit, no credential-chain probing) |
| One Key Vault for all apps/environments | Vault per app per environment |
| `_logger.LogInformation("Login {@Request}", request)` | Log `{Email}` at most — never the password-bearing object |
| `IConfiguration` injected and read ad hoc for secrets | Bound, validated options (SKILL.md) |

## Sources

- https://learn.microsoft.com/en-us/aspnet/core/fundamentals/configuration/?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/app-secrets?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/aspnet/core/security/key-vault-configuration?view=aspnetcore-10.0
- https://learn.microsoft.com/en-us/azure/azure-app-configuration/reference-dotnet-provider
- https://learn.microsoft.com/en-us/dotnet/core/extensions/data-redaction
- https://learn.microsoft.com/en-us/dotnet/core/extensions/logging/source-generation#redacting-sensitive-information-in-logs
- https://docs.docker.com/compose/how-tos/use-secrets/
- https://github.com/serilog/serilog/wiki/Structured-Data (destructuring)
