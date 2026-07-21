---
name: claude-pty-agents
description: Launch, reuse, and safely retire persistent Claude Code workers owned by the current Codex thread, with an Opus parent, role-routed Haiku/Sonnet/Opus/Fable subagents, read-only loopback CodeIndexer discovery, and GPT-5.6 native Codex fallback. Use when Claude is requested, when continuing a Codex-owned Claude outcome, or when bounded repository work benefits from context isolation or a long autonomous lifecycle. Do not use for routine known-file work, user-launched standalone Claude, or environments without an interactive PTY.
---

# Claude PTY agents

Use persistent Claude Code processes owned by this Codex thread. Launch as many
as the work needs, including several in one canonical worktree; the launcher
imposes no limit and never refuses a launch because another Claude process or
registered worker shares the root. Keep Codex as the owner of intent, material
architecture or product tradeoffs, authority, conflicts, independent
verification, and the final verdict. Treat this skill as transport and custody
policy, never as additional authority.

## Contract and boundaries

Give an edit-capable worker one compact contract:

- `Outcome`: state that must become true.
- `Done when`: observable acceptance criteria.
- `Boundaries`: exact root, side effects, prohibited actions, and ownership.
- `Authoritative context`: applicable source-of-truth material and unknowns.
- `Non-goals`: adjacent work not to absorb.
- `Required handoff`: material evidence, risk, uncertainty, missing authority,
  deliberate non-actions, and custody needed for Codex to decide.

The worker is permanently local-only. It cannot commit, push, publish, deploy,
control services, send external messages, administer the host, operate on
credentials, modify Claude/Codex configuration, or perform destructive
remediation. Such work requires separate Codex review and exact current-user
authorization.

The launcher enforces session ownership, not worktree exclusivity: it guarantees
that no thread steers a session it did not register, but it does not serialize
writers. When you run more than one edit-capable worker in a worktree, give each
one a non-overlapping edit scope yourself — nothing below will detect or prevent
two siblings editing the same files. Never resume, assign, rotate, retire, or
otherwise adopt a session registered by another Codex thread, or any standalone
Claude the user started.

The generated settings, deny rules, prompt, and hook are cooperative controls,
not an OS sandbox. Bash or a malicious repository instruction can bypass path
rules. Use Codex sandbox/approval policy, source review, and least privilege as
the actual containment boundary.

## Start or resume

Resolve this skill's directory, then check prerequisites and status:

```text
<skill-dir>/scripts/toggle-agents.zsh status
command -v claude jq zsh git
```

The file `$HOME/.codex/claude-pty-agents.disabled` is the sole ON/OFF state.
Check it before every launch, resume, assignment, and PTY poll. Do not remove it
unless the user explicitly asks to enable workers.

Launch only a narrow absolute project root, with an interactive PTY:

```javascript
const worker = await tools.exec_command({
  cmd: "exec <skill-dir>/scripts/launch-worker.zsh /absolute/project/root",
  workdir: "/absolute/project/root",
  yield_time_ms: 1000,
  max_output_tokens: 8000,
  tty: true,
});
```

The launcher requires `CODEX_THREAD_ID` and defaults the parent to `opus`.
Override only the parent with a non-secret process variable:

```text
CODEX_CLAUDE_PARENT_MODEL=<alias-or-model-id>
```

The launcher passes a private session-scoped `--agents` roster. Explorer,
log-analyzer, and test-triager use Haiku; implementer and debugger use Sonnet;
reviewer and security-reviewer use Opus. Long-horizon uses Claude's official
Fable model. When Fable is outside the account's allowed model set, Claude Code
inherits the Opus parent; for other availability failures, the parent retains
the outcome. Built-in agents are denied, and a pre-spawn hook rejects unlisted
roles or mismatched model overrides. Read-only roles receive Bash in `plan`
mode when the parent permission mode permits that override. The default parent
starts in Claude Code Auto Mode to avoid manual approval queues; current Claude
Code versions make subagents inherit parent Auto Mode, so their remaining
read-only boundary is the role contract and absence of Edit/Write tools, not an
OS-enforced Bash sandbox. The launcher explicitly removes inherited
`CLAUDE_CODE_SUBAGENT_MODEL` and the legacy `CODEX_CLAUDE_SUBAGENT_MODEL`
convention because either would collapse the role-specific routing.

