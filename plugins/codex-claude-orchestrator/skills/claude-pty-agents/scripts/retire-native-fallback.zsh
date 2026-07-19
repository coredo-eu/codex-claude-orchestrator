#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: retire-native-fallback.zsh <absolute-worktree-root> <worker-uuid> <task-id>"
  exit 64
}

(( $# == 3 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage
print -r -- "$2" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || usage
[[ -n "$3" && ${#3} -le 200 && "$3" != *$'\n'* ]] || usage

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"
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

# Native edit custody cannot begin while any verified Codex-owned worker has an
# overlapping canonical scope. The gate prevents concurrent launch/resume;
# lease and durable-registration scans close stale or missing state gaps.
for active_lease in "$CCO_LEASE_ROOT"/*(N/); do
  if cco_lease_has_durable_registration "$active_lease" && cco_lease_is_live "$active_lease"; then
    active_root=$(<"$active_lease/root")
    if cco_scope_overlaps "$root" "$active_root"; then
      active_uuid=$(<"$active_lease/session_uuid")
      cco_die 75 "CLAUDE_RETIRE_WORKER_STILL_LIVE: uuid=$active_uuid root=$active_root lease=$active_lease"
    fi
  fi
done

for active_registration in "$CCO_SESSION_ROOT"/*(N/); do
  for field in owner_kind root session_uuid name process_group; do
    [[ -r "$active_registration/$field" ]] || continue 2
  done
  [[ "$(<"$active_registration/owner_kind")" == "codex-pty-worker" ]] || continue
  active_root=$(<"$active_registration/root")
  cco_scope_overlaps "$root" "$active_root" || continue
  active_uuid=$(<"$active_registration/session_uuid")
  active_name=$(<"$active_registration/name")
  active_group=$(<"$active_registration/process_group")
  if cco_process_group_has_live_members "$active_group"; then
    cco_die 75 "CLAUDE_RETIRE_WORKER_STILL_LIVE: uuid=$active_uuid root=$active_root pgid=$active_group"
  fi
  for pid in "${(@f)$(ps -axo pid= 2>/dev/null || true)}"; do
    pid=${pid//[[:space:]]/}
    [[ "$pid" == <-> ]] || continue
    args=$(cco_process_args "$pid")
    if [[ "$args" == *"--name $active_name"* &&
          ( "$args" == *"--session-id $active_uuid"* || "$args" == *"--resume $active_uuid"* ) ]]; then
      cco_die 75 "CLAUDE_RETIRE_WORKER_STILL_LIVE: uuid=$active_uuid root=$active_root pid=$pid"
    fi
  done
done

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
