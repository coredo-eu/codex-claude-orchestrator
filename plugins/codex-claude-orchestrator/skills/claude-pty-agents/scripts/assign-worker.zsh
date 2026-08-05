#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: assign-worker.zsh <absolute-worktree-root> <worker-uuid> <task-id> [--continue-current-context]"
  exit 64
}

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"

(( $# == 3 || $# == 4 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage
cco_is_uuid "$2" || usage
cco_is_short_text "$3" 200 || usage
continue_context=0
if (( $# == 4 )); then
  [[ "$4" == "--continue-current-context" ]] || usage
  continue_context=1
fi

cco_init
codex_thread_id=${CODEX_THREAD_ID:-}
[[ -n "$codex_thread_id" ]] || cco_die 69 "CODEX_THREAD_ID_MISSING"
root=$(cco_canonical_root "$1") || usage
session_uuid="${2:l}"
task_id="$3"
path_hash=$(cco_hash "$root")
thread_hash=$(cco_hash "$codex_thread_id")
registration="$CCO_SESSION_ROOT/$session_uuid"
threshold="$CCO_CONTEXT_COMPACTION_THRESHOLD"
max_busy=${CODEX_CLAUDE_MAX_BUSY_WORKERS:-2}
[[ "$max_busy" == <-> && "$max_busy" -ge 1 && "$max_busy" -le 2 ]] || \
  cco_die 64 "INVALID_MAX_BUSY_WORKERS"

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"
cco_acquire_gate || cco_die $? "CLAUDE_GATE_BUSY: $CCO_GATE_LOCK"
gate_held=1
ack_tmp=""
cleanup() {
  [[ -n "${ack_tmp:-}" && -e "$ack_tmp" ]] && /bin/rm -f -- "$ack_tmp"
  if (( ${gate_held:-0} == 1 )); then
    cco_release_gate
    gate_held=0
  fi
}
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"
cco_registration_matches "$registration" "$root" "$path_hash" "$thread_hash" "$session_uuid" || \
  cco_die 77 "CLAUDE_ASSIGN_OWNERSHIP_UNPROVEN: uuid=$session_uuid root=$root"
[[ ! -e "$registration/retirement.json" ]] || \
  cco_die 77 "CLAUDE_ASSIGN_RETIRED: uuid=$session_uuid root=$root"
[[ -r "$registration/runtime_schema_version" ]] || \
  cco_die 77 "CLAUDE_ASSIGN_SCHEMA_UNSUPPORTED: uuid=$session_uuid"
runtime_schema=$(<"$registration/runtime_schema_version")

# Only the lease this exact session owns proves it is still assignable.
lease=$(cco_worker_lease "$session_uuid") || \
  cco_die 75 "CLAUDE_ASSIGN_WORKER_NOT_LIVE: uuid=$session_uuid root=$root"
cco_lease_is_live "$lease" || \
  cco_die 75 "CLAUDE_ASSIGN_WORKER_NOT_LIVE: uuid=$session_uuid root=$root"

# Admission is assignment-time accounting: idle live PTYs have no record and
# consume no busy capacity. Active records serialize edit custody by canonical
# root, including a provably-dead named worker that remains an orphan until a
# terminal lifecycle action reconciles it.
cco_assignment_root_ready || cco_die 70 "CLAUDE_ASSIGNMENT_STATE_AMBIGUOUS"
assignment_records=("${(@f)$(cco_active_assignments)}") || \
  cco_die 70 "CLAUDE_ASSIGNMENT_STATE_AMBIGUOUS"
busy_count=0
for assignment_record in "${assignment_records[@]}"; do
  [[ -n "$assignment_record" ]] || continue
  assignment_root=$("$CCO_JQ" -r '.root' "$assignment_record")
  assignment_uuid=$("$CCO_JQ" -r '.session_uuid' "$assignment_record")
  assignment_task=$("$CCO_JQ" -r '.task_id' "$assignment_record")
  if [[ "$assignment_uuid" == "$session_uuid" ]]; then
    if [[ "$assignment_task" == "$task_id" ]]; then
      cco_die 79 "CLAUDE_ASSIGN_DUPLICATE_ACTIVE: uuid=$session_uuid task_id=$task_id"
    fi
    cco_die 77 "CLAUDE_ASSIGN_SESSION_BUSY: uuid=$session_uuid task_id=$assignment_task"
  fi
  [[ "$assignment_root" != "$root" ]] || \
    cco_die 77 "CLAUDE_ASSIGN_ROOT_BUSY: root=$root uuid=$assignment_uuid task_id=$assignment_task"
  if cco_assignment_worker_live "$assignment_record"; then
    (( busy_count += 1 ))
  fi
done
(( busy_count < max_busy )) || cco_die 77 "CLAUDE_ASSIGN_CAPACITY_BUSY: busy=$busy_count max=$max_busy"

events=0
acknowledged=0
context_state="observed"
continuation_scope="none"

if [[ "$runtime_schema" == "3" || "$runtime_schema" == "4" || "$runtime_schema" == "5" ]]; then
  counts=$(cco_context_counts "$registration") || \
    cco_die 70 "CLAUDE_ASSIGN_CONTEXT_CORRUPT: uuid=$session_uuid"
  events="${counts%% *}"
  acknowledged="${counts##* }"
  decision_required=0
  (( events >= threshold && acknowledged != events )) && decision_required=1

  if (( decision_required == 1 && continue_context == 0 )); then
    decision_json=$("$CCO_JQ" -cn \
      --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
      --argjson compactions "$events" --argjson threshold "$threshold" \
      '{uuid:$uuid,root:$root,task_id:$task_id,context_state:"decision_required",
        compactions:$compactions,threshold:$threshold,
        options:["rerun with --continue-current-context","rotate after handoff, custody return, and process-group death"]}')
    print -r -- "CODEX_PTY_WORKER_DECISION $decision_json"
    cco_die 76 "CLAUDE_ASSIGN_DECISION_REQUIRED: uuid=$session_uuid compactions=$events"
  fi

  if (( continue_context == 1 )); then
    (( decision_required == 1 )) || \
      cco_die 65 "CLAUDE_ASSIGN_CONTINUATION_NOT_REQUIRED: uuid=$session_uuid compactions=$events"
    context_dir="$registration/context"
    ack_tmp=$(mktemp "$context_dir/.acknowledged.XXXXXX")
    print -r -- "$events" > "$ack_tmp"
    /bin/chmod 600 "$ack_tmp"
    /bin/mv -- "$ack_tmp" "$context_dir/acknowledged_compactions"
    ack_tmp=""
    confirmed=$(cco_context_counts "$registration") || \
      cco_die 70 "CLAUDE_ASSIGN_CONTEXT_CORRUPT: uuid=$session_uuid"
    confirmed_events="${confirmed%% *}"
    if (( confirmed_events != events )); then
      cco_die 76 "CLAUDE_ASSIGN_DECISION_REQUIRED: uuid=$session_uuid compactions=$confirmed_events"
    fi
    acknowledged="$events"
    context_state="continued"
    continuation_scope="until_next_compaction"
  elif (( acknowledged == events && events >= threshold )); then
    context_state="continued"
    continuation_scope="until_next_compaction"
  fi
elif [[ "$runtime_schema" == "1" || "$runtime_schema" == "2" ]]; then
  (( continue_context == 0 )) || \
    cco_die 65 "CLAUDE_ASSIGN_CONTINUATION_NOT_SUPPORTED: uuid=$session_uuid context=unobserved_legacy"
  context_state="unobserved_legacy"
  continuation_scope="not_observed"
else
  cco_die 77 "CLAUDE_ASSIGN_SCHEMA_UNSUPPORTED: uuid=$session_uuid schema=$runtime_schema"
fi

assign_json=$("$CCO_JQ" -cn \
  --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
  --arg context_state "$context_state" --arg continuation_scope "$continuation_scope" \
  --argjson compactions "$events" --argjson threshold "$threshold" \
  '{uuid:$uuid,root:$root,task_id:$task_id,context_state:$context_state,
    continuation_scope:$continuation_scope,compactions:$compactions,threshold:$threshold}')
assignment_record="$CCO_ASSIGNMENT_ROOT/$session_uuid.json"
if [[ -e "$assignment_record" || -L "$assignment_record" ]]; then
  cco_die 77 "CLAUDE_ASSIGN_RECORD_EXISTS: uuid=$session_uuid"
fi
assignment_tmp=$(mktemp "$CCO_ASSIGNMENT_ROOT/.assignment.XXXXXX") || cco_die 75 "CLAUDE_ASSIGN_RECORD_ACQUIRE_FAILED"
assigned_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
assigned_at_epoch=$(date +%s)
[[ "$assigned_at_epoch" == <-> ]] || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
"$CCO_JQ" -cn \
  --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" --arg thread_hash "$thread_hash" \
  --arg assigned_at "$assigned_at" \
  '{version:1,state:"active",access:"write",session_uuid:$uuid,root:$root,task_id:$task_id,thread_hash:$thread_hash,assigned_at:$assigned_at}' \
  > "$assignment_tmp" || cco_die 75 "CLAUDE_ASSIGN_RECORD_ACQUIRE_FAILED"
health_assignment_tmp=""
health_cursor_tmp=""
if [[ "$runtime_schema" == "5" ]]; then
  health_dir="$registration/health"
  [[ -d "$health_dir" && ! -L "$health_dir" && ! -e "$health_dir/checkpoint.json" && ! -L "$health_dir/checkpoint.json" ]] || cco_die 77 "CLAUDE_ASSIGN_STAGE_CHECKPOINTED: uuid=$session_uuid"
  for health_file in health_schema_version policy.json assignment.json parent_tool_calls agent_calls transcript_cursor_bytes max_cache_read_input_tokens request_keys.log warning_emitted; do
    [[ -f "$health_dir/$health_file" && ! -L "$health_dir/$health_file" ]] || cco_die 70 "CLAUDE_ASSIGN_STAGE_HEALTH_CORRUPT: uuid=$session_uuid"
  done
  transcript_baseline=0
  transcript_candidates=("$CCO_HOME/.claude/projects"/**/"$session_uuid.jsonl"(N))
  if (( ${#transcript_candidates[@]} == 1 )) && [[ -f "$transcript_candidates[1]" && ! -L "$transcript_candidates[1]" ]]; then
    transcript_baseline=$(/usr/bin/stat -f '%z' "$transcript_candidates[1]" 2>/dev/null || /usr/bin/stat -c '%s' "$transcript_candidates[1]" 2>/dev/null || print -r -- "0")
    [[ "$transcript_baseline" == <-> ]] || transcript_baseline=0
  fi
  health_assignment_tmp=$(mktemp "$health_dir/.assignment.XXXXXX") || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
  "$CCO_JQ" -cn --arg task_id "$task_id" --argjson assigned_at_epoch "$assigned_at_epoch" '{schema_version:1,assigned_at_epoch:$assigned_at_epoch,task_id:$task_id}' > "$health_assignment_tmp" || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
  /bin/chmod 600 "$health_assignment_tmp" || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
  health_cursor_tmp=$(mktemp "$health_dir/.transcript-cursor.XXXXXX") || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
  print -r -- "$transcript_baseline" > "$health_cursor_tmp"
  /bin/chmod 600 "$health_cursor_tmp" || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
fi
if [[ "$runtime_schema" == "5" ]]; then
  /bin/mv -- "$health_cursor_tmp" "$health_dir/transcript_cursor_bytes" && /bin/mv -- "$health_assignment_tmp" "$health_dir/assignment.json" || cco_die 75 "CLAUDE_ASSIGN_STAGE_HEALTH_FAILED: uuid=$session_uuid"
fi
/bin/chmod 600 "$assignment_tmp" && /bin/mv -- "$assignment_tmp" "$assignment_record" || cco_die 75 "CLAUDE_ASSIGN_RECORD_ACQUIRE_FAILED"
print -r -- "CODEX_PTY_WORKER_ASSIGN $assign_json"
