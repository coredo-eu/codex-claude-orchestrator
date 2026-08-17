# Opt-in Codex orchestration policy

Review and copy the block below into the applicable project `AGENTS.md`, or
adapt it for a personal policy. Plugin installation does not apply it. Keep the
policy narrow enough for your environment and preserve stricter existing rules.

```markdown
## Goal-aware programmatic tool batching

While an active goal is running, treat the goal and its verification criteria
as the persistent outer control loop. On each automatic continuation, choose
the next bounded stage from the evidence already available.

Within that stage, run already-known independent read-only,
`functions.exec`-eligible `tools.*` calls concurrently in one `functions.exec`
program. Use `Promise.allSettled` when partial results remain useful and inspect
every outcome; use `Promise.all` only when any failure invalidates the stage.
Bound every nested output and the outer program output, and emit only compact
evidence. Do not split otherwise batchable inspections across outer tool calls.

After the batch, return to model judgment before choosing the next stage. Keep
goal-control calls and state transitions, adaptive investigations,
waits/resumes, approvals, citation or native-artifact retrieval, and all
mutations direct and sequential.

A successful batch is not goal completion. Continue until the goal's actual
verification criteria are satisfied.

For Claude PTY observation, keep the kill-switch and retirement preflight plus
the dependent poll sequential inside one `functions.exec` program. While a
worker holds edit custody, do not duplicate that outcome in Codex; observation,
unrelated work, and later independent verification remain available.

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

The launcher admits at most two busy Claude assignments per HOME by default
(`CODEX_CLAUDE_MAX_BUSY_WORKERS` may be only `1` or `2`), and an active
write assignment serializes a canonical root. Admission occurs at assignment:
idle PTYs consume no busy capacity. A new launch also refuses a second live
worker in the same current Codex thread/root. It never adopts a foreign-thread
or standalone Claude session. A Codex-owned Claude worker
is permanently local-only and may not commit, push, publish, release, deploy,
control services, send external messages, administer the host, operate on
credentials, or perform destructive remediation. These restrictions bind the
worker, not the owning Codex session. After custody returns, Codex may perform
shared or external actions already authorized by the active goal and its
unambiguous scope. Codex asks the user only for a material scope expansion or
when the target or intended end state cannot be determined safely.

Treat `$HOME/.codex/claude-pty-agents.disabled` as the sole worker ON/OFF state.
Never launch, resume, assign, or poll a worker while it exists. Resume only the
same bounded outcome for a session whose UUID, canonical root, and registration were created by this exact
Codex thread; its lease is keyed by that UUID. Never resume, assign, rotate,
retire, or otherwise control a session belonging to another Codex thread, or a
user-launched standalone Claude session.

Each successful assignment owns one bounded stage. After a verified handoff,
Codex sends `/exit`, proves the named process group dead, and terminalizes that
same task through rotate or retire; no next-task reuse is permitted. Fallback transfers ownership; it never duplicates execution. Claude failure
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
The role file's sandbox is a default, not proof of a narrower child policy. If
the parent runtime is broader than the role, use the bundled isolated native
launcher, which validates the installed profile and starts `codex exec` with
that explicit sandbox. The isolation launcher trusts only the user-level role
copy whose contract matches the bundled template, never a repository-owned
profile. Never duplicate the same outcome across both paths.

Give an edit-capable worker a compact contract: Outcome, observable Done when,
Boundaries, Authoritative context, Non-goals, and Required handoff. Preserve
unrelated changes and expose no credentials, secret values, private transcripts,
or unnecessary personal data.
```