The launcher loads no user/project/local settings sources and does not edit
standalone Claude configuration. A new schema-4 worker extracts only the exact
credential-free loopback CodeIndexer entry from `$HOME/.claude.json`, snapshots
it privately, and guards its MCP tools with a read-only allowlist. Resume uses
that snapshot without rereading the global file. It remains optional; direct
source inspection is equally valid. Claude Code may show a
repository trust dialog on the first launch; the user must decide it
interactively. Never bypass it.

Keep the returned PTY `session_id` together with the exact UUID, name, root, and
lease from the JSON object after `CODEX_PTY_WORKER_READY`. Reuse only that
current-thread mapping.
Never use bare `claude -c`, an unqualified `--resume`, or another session.

Resume a dead, registered worker only after validating the same thread/root and
confirming no native transfer:

```text
<skill-dir>/scripts/launch-worker.zsh /absolute/project/root --resume <exact-uuid>
```

## Assign and observe

Wait for the interactive prompt, then run the assignment gate:

```text
<skill-dir>/scripts/assign-worker.zsh <root> <uuid> <task-id>
```

If it exits `76`, decide whether the current parent remains useful. To continue,
rerun once with `--continue-current-context`; that decision remains valid until
the next completed compaction. Otherwise rotate only after terminal handoff,
custody return, and process-group death:

```text
<skill-dir>/scripts/rotate-worker.zsh <root> <uuid> <task-id> \
  --handoff <ready_for_verification|blocked> --custody-returned
<skill-dir>/scripts/launch-worker.zsh <root> --successor-of <uuid>
```

If the gate exits `70`, the observer state is not trustworthy. Do not delete
its pending marker or continue the parent; use the same handoff, shutdown, and
rotation boundary.

The old UUID is then non-resumable and each registered successor attempt records
its lineage without preventing a retry after a failed launch.
Claude Code still owns compaction; the runtime counts completed `PostCompact`
events without retaining their summaries.

After a successful gate, immediately recheck the kill switch and retirement
marker, then send one task body without putting it in a process argument.
Submit multiline content and the final carriage return separately.

```text
TASK_ID: <unique-id>

Outcome:
Done when:
Boundaries:
Authoritative context:
Non-goals:
Known evidence:
Required handoff:

Work autonomously inside this contract. Preserve unrelated changes. Stop only
when ready for independent verification, genuinely blocked, or missing a
material decision or authority. Return one terminal marker after the handoff
and custody return:
CODEX_HANDOFF_READY <TASK_ID> <ready_for_verification|blocked>
```

Before every poll or other `write_stdin`, including an empty poll, recheck the
kill switch and confirm the registration
has no `retirement.json`. This is a cooperative
preflight, not an atomic lock around the external PTY call: a call already in
flight may finish after `off` returns. A retired UUID receives no new input.
Accept a handoff only when the task/state marker matches, the full evidence
precedes it, the prompt returns, all edit/card/phase custody returns, and no
delegated writer or background child remains. Independently inspect the
artifacts and choose evidence that resolves material uncertainty around `Done
when`.

## Native fallback

Fallback transfers ownership; it never duplicates execution. Use it when the
kill switch is active, Claude/PTY is unavailable, capacity prevents useful work,
or the exact worker cannot be recovered.

1. Require a clean terminal handoff and prove edit custody has returned. The
   process-group checks catch same-group descendants, but cooperative policy is
   not proof against a deliberately detached daemon. After a crash or ambiguous
   PTY loss, keep native work read-only or move it to an isolated root.
2. Retire the current registration; the script refuses while that exact session
   is still live. It does not check sibling workers, so confirm yourself that no
   other worker is writing this root before native work begins:

   ```text
   <skill-dir>/scripts/retire-native-fallback.zsh <absolute-root> <uuid> <task-id>
   ```

3. Transfer the unchanged outcome and boundaries to one bounded native owner.
   Add read-only explorer/reviewer roles or a post-custody test runner only when
   they materially improve confidence.

### Native routing gate

Native Codex roles are a separate routing surface from Claude subagents. For a
native dispatch, `task_name` is only a semantic instance identifier (for
example, `authz_source_discovery`); it never selects a profile. Select an
installed custom native profile with the mandatory `agent_type` field, such as
`source_explorer`, `mech_executor`, or `test_runner`. Claude's corresponding
field is `subagent_type`; do not substitute it for native routing.

