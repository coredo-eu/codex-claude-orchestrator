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
lease="$CCO_LEASE_ROOT/$path_hash"
threshold="$CCO_CONTEXT_COMPACTION_THRESHOLD"

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

[[ -r "$lease/session_uuid" && "$(<"$lease/session_uuid")" == "$session_uuid" ]] || \
  cco_die 75 "CLAUDE_ASSIGN_WORKER_NOT_LIVE: uuid=$session_uuid root=$root"
cco_lease_is_live "$lease" || \
  cco_die 75 "CLAUDE_ASSIGN_WORKER_NOT_LIVE: uuid=$session_uuid root=$root"

events=0
acknowledged=0
context_state="observed"
continuation_scope="none"

if [[ "$runtime_schema" == "3" || "$runtime_schema" == "4" ]]; then
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
print -r -- "CODEX_PTY_WORKER_ASSIGN $assign_json"
