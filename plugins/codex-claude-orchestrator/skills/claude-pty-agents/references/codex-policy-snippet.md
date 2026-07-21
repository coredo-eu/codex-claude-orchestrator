# Opt-in Codex orchestration policy

Review and copy the block below into the applicable project `AGENTS.md`, or
adapt it for a personal policy. Plugin installation does not apply it. Keep the
policy narrow enough for your environment and preserve stricter existing rules.

```markdown
## Codex-to-Claude executor policy

Codex owns user intent, architecture, material tradeoffs, authority expansion,
conflict resolution, independent verification, and the final verdict. Workers
return evidence; they do not declare the user's outcome complete.

Choose the executor that minimizes end-to-end model cost and elapsed time while
preserving correctness, required evidence, safety, authority, and custody. For a
bounded work package where delegation has net value, prefer the persistent
Codex-owned Claude worker provided by
`$codex-claude-orchestrator:claude-pty-agents`. Keep work in Codex
when orchestrator judgment is material or delegation overhead, risk, or
unavailability removes that value.

Use one edit-capable owner per canonical worktree. A Codex-owned Claude worker
is permanently local-only and may not commit, push, publish, release, deploy,
control services, send external messages, administer the host, operate on
credentials, or perform destructive remediation. Each such action requires
separate, exact current-user authorization and Codex review.

Treat `$HOME/.codex/claude-pty-agents.disabled` as the sole worker ON/OFF state.
Never launch, resume, assign, or poll a worker while it exists. Reuse only the
PTY, UUID, canonical root, lease, and current-thread registration created by
this Codex thread. Never control a user-launched standalone Claude session.

Fallback transfers ownership; it never duplicates execution. Claude failure
changes the executor, not the outcome or authority. Before a
native fallback writes, prove the exact Claude worker is dead, return edit
custody, and retire its registered assignment with the bundled retirement
script. Never duplicate execution. Use the smallest useful native topology:
read-only exploration or focused review, one bounded edit owner, and a test
runner only after edit custody returns or in an isolated root.

For a role-routed native Codex child, treat `task_name` only as the semantic
task identifier and pass the exact custom profile through `agent_type`. Use
`fork_turns: "none"` or a bounded numeric fork; a full-history `"all"` fork
inherits the parent role/model/effort. Verify exposed `agent_role` and expected
model/effort before transferring custody. Missing, rejected, null, or mismatched
role metadata fails closed; renaming `task_name` is not a routing fallback.

Give an edit-capable worker a compact contract: Outcome, observable Done when,
Boundaries, Authoritative context, Non-goals, and Required handoff. Preserve
unrelated changes and expose no credentials, secret values, private transcripts,
or unnecessary personal data.
```
