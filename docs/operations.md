# CodeIndexer execution details

The [README](../README.md) covers installation and normal use. The
[skill](../plugins/codex-claude-orchestrator/skills/claude-pty-agents/SKILL.md) owns the complete transport and recovery procedure.

## CodeIndexer profile

New schema-6 workers accept only a credential-free loopback HTTP `/mcp` endpoint
from the `codeindexer` entry in the selected Claude profile. The default state
file is `$HOME/.claude.json`. Set `CODEX_CLAUDE_CONFIG_DIR` to an existing,
absolute, non-symlink configuration directory to select another profile; its
state file is then `$CODEX_CLAUDE_CONFIG_DIR/.claude.json`.

The launcher clears ambient `CLAUDE_CONFIG_DIR`, pins the selected profile, and
snapshots the endpoint. Resume uses the snapshot; assignment, resume, and
successor lineage reject a profile mismatch. Workers get only the allowlisted
read surface. Indexed conclusions still need verification in source.

## Native fallback routing

`task_name` names the task; `agent_type` selects the installed custom profile.
Missing or mismatched `agent_role` fails closed. With an explicit role,
`fork_turns=all` and the default are invalid; use `none` or a bounded numeric fork.
Do not use Claude's `subagent_type` field for native routing.

A role file is not proof that the runtime narrowed a child's sandbox. When the
parent policy is broader, use the isolated `run-native-agent.zsh` launcher with
the trusted user-level role. This variant exposes only pure read/search MCP tools
to that process. Follow the skill's custody and retirement checks before any
fallback writes; never run duplicate executors for the same outcome.

## Admission and task handoff

Normal launch reserves a canonical root and one busy slot before starting
Claude. Assignment atomically upgrades `access:none` to `access:write`.
`CODEX_CLAUDE_MAX_BUSY_WORKERS` defaults to 2 and accepts 1 through 7. Capacity is
a ceiling, not a target. One edit owner per worktree remains mandatory.

Each assignment has seven ordered fields: `Outcome`, `Done when`, `Boundaries`,
`Authoritative context`, `Non-goals`, `Known evidence`, and `Required handoff`.
A stage checkpoint may request a handoff; it neither completes the user's goal
nor transfers edit custody. Codex verifies the returned work and performs the
terminal lifecycle before handing the same outcome to another executor.
