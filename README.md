# Codex Claude Orchestrator

[![CI](https://github.com/coredo-eu/codex-claude-orchestrator/actions/workflows/ci.yml/badge.svg)](https://github.com/coredo-eu/codex-claude-orchestrator/actions/workflows/ci.yml)

An installable Codex marketplace plugin for custody-aware, two-level local
delegation:

1. Codex stays the orchestrator and final verifier.
2. A persistent Claude Code parent handles one bounded repository outcome.
3. Claude routes supporting work to a least-cost role-specific model.
4. If Claude cannot safely continue, Codex transfers the unchanged contract to
   a small set of configurable native fallback roles.

The project is intentionally a transport and policy layer. It is not a daemon,
an agent platform, an operating-system sandbox, or an authority source.

```mermaid
flowchart TD
    U[User outcome and exact authority] --> C[Codex orchestrator]
    C -->|bounded contract + edit custody| O[Persistent Claude Code parent<br/>default: opus]
    O -->|search / logs / first triage| H[Haiku roles]
    O -->|implementation / debugging| S[Sonnet roles]
    O -->|review / security| P[Opus roles]
    O -->|exceptional long horizon| F[Fable role<br/>Opus parent fallback]
    H -->|distilled evidence| O
    S -->|bounded result| O
    P -->|independent findings| O
    F -->|verified handoff| O
    O -->|terminal handoff + custody return| C
    C -->|independent verification| U
    C -. Claude unavailable; no live writer .-> N[Native Codex fallback<br/>GPT-5.6 role map]
    N --> E[source_explorer / reviewer<br/>security_reviewer]
    N --> W[one mech_executor]
    N --> T[test_runner after custody return]
```

## Why this shape

The economic model is role-based, not a promise about a bill:

- Codex spends its highest-value context on intent, architecture, authority,
  conflicts, and the final verdict.
- One persistent Claude parent amortizes repository context and task setup over
  related follow-ups.
- A session-scoped roster maps discovery and triage to Haiku, ordinary coding
  and debugging to Sonnet, review to Opus, and exceptional long-horizon work to
  Fable with an Opus availability fallback.
- Native fallback maps each narrow role to Luna, Terra, or Sol instead of
  silently inheriting the main Codex session.
- Delegation is chosen only when context transfer, coordination, verification,
  and recovery still leave a net cost or elapsed-time benefit.

Parallel agents can consume more tokens than one agent, and model availability
depends on the user's plans and organization policy. This repository therefore
publishes no price table or savings percentage.

## Prompt design

The model prompts state the outcome, authority boundary, and evidence expected
at handoff, then explicitly leave method, decomposition, investigation, and
verification choices to the model. Routing descriptions explain when a role is
useful; tool allowlists and runtime controls enforce capabilities. Prompts do
not duplicate those mechanisms with a hand-written implementation plan.

This follows current guidance to keep strong-model prompts lean and
outcome-focused. Prescriptive steps remain appropriate only when order itself
is a real safety or protocol requirement. The self-check enforces compact
`Outcome` / `Boundary` / `Return` contracts so future edits do not quietly
restore procedural scaffolding.

## Status and prerequisites

Version `0.2.0` is an early, local-only release.

| Surface | Status |
| --- | --- |
| macOS with Claude Code 2.1.215 | Primary development target |
| Modern Linux with `zsh`, `jq`, Git, `flock`, and `/proc` | Lifecycle tested in CI with fake Claude; real CLI use should be validated locally |
| Windows / PowerShell | Not supported in v0.2 |
| Codex surfaces exporting `CODEX_THREAD_ID` to tool shells | Required |
| Codex surfaces without `CODEX_THREAD_ID` | Unsupported; launcher fails closed |

`CODEX_THREAD_ID` is a compatibility-sensitive host contract, not a stable
public Codex API documented for third-party launchers. Run the preflight after
Codex upgrades and expect this integration point to require maintenance.

Required:

- a supported Codex surface with marketplace plugins and interactive PTYs;
- Claude Code installed and authenticated by the user;
- `zsh`, `jq`, Git, `ps`, `sed`, `awk`, `tr`, and a SHA-256 utility;
- `lockf` on macOS or `flock` on Linux;
- `lsof` on macOS, or `/proc/<pid>/cwd` on Linux, for process-cwd identity;
- access to the configured Claude and Codex models.

The launcher requires these Claude flags: `--model`, `--agents`, `--session-id`,
`--resume`, `--name`, `--settings`, `--setting-sources`, `--strict-mcp-config`,
`--append-system-prompt-file`, and `--disallowedTools`. It never bypasses the
first-launch repository trust dialog; that choice belongs to the user.

Useful preflight from the Codex tool shell:

```zsh
test -n "${CODEX_THREAD_ID:-}" || print -u2 -- "CODEX_THREAD_ID is unavailable"
command -v claude jq zsh git
claude --version
claude --help | rg -- '--agents|--model|--settings|--setting-sources|--strict-mcp-config|--session-id|--resume|--disallowedTools'
```

## Install from the Git marketplace

```text
codex plugin marketplace add coredo-eu/codex-claude-orchestrator
codex plugin add codex-claude-orchestrator@codex-claude-orchestrator
```

For a local clone:

```text
codex plugin marketplace add /absolute/path/to/codex-claude-orchestrator
codex plugin add codex-claude-orchestrator@codex-claude-orchestrator
```

Start a new Codex thread after installation so the bundled skill is discovered.
Plugin activation does not edit `AGENTS.md`, native agent configuration, Claude
settings, or authentication.

## Opt in to Claude-first selection

Installing a skill makes the transport available; it does not make a durable
executor-selection policy. Review
[`codex-policy-snippet.md`](plugins/codex-claude-orchestrator/skills/claude-pty-agents/references/codex-policy-snippet.md)
and manually adapt it into the applicable project `AGENTS.md` if you want Codex
to prefer this path. The snippet is generic and cannot weaken stricter project
or organization policy.

Do not automate this copy. `AGENTS.md` may already encode authority and safety
rules that need a human merge.

## Use

Ask Codex to use the bundled skill for a bounded local outcome:

```text
Use $claude-pty-agents to implement this bounded change. Keep Codex as the
authority owner and independently verify Claude's handoff.
```

Codex should provide a compact contract with `Outcome`, observable `Done when`,
`Boundaries`, `Authoritative context`, `Non-goals`, and `Required handoff`. The
skill handles launch/reuse, task transport, terminal handoff, and safe fallback.

Parent default and non-secret override:

```zsh
# Defaults shown explicitly; export only when changing them.
export CODEX_CLAUDE_PARENT_MODEL=opus
```

The parent model is passed with `claude --model`. The role roster is passed with
`--agents` from a private runtime snapshot. A `PreToolUse` hook rejects unlisted
roles and mismatched per-invocation model overrides. The launcher also clears
inherited `CLAUDE_CODE_SUBAGENT_MODEL` and legacy
`CODEX_CLAUDE_SUBAGENT_MODEL` values because Claude gives a global override
higher precedence than per-role definitions. The worker hook prevents another
delegation layer.

### Claude role routing

| Claude role | Model | Intended work |
| --- | --- | --- |
| `explorer` | Haiku | file search, source facts, bounded discovery |
| `log-analyzer` | Haiku | logs, test output, classification |
| `test-triager` | Haiku | first pass over failures |
| `implementer` | Sonnet | ordinary bounded implementation |
| `debugger` | Sonnet | multi-step diagnosis without source edits |
| `reviewer` | Opus | complex regressions and architecture review |
| `security-reviewer` | Opus | security, authorization, and concurrency |
| `long-horizon` | Fable | exceptionally large autonomous outcomes only |

Claude Code inherits the Opus parent when Fable is outside the account's
allowed model set. If Fable fails for another availability reason, the parent
retains the outcome instead of silently routing it to a cheaper role. The
roster deliberately denies built-in Explore, Plan, general-purpose,
statusline-setup, and claude-code-guide agents. A runtime hook rejects unlisted
roles and any per-invocation model override that disagrees with the published
map. Read-only roles receive Bash under Claude Code's `plan` permission mode so
they can choose useful diagnostics without receiving normal edit capability.

### Optional native roles

Codex plugins do not install custom Codex agent files on their own. Preview the
bundled templates first:

```zsh
SKILL_DIR=/absolute/path/to/installed/claude-pty-agents
"$SKILL_DIR/scripts/setup-native-agents.zsh" \
  --target project \
  --root /absolute/project/root
```

The default is dry-run. `--apply` asks for confirmation; `--apply --yes` is the
explicit non-interactive form. A pre-existing target, including a dangling
symlink, is refused. Final paths are created atomically without replacement; a
concurrent late collision can leave an earlier role installed, but never
overwrites the colliding entry. Choose `--target user` only when these roles
should be personal defaults across repositories. A uniform model can be
selected with `--model` or `CODEX_NATIVE_AGENT_MODEL`. A repeatable
`--role-model role=model` overrides one role and takes precedence over a
uniform override.

The templates are:

- `source_explorer` — read-only source reconstruction;
- `reviewer` — read-only correctness and regression review;
- `security_reviewer` — read-only focused security review;
- `mech_executor` — the sole bounded edit owner after explicit custody transfer;
- `test_runner` — write-capable verification only after edit custody returns or
  in an isolated root.

| Native role | Default model | Reasoning effort |
| --- | --- | --- |
| `source_explorer` | `gpt-5.6-luna` | `medium` |
| `test_runner` | `gpt-5.6-luna` | `low` |
| `mech_executor` | `gpt-5.6-terra` | `medium` |
| `reviewer` | `gpt-5.6-terra` | `high` |
| `security_reviewer` | `gpt-5.6-sol` | `high` |

The Codex orchestrator inherits the model of the main Codex session; this
plugin never pins it.

## Authority and custody boundaries

| Actor | Owns | Must not do without separate authority |
| --- | --- | --- |
| User | Desired outcome and exact authorization | Nothing is inferred from tool availability or old handoffs |
| Codex orchestrator | Material architecture or product tradeoffs, executor choice, authority expansion, conflicts, independent verification, final verdict | Treat a worker handoff as completion or control standalone Claude |
| Codex-owned Claude parent | One bounded local lifecycle in one canonical root | Commit, push, publish, deploy, service control, external messages, host administration, credential operations, destructive remediation, config changes |
| Claude subagent | One role-specific supporting package; only implementer or long-horizon can receive edit custody | Expand authority, overlap another writer, recursively delegate, write coordination state |
| Native fallback | The same unchanged contract after verified transfer | Overlap a live Claude writer or resume a retired assignment |

One canonical worktree has one edit-capable owner. The launcher creates an
atomic lease keyed by the canonical root and a durable registration bound to a
hash of the current Codex thread. The raw thread identifier is not stored.

A live worker receives a private per-session runtime snapshot with directory
mode `0700` and file modes `0600`/`0700`: generated settings, worker prompt,
subagent context hook, agent-routing hook, exact roster, model choices, schema
version, and runtime version. This prevents a marketplace update from changing
those inputs underneath a live process.
Task bodies are sent through the PTY, never process arguments.
The `--agents` process argument contains only the static roster policy, never a
task body, repository path, thread identifier, or credential.

## Disable, fallback, and recovery

The only enabled/disabled state is:

```text
$HOME/.codex/claude-pty-agents.disabled
```

From the installed skill directory:

```zsh
./scripts/toggle-agents.zsh status
./scripts/toggle-agents.zsh off
./scripts/toggle-agents.zsh off --stop
./scripts/toggle-agents.zsh on
```

`off` blocks launch/resume in the runtime and makes a conforming Codex
orchestrator refuse assignments and polls at its next preflight, without killing
a process. That preflight is not atomic with the external PTY call, so a call
already in flight may finish after `off` returns. `off --stop` additionally
sends `TERM` to isolated process groups backed by durable registrations and
verified live leases, then fails closed if a registered group remains.
Standalone Claude is never discovered by name and never targeted.

Native fallback is an ownership transfer:

1. stop input to Claude and obtain a clean terminal handoff;
2. prove the registered process group is empty and edit custody has returned;
3. run `retire-native-fallback.zsh <root> <uuid> <task-id>`;
4. begin native writes only after the retirement marker succeeds.

Retirement holds the global gate, validates thread/root/UUID registration,
checks leases, durable registrations, the process table, and every overlapping
registered process group. A retired UUID cannot be resumed. These are
cooperative controls, not proof against a process deliberately detached from its
group; after a crash, lost PTY, or ambiguous identity, stay read-only or use an
isolated worktree.

Version `0.2.0` creates runtime schema 2. A schema-2 resume reuses the original
roster snapshot even after plugin updates. Published schema-1 registrations can
still resume with their original single-subagent-model snapshot; they are never
silently converted to the new routing. Unversioned legacy registrations are not
adopted.

## Uninstall and state cleanup

1. Run `off --stop` and verify no registered worker remains.
2. Uninstall the plugin through `/plugins` in Codex CLI or the supported plugin
   UI, then start a new Codex thread.
3. Remove the marketplace only if no other installed plugin depends on it.
4. Native role files are outside plugin lifecycle. Remove only the exact files
   you previously installed, and only after reviewing that they were not edited.
5. Inspect `$HOME/.codex/claude-pty-sessions` and
   `$HOME/.codex/claude-pty-leases` before deleting any retired/stale state. Do
   not use a broad recursive deletion against `$HOME` or `$HOME/.codex`.

The runtime stores registrations, leases, model names, generated settings, and
retirement metadata in the user's Codex state directory. Claude Code may store
its own transcripts, history, and diagnostics according to its product
behavior. This plugin does not upload that data or print task bodies itself, but
it is not a log-prevention or data-loss-prevention system.

## Threat model

Designed to resist accidental overlap and common authority drift:

- canonical-root leases prevent two registered writers in overlapping scopes;
- current-thread registration prevents UUID-only resume;
- retirement makes native transfer non-resumable and fails closed on a live
  process;
- a global gate serializes launch, disable, and retirement state transitions;
- generated settings deny common configuration edits and the CLI denies common
  external, destructive, publication, and service-control commands;
- setting sources are empty and no MCP servers are enabled for the worker;
- inherited global subagent-model overrides are removed for schema-2 workers;
- built-in Claude agents are denied, and a pre-spawn hook rejects unlisted
  roles or mismatched model overrides;
- runtime snapshots are private to the local user and contain no task body or
  credential by design.

Not defended as an OS security boundary:

- a malicious or compromised repository, shell tool, hook, Claude/Codex binary,
  dependency, or same-user process;
- Bash variants that evade string-based deny rules;
- read-only roles retain Bash under `plan` mode; a parent permission mode that
  takes product-defined precedence can weaken that boundary;
- per-role routing is enforced by a same-user hook, not an OS or account-level
  boundary;
- network egress allowed by the host sandbox;
- credentials already present in inherited environment variables or readable
  files;
- tampering by another process running as the same OS user;
- PID/cwd inspection unavailable on an unsupported platform;
- product changes to undocumented `CODEX_THREAD_ID` behavior.

Use only trusted repositories, run Codex with least-privilege sandbox and
network policy, keep secrets out of task contracts, and review generated runtime
state before sharing diagnostics. The first Claude trust dialog and any later
approval remain user decisions; the launcher does not answer them.

## Verification

The self-check uses a clean temporary home and fake Claude process. It verifies
manifest structure, shell syntax, exact role routing, snapshot permissions,
clean-profile argv/environment, concurrent writer rejection, fail-closed live
retirement, retired resume rejection, kill-switch behavior, native installer
safety, and absence of private paths or credential-shaped data.

```zsh
./scripts/self-check.zsh
```

GitHub Actions runs the same checks without Claude/Codex credentials or network
calls to either product.

## Official documentation

- [Codex plugins](https://learn.chatgpt.com/docs/plugins)
- [Codex custom subagents and agent files](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents)
- [OpenAI GPT-5.6 prompting best practices](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Claude Code subagents and model precedence](https://code.claude.com/docs/en/sub-agents)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Anthropic prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)
- [Anthropic prompting Claude Fable 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5)

## License

MIT. See [LICENSE](LICENSE).

This is an independent project and is not affiliated with or endorsed by OpenAI
or Anthropic. Codex, Claude, and Claude Code are trademarks of their respective
owners.
