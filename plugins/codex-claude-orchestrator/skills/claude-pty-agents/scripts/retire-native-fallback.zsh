#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: retire-native-fallback.zsh <absolute-worktree-root> <worker-uuid> <task-id>"
  exit 64
}

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"

(( $# == 3 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage
cco_is_uuid "$2" || usage
cco_is_short_text "$3" 200 || usage

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

cco_acquire_gate || cco_die $? "CLAUDE_GATE_BUSY: $CCO_GATE_LOCK"
gate_held=1
cleanup_gate() {
  if (( ${gate_held:-0} == 1 )); then
    cco_release_gate
    gate_held=0
  fi
}
trap 'cleanup_gate' EXIT
trap 'cleanup_gate; exit 129' HUP
trap 'cleanup_gate; exit 130' INT
trap 'cleanup_gate; exit 143' TERM

cco_registration_matches "$registration" "$root" "$path_hash" "$thread_hash" "$session_uuid" || \
  cco_die 77 "CLAUDE_RETIRE_OWNERSHIP_UNPROVEN: uuid=$session_uuid root=$root"

retirement="$registration/retirement.json"
if [[ -r "$retirement" ]]; then
  existing_state=$("$CCO_JQ" -r '.state // empty' "$retirement" 2>/dev/null || true)
  existing_task=$("$CCO_JQ" -r '.task_id // empty' "$retirement" 2>/dev/null || true)
  if [[ "$existing_state" == "transferred_native" && "$existing_task" == "$task_id" ]]; then
    print -- "CODEX_PTY_WORKER_RETIRED uuid=$session_uuid task_id=$task_id state=transferred_native"
    exit 0
  fi
  cco_die 75 "CLAUDE_RETIRE_CONFLICT: uuid=$session_uuid state=${existing_state:-invalid} task_id=${existing_task:-unknown}"
fi

# Native edit custody cannot begin while a verified Codex-owned worker still
# overlaps this scope. Rotation uses the same liveness proof.
if overlap_reason=$(cco_live_overlap_reason "$root"); then
  cco_die 75 "CLAUDE_RETIRE_WORKER_STILL_LIVE: $overlap_reason"
fi

umask 077
retirement_tmp=$(mktemp "$registration/.retirement.XXXXXX")
cleanup_tmp() {
  [[ -n "${retirement_tmp:-}" && -e "$retirement_tmp" ]] && /bin/rm -f -- "$retirement_tmp"
}
trap 'cleanup_tmp; cleanup_gate' EXIT
trap 'cleanup_tmp; cleanup_gate; exit 129' HUP
trap 'cleanup_tmp; cleanup_gate; exit 130' INT
trap 'cleanup_tmp; cleanup_gate; exit 143' TERM

"$CCO_JQ" -n \
  --arg state "transferred_native" \
  --arg task_id "$task_id" \
  --arg session_uuid "$session_uuid" \
  --arg root "$root" \
  --arg retired_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{state:$state,task_id:$task_id,session_uuid:$session_uuid,root:$root,retired_at:$retired_at}' \
  > "$retirement_tmp"
/bin/chmod 600 "$retirement_tmp"
/bin/mv -- "$retirement_tmp" "$retirement"
retirement_tmp=""

print -- "CODEX_PTY_WORKER_RETIRED uuid=$session_uuid task_id=$task_id state=transferred_native"
