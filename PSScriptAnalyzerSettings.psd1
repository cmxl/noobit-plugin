@{
    Severity     = @('Error', 'Warning')
    # Hooks are fail-soft by design: an error inside a hook must never block or break the
    # Claude Code session, so their top-level try/catch blocks are intentionally empty.
    ExcludeRules = @('PSAvoidUsingEmptyCatchBlock')
}
