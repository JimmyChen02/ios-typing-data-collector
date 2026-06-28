# process/ — Run Log

Append-only journal of significant runs so future agents inherit hard-won context
(what failed, why, and the fix) instead of rediscovering it.

## When to log
- A non-trivial build, analysis run, or refactor — especially if it errored.
- Anything that took more than one try, or revealed all non-obvious gotcha.

## How
Create one file per run: `YYYY-MM-DD-short-slug.md`. Suggested template:

```markdown
# <date> — <what you set out to do>

**Context:** branch, relevant files, goal.
**Attempted:** commands/changes made.
**Errors:** verbatim error + what caused it.
**Fix / outcome:** what resolved it, or what's still open.
**Notes for next agent:** gotchas, follow-ups.
```

Keep entries short and factual. Successes are worth logging too when they encode a
working recipe (e.g. exact xcodebuild invocation, working script flags).
