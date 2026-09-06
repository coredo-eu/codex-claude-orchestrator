# Codex Claude Orchestrator

## Project family

- [codex-agent-config](https://github.com/coredo-eu/codex-agent-config) — Codex instructions and native specialist profiles.
- [claude-agent-config](https://github.com/coredo-eu/claude-agent-config) — standalone Claude Code instructions and specialist agents.
- [codex-claude-orchestrator](https://github.com/coredo-eu/codex-claude-orchestrator) — Codex plugin that delegates local tasks to Claude Code and returns results for Codex verification.

Together, these projects form the **COREDO agent tools family**: two
configuration packages and one installable Codex plugin. Use each on its own
or combine them. The orchestrator requires Claude Code, but does not require
`claude-agent-config`; it supplies its own worker instructions and roles.

## What it does

A Codex plugin that delegates a bounded coding task to Claude Code and brings
its result back to Codex for verification. You give Codex the outcome; Codex
decides whether delegation helps, gives Claude one local task, and checks the
changes before calling the work complete. Codex chooses the executor based
on the task and the cost of delegation. The plugin keeps track of which session owns the work so two agents do not
accidentally edit the same worktree.

| Component | Responsibility |
| --- | --- |
| Codex | Understands the request, chooses the executor, makes key decisions, and verifies the result. |
| Claude Code | Completes one delegated local stage, then returns its changes and evidence. |
| Optional specialists | Help with discovery, implementation, testing, or review when useful. |

Boundaries:

- One edit owner per worktree; a worker handoff returns control to Codex.
- Workers make local changes only. Commits, pushes, deployments, and other
  external actions stay with Codex and require the user's task to authorize
  them.
- The plugin only controls workers registered to the current Codex thread. It
  does not attach to standalone Claude sessions or change their settings.
- A kill switch stops new worker interactions. Recovery checks prevent
  another executor from taking over while the original worker may still be
  writing.

These controls are cooperative, not an operating-system sandbox. Use trusted
repositories and appropriate host permissions. Coordination runs locally;
model requests still go to OpenAI and Anthropic under your account settings.

## What's included

| Branch | Use it when |
| --- | --- |
| [`main`](https://github.com/coredo-eu/codex-claude-orchestrator/tree/main) | You want Claude to work directly with repository files, without an MCP dependency. |
| [`codeindexer`](https://github.com/coredo-eu/codex-claude-orchestrator/tree/codeindexer) | You use CodeIndexer and want guarded semantic search and dependency discovery. |

**This checkout is the `main` variant.** It does not enable MCP for Claude
workers. The branches are separate runtime variants — install the one you
need, and do not merge them.

The plugin keeps your selected Codex model and reasoning level. A Claude
worker starts with Sonnet 5 at high effort; its optional roles use Haiku,
Sonnet, Opus, or Fable. Native Codex fallback roles have their own model
settings. No task must use every role. See the
[skill](plugins/codex-claude-orchestrator/skills/claude-pty-agents/SKILL.md)
for the exact routes.

The [plugin manifest](plugins/codex-claude-orchestrator/.codex-plugin/plugin.json)
records the version shipped by this branch.

## Installation

You need Codex and Claude Code installed and authenticated, plus `zsh`, `jq`,
Git and the platform locking/process tools described in the skill. Use macOS
or Linux; Windows is not supported. The Codex tool shell must provide an
interactive PTY and `CODEX_THREAD_ID` — this integration depends on that host
behavior, which can change between Codex versions.

```sh
codex plugin marketplace add coredo-eu/codex-claude-orchestrator --ref main
codex plugin add codex-claude-orchestrator@codex-claude-orchestrator
```

For an existing marketplace checkout, confirm it is on `main` before
installing.

## Usage

Start a new Codex session after installation, then ask:

```text
Use $codex-claude-orchestrator:claude-pty-agents to fix this bug.
Give Claude one bounded task and verify its changes before finishing.
```

For automatic executor selection, merge the
[opt-in policy](plugins/codex-claude-orchestrator/skills/claude-pty-agents/references/codex-policy-snippet.md)
into your existing `AGENTS.md`. Installing the plugin alone does not change
your instructions or install the optional native agent profiles from
[codex-agent-config](https://github.com/coredo-eu/codex-agent-config).

## Validation

Run the deterministic checks without a real Claude session or credentials:

```sh
./scripts/self-check.zsh
```

The checks use temporary state and fake worker processes. CI runs them on
macOS and Linux; real CLI compatibility still depends on your installed
Codex and Claude Code versions.

## Further reading

- [Worker lifecycle, model routes, setup and recovery](plugins/codex-claude-orchestrator/skills/claude-pty-agents/SKILL.md)
- [Optional executor-selection policy](plugins/codex-claude-orchestrator/skills/claude-pty-agents/references/codex-policy-snippet.md)
- [Security and limitations](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [claude-agent-config](https://github.com/coredo-eu/claude-agent-config): configuration for standalone Claude Code.
- [codex-agent-config](https://github.com/coredo-eu/codex-agent-config): portable instructions and optional native specialist profiles.
