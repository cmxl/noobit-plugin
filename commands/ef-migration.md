---
description: Add an EF Core migration safely — generate, review the SQL for destructive operations, verify against a real database
argument-hint: "<MigrationName>"
---

Add an EF Core migration named "$ARGUMENTS" (PascalCase; if blank, derive a name from the pending model change and tell me which). Load `noobit:data-access` and the matching provider skill (`noobit:mssql` / `noobit:postgres` / `noobit:sqlite`) first.

1. **Locate** the DbContext project and the startup project (the API host). If several contexts exist, pick the one whose model changed and say so.
2. **Confirm there is a change**: `dotnet ef migrations has-pending-model-changes` (project + startup project flags). No pending change → say so and stop.
3. **Add**: `dotnet ef migrations add <Name>`. Read the generated migration and the model snapshot diff.
4. **Review the SQL**: `dotnet ef migrations script <previous> <Name> --idempotent` (`<previous>` is `0` for the first migration) and inspect it for:
   - data loss — `DROP COLUMN`/`DROP TABLE`, column type narrowing, renames emitted as drop + add (fix with `RenameColumn`/`RenameTable` in the migration);
   - blocking DDL on large tables — non-nullable column without a default, index builds that should be online/concurrent (provider skill), table rebuilds (SQLite);
   - deploy order — the old app version must keep working against the new schema while replicas roll (expand → migrate data → contract across separate releases).
   Report each risk with the line and the mitigation you applied or propose. Any data loss → stop and ask me before going on.
5. **Verify**: run the integration tests (they apply migrations to a Testcontainers database — start Docker if needed per `noobit:dotnet-testing`), and confirm `has-pending-model-changes` is now clean.
6. **Docs**: if the schema change alters the documented data model, update `docs/data-model.md` per `noobit:docs-maintenance`.

Report: migration files, the risk review, test results. Do not commit.
