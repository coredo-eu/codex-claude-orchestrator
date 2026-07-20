#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: rotate-worker.zsh <absolute-worktree-root> <worker-uuid> <task-id> --handoff <ready_for_verification|blocked> --custody-returned"
  exit 64
}

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"

(( $# == 6 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage
cco_is_uuid "$2" || usage
cco_is_short_text "$3" 200 || usage
[[ "$4" == "--handoff" ]] || usage
[[ "$5" == "ready_for_verification" || "$5" == "blocked" ]] || usage
[[ "$6" == "--custody-returned" ]] || usage

cco_init
codex_thread_id=${CODEX_THREAD_ID:-}
[[ -n "$codex_thread_id" ]] || cco_die 69 "CODEX_THREAD_ID_MISSING"
root=$(cco_canonical_root "$1") || usage
session_uuid="${2:l}"
task_id="$3"
handoff_state="$5"
path_hash=$(cco_hash "$root")
thread_hash=$(cco_hash "$codex_thread_id")
registration="$CCO_SESSION_ROOT/$session_uuid"

cco_acquire_gate || cco_die $? "CLAUDE_GATE_BUSY: $CCO_GATE_LOCK"
gate_held=1
retirement_tmp=""
cleanup() {
  [[ -n "${retirement_tmp:-}" && -e "$retirement_tmp" ]] && /bin/rm -f -- "$retirement_tmp"
  if (( ${gate_held:-0} == 1 )); then
    cco_release_gate
    gate_held=0
  fi
}
trap 'cleanup' EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

cco_registration_matches "$registration" "$root" "$path_hash" "$thread_hash" "$session_uuid" || \
  cco_die 77 "CLAUDE_ROTATE_OWNERSHIP_UNPROVEN: uuid=$session_uuid root=$root"

retirement="$registration/retirement.json"
if [[ -r "$retirement" ]]; then
  existing_state=$("$CCO_JQ" -r '.state // empty' "$retirement" 2>/dev/null || true)
  existing_task=$("$CCO_JQ" -r '.task_id // empty' "$retirement" 2>/dev/null || true)
  if [[ "$existing_state" == "rotated_context" && "$existing_task" == "$task_id" ]]; then
    print -r -- "CODEX_PTY_WORKER_ROTATED $("$CCO_JQ" -c . "$retirement")"
    exit 0
  fi
  cco_die 75 "CLAUDE_ROTATE_CONFLICT: uuid=$session_uuid state=${existing_state:-invalid}"
fi

# Handoff and custody are explicit Codex attestations. Process-group death is
# independently observable and remains the non-negotiable runtime boundary.
if overlap_reason=$(cco_live_overlap_reason "$root"); then
  cco_die 75 "CLAUDE_ROTATE_WORKER_STILL_LIVE: $overlap_reason"
fi

umask 077
rotated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
lineage_id=$(cco_hash "$session_uuid|$task_id|$rotated_at")
lineage_id="${lineage_id[1,16]}"
retirement_tmp=$(mktemp "$registration/.retirement.XXXXXX")
"$CCO_JQ" -n \
  --arg state "rotated_context" --arg task_id "$task_id" \
  --arg session_uuid "$session_uuid" --arg root "$root" \
  --arg retired_at "$rotated_at" --arg lineage_id "$lineage_id" \
  --arg handoff_state "$handoff_state" \
  '{state:$state,task_id:$task_id,session_uuid:$session_uuid,root:$root,
    retired_at:$retired_at,lineage_id:$lineage_id,
    attested:{handoff_state:$handoff_state,custody_returned:true,attested_by:"codex"},
    verified:{no_live_overlapping_worker:true,ownership:"thread_and_root"}}' > "$retirement_tmp"
/bin/chmod 600 "$retirement_tmp"
/bin/mv -- "$retirement_tmp" "$retirement"
retirement_tmp=""

print -r -- "CODEX_PTY_WORKER_ROTATED $("$CCO_JQ" -c . "$retirement")"
