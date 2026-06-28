# agents/ — Custom Subagent Definitions

Project-scoped subagents (Markdown files with YAML frontmatter) Claude Code can
invoke for this repo. One agent per file: `agent-name.md`.

```markdown
---
name: analysis-runner
description: Runs the Python cleaning/Gaussian pipeline and summarizes results.
tools: Bash, Read, Edit
---
System prompt: what the agent specializes in and how it should behave here.
```

Candidate agents for this project: an **ios-build** agent (build + parse xcodebuild
logs, update build_log.md) and an **analysis-runner** agent (drive `scripts/` and
interpret outputs). Add them when a workflow becomes repetitive.
