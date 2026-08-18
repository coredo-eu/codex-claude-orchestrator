#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: reconcile-orphan.zsh <absolute-worktree-root> <worker-uuid> <task-id> [--apply <confirmation-token>]"
  exit 64
}

(( $# == 3 || $# == 5 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"

cco_is_uuid "$2" || usage
cco_is_short_text "$3" 200 || usage
apply=0
confirmation_token=""
if (( $# == 5 )); then
  [[ "$4" == "--apply" && "$5" =~ '^[0-9a-f]{64}$' ]] || usage
  apply=1
  confirmation_token="$5"
fi

cco_init
codex_thread_id=${CODEX_THREAD_ID:-}
[[ -n "$codex_thread_id" ]] || cco_die 69 "CODEX_THREAD_ID_MISSING"
operator_thread_hash=$(cco_hash "$codex_thread_id")
root=$(cco_canonical_root "$1") || usage
session_uuid="${2:l}"
task_id="$3"
path_hash=$(cco_hash "$root")

cco_acquire_gate || cco_die $? "CLAUDE_GATE_BUSY: $CCO_GATE_LOCK"
gate_held=1
retirement_tmp=""
cleanup_gate() {
  [[ -n "${retirement_tmp:-}" && -e "$retirement_tmp" ]] && /bin/rm -f -- "$retirement_tmp"
  if (( ${gate_held:-0} == 1 )); then
    cco_release_gate
    gate_held=0
  fi
}
trap 'cleanup_gate' EXIT
trap 'cleanup_gate; exit 129' HUP
trap 'cleanup_gate; exit 130' INT
trap 'cleanup_gate; exit 143' TERM

cco_assignment_root_ready || cco_die 70 "CLAUDE_ORPHAN_ASSIGNMENT_STATE_AMBIGUOUS"
assignment_record="$CCO_ASSIGNMENT_ROOT/$session_uuid.json"
cco_assignment_record_valid "$assignment_record" || \
  cco_die 77 "CLAUDE_ORPHAN_ASSIGNMENT_NOT_FOUND: uuid=$session_uuid root=$root"
assignment_thread_hash=$("$CCO_JQ" -r '.thread_hash' "$assignment_record")
cco_assignment_matches "$assignment_record" "$session_uuid" "$task_id" "$root" "$assignment_thread_hash" || \
  cco_die 77 "CLAUDE_ORPHAN_ASSIGNMENT_MISMATCH: uuid=$session_uuid root=$root task_id=$task_id"
assignment_state=$("$CCO_JQ" -r '.state' "$assignment_record")
[[ "$assignment_state" == "active" || "$assignment_state" == "abandoned_orphan" ]] || \
  cco_die 77 "CLAUDE_ORPHAN_ASSIGNMENT_NOT_ACTIVE: uuid=$session_uuid state=$assignment_state"

registration="$CCO_SESSION_ROOT/$session_uuid"
cco_registration_matches "$registration" "$root" "$path_hash" "$assignment_thread_hash" "$session_uuid" || \
  cco_die 77 "CLAUDE_ORPHAN_REGISTRATION_UNPROVEN: uuid=$session_uuid root=$root"

live_status=0
live_reason=$(cco_worker_live_reason "$session_uuid" "$root" "$path_hash") || live_status=$?
if (( live_status == 0 )); then
  cco_die 75 "CLAUDE_ORPHAN_WORKER_STILL_LIVE: $live_reason"
elif (( live_status != 1 )); then
  cco_die 70 "CLAUDE_ORPHAN_LIVENESS_UNPROVEN: uuid=$session_uuid root=$root"
fi

assigned_at=$("$CCO_JQ" -r '.assigned_at' "$assignment_record")
expected_token=$(cco_hash "abandon-orphan|$session_uuid|$root|$task_id|$assignment_thread_hash|$assigned_at")
retirement="$registration/retirement.json"
retirement_exists=0
if [[ -e "$retirement" || -L "$retirement" ]]; then
  [[ -f "$retirement" && ! -L "$retirement" ]] || \
    cco_die 70 "CLAUDE_ORPHAN_RETIREMENT_AMBIGUOUS: uuid=$session_uuid"
  "$CCO_JQ" -e --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
    --arg token "$expected_token" '
      type == "object" and .state == "abandoned_orphan" and
      .session_uuid == $uuid and .root == $root and .task_id == $task_id and
      .confirmation_token == $token
    ' "$retirement" >/dev/null 2>&1 || \
      cco_die 70 "CLAUDE_ORPHAN_RETIREMENT_CONFLICT: uuid=$session_uuid"
  retirement_exists=1
fi

preview_json=$("$CCO_JQ" -cn \
  --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
  --arg token "$expected_token" --arg state "$assignment_state" \
  --argjson retirement_exists "$retirement_exists" \
  '{session_uuid:$uuid,root:$root,task_id:$task_id,assignment_state:$state,
    worker_state:"proven_dead",retirement_exists:($retirement_exists == 1),
    confirmation_token:$token,
    effects:["write retirement tombstone","terminalize assignment","preserve worktree and registration"],
    non_effects:["no process signal","no transcript read","no file deletion","no session adoption"]}')

if (( apply == 0 )); then
  print -r -- "CODEX_PTY_ORPHAN_PREVIEW $preview_json"
  exit 0
fi
[[ "$confirmation_token" == "$expected_token" ]] || \
  cco_die 77 "CLAUDE_ORPHAN_CONFIRMATION_MISMATCH: uuid=$session_uuid"

if (( retirement_exists == 0 )); then
  retirement_tmp=$(mktemp "$registration/.retirement.XXXXXX") || \
    cco_die 75 "CLAUDE_ORPHAN_RETIREMENT_FAILED: uuid=$session_uuid"
  retired_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  "$CCO_JQ" -cn \
    --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
    --arg retired_at "$retired_at" --arg original_thread_hash "$assignment_thread_hash" \
    --arg operator_thread_hash "$operator_thread_hash" --arg token "$expected_token" \
    '{state:"abandoned_orphan",task_id:$task_id,session_uuid:$uuid,root:$root,
      retired_at:$retired_at,original_thread_hash:$original_thread_hash,
      operator_thread_hash:$operator_thread_hash,confirmation_token:$token,
      attested:{worker_process_dead:true,transcript_unread:true,worktree_preserved:true}}' \
    > "$retirement_tmp" || cco_die 75 "CLAUDE_ORPHAN_RETIREMENT_FAILED: uuid=$session_uuid"
  /bin/chmod 600 "$retirement_tmp" && /bin/mv -- "$retirement_tmp" "$retirement" || \
    cco_die 75 "CLAUDE_ORPHAN_RETIREMENT_FAILED: uuid=$session_uuid"
  retirement_tmp=""
fi

cco_terminalize_assignment "$session_uuid" "$task_id" "$root" "$assignment_thread_hash" "abandoned_orphan" || \
  cco_die 70 "CLAUDE_ORPHAN_ASSIGNMENT_RECONCILE_FAILED: uuid=$session_uuid"
result_json=$("$CCO_JQ" -cn \
  --arg uuid "$session_uuid" --arg root "$root" --arg task_id "$task_id" \
  '{state:"abandoned_orphan",session_uuid:$uuid,root:$root,task_id:$task_id,
    worker_state:"proven_dead",worktree_preserved:true,custody_available_for_inspection:true}')
print -r -- "CODEX_PTY_ORPHAN_RECONCILED $result_json"