```json
{
  "task_name": "gateway_minimal_reuse_audit",
  "agent_type": "source_explorer",
  "fork_turns": "none",
  "message": "<bounded outcome, context, evidence, and handoff>"
}
```

When an explicit native `agent_type` is used, set `fork_turns` to `none` or a
bounded numeric value. `fork_turns=all` and its default are incompatible with
an explicit role because a full-history fork inherits the parent role, model,
and effort. Do not use an omitted `agent_type` as a fallback: it selects the
platform default rather than an installed custom profile.

Before transferring any custody, fail closed unless the dispatch receipt has a
non-empty `agent_role` exactly equal to the requested `agent_type`. A missing
or mismatched role, or a model/effort mismatch against the selected profile,
means stop the child: no task assignment and no edit custody transfer. This gate
protects the native profile contract; sandbox inheritance is a separate runtime
limitation and is not corrected by configuration.

The custom-agent `sandbox_mode` is a role default, not proof that a child was
narrowed below the parent turn. A built-in child inherits the parent turn's live
sandbox policy. Use it only when the observed child policy is no broader than
the selected role profile.

When the parent policy is broader, or the current native tool surface rejects
`agent_type`, run the role as a separate non-interactive Codex process instead:

```text
print -r -- "<bounded task>" | \
  <skill-dir>/scripts/run-native-agent.zsh source_explorer <absolute-root>
```

The launcher reads only a regular, non-symlink user-level role profile and
requires its role contract to match the bundled template; a repository-owned
profile is not a trusted isolation authority. Install the trusted copy with
`setup-native-agents.zsh --target user`. The selected model remains the model
explicitly installed in that profile. The launcher passes the task only on stdin and uses
`codex exec --ignore-user-config` with an explicit `--sandbox`, disables hooks,
apps, web search, and nested agents, and refuses `danger-full-access`. Its output
is evidence awaiting Codex verification; it is not a child thread or a custody
transfer receipt. Never run this isolated path and a built-in child for the same
outcome. This branch also injects the same validated loopback CodeIndexer
endpoint with an MCP `enabled_tools` allowlist containing only pure read/search
operations plus an explicit deny-list for the remaining known server tools.
Those allowlisted reads are pre-approved for non-interactive use;
mixed-action management tools are not exposed to the native role. Before launch,
the owning Codex should resolve the exact registered CodeIndexer project name and
include it in the bounded task. If that name is unavailable, the role uses
ordinary source tools instead of guessing or requesting management tools.

Optional native role templates are installed separately and never by plugin
activation. Preview first:

```text
<skill-dir>/scripts/setup-native-agents.zsh --target project --root <absolute-root>
```

Use `--apply` for interactive confirmation or `--apply --yes` after reviewing
the dry run. Existing role files are never overwritten. Defaults are
role-specific:

```text
source_explorer=gpt-5.6-luna   test_runner=gpt-5.6-luna
mech_executor=gpt-5.6-terra    reviewer=gpt-5.6-terra
security_reviewer=gpt-5.6-sol
```

Use `--model <model>` or `CODEX_NATIVE_AGENT_MODEL` only for an intentional
uniform override. Use repeatable `--role-model <role=model>` for targeted
overrides; role overrides take precedence over a uniform override. The Codex
orchestrator always inherits the main session model and is never pinned here.

To make Claude-first selection durable, review and manually adopt the opt-in
policy in [references/codex-policy-snippet.md](references/codex-policy-snippet.md).
The plugin never edits `AGENTS.md`.

## Disable and recover

`toggle-agents.zsh off` creates the kill switch without terminating processes;
conforming Codex transport refuses calls after its next preflight, while an
already-started PTY call may complete. `off --stop` additionally sends `TERM` to
isolated process groups whose live parent identity is verified through this
runtime's leases, then fails closed if a registered group remains. `on` requires
an explicit user action. These operations never discover or target standalone
Claude by process name.

If a PTY handle is lost, do not guess one. Recover only from the exact durable
current-thread registration after the prior process is proven dead. If identity
cannot be proven, keep native agents read-only or use an isolated worktree until
the ambiguity is resolved.
