#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: toggle-agents.zsh <status|on|off> [--stop]"
  exit 64
}

(( $# >= 1 && $# <= 2 )) || usage
action="$1"
stop_workers=0
[[ "$action" == "status" || "$action" == "on" || "$action" == "off" ]] || usage
if (( $# == 2 )); then
  [[ "$action" == "off" && "$2" == "--stop" ]] || usage
  stop_workers=1
fi

script_dir=${0:A:h}
source "$script_dir/runtime-lib.zsh"
cco_init

if [[ "$action" == "status" ]]; then
  max_busy=$(cco_max_busy_workers) || cco_die 64 "INVALID_MAX_BUSY_WORKERS"
  if [[ ! -e "$CCO_STATE_DIR" && ! -L "$CCO_STATE_DIR" ]]; then
    print -- "Claude PTY agents: ON — busy=0/$max_busy active=0 reserved=0 orphaned=0 stale_reserved=0 blocked_roots=0 live_workers=0 legacy_stale_leases=0"
    exit 0
  fi
  [[ -d "$CCO_STATE_DIR" && ! -L "$CCO_STATE_DIR" ]] || \
    cco_die 70 "CLAUDE_STATUS_STATE_AMBIGUOUS"
fi

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

if [[ "$action" == "status" ]]; then
  assignment_records=("${(@f)$(cco_open_assignments)}") || cco_die 70 "CLAUDE_STATUS_ASSIGNMENT_STATE_AMBIGUOUS"
  active_count=0; reserved_count=0; busy_count=0; orphaned_count=0; stale_reserved_count=0
  typeset -A active_roots
  for assignment_record in "${assignment_records[@]}"; do
    [[ -n "$assignment_record" ]] || continue
    assignment_state=$("$CCO_JQ" -r '.state' "$assignment_record")
    assignment_root=$("$CCO_JQ" -r '.root' "$assignment_record")
    [[ -z "${active_roots[$assignment_root]:-}" ]] || cco_die 70 "CLAUDE_STATUS_DUPLICATE_ROOT_ASSIGNMENT"
    active_roots[$assignment_root]=1
    if [[ "$assignment_state" == "active" ]]; then
      (( active_count += 1 ))
    else
      (( reserved_count += 1 ))
    fi
    assignment_live_status=0
    cco_assignment_worker_live "$assignment_record" || assignment_live_status=$?
    if (( assignment_live_status == 0 )); then
      (( busy_count += 1 ))
    elif (( assignment_live_status == 1 )); then
      if [[ "$assignment_state" == "active" ]]; then
        (( orphaned_count += 1 ))
      else
        (( stale_reserved_count += 1 ))
      fi
    else
      cco_die 70 "CLAUDE_STATUS_LIVENESS_UNPROVEN"
    fi
  done

  live_count=0
  legacy_stale_count=0
  typeset -A status_process_starts status_process_groups
  while read -r status_pid status_group status_dow status_mon status_day status_clock status_year; do
    [[ "$status_pid" == <-> && "$status_group" == <-> ]] || continue
    status_process_starts[$status_pid]="$status_dow $status_mon $status_day $status_clock $status_year"
    status_process_groups[$status_pid]="$status_group"
  done < <(ps -axo pid=,pgid=,lstart= 2>/dev/null || true)
  status_process_args=$(ps -axo args= 2>/dev/null || true)
  if [[ -e "$CCO_LEASE_ROOT" || -L "$CCO_LEASE_ROOT" ]]; then
    [[ -d "$CCO_LEASE_ROOT" && ! -L "$CCO_LEASE_ROOT" ]] || \
      cco_die 70 "CLAUDE_STATUS_LEASE_STATE_AMBIGUOUS"
    for lease in "$CCO_LEASE_ROOT"/*(DN); do
      [[ -d "$lease" && ! -L "$lease" ]] || \
        cco_die 70 "CLAUDE_STATUS_LEASE_STATE_AMBIGUOUS"
      if ! cco_lease_has_status_registration "$lease"; then
        legacy_owner_pid=""
        [[ ! -r "$lease/owner_pid" ]] || legacy_owner_pid=$(<"$lease/owner_pid")
        observed_legacy_start=""
        [[ "$legacy_owner_pid" != <-> ]] || observed_legacy_start="${status_process_starts[$legacy_owner_pid]:-}"
        if cco_legacy_lease_is_stale "$lease" "$observed_legacy_start" "$status_process_args"; then
          (( legacy_stale_count += 1 ))
          continue
        fi
        cco_die 70 "CLAUDE_STATUS_LEASE_STATE_AMBIGUOUS"
      fi
      lease_owner_pid=""
      lease_owner_start=""
      lease_owner_group=""
      [[ ! -r "$lease/owner_pid" ]] || lease_owner_pid=$(<"$lease/owner_pid")
      [[ ! -r "$lease/process_start" ]] || lease_owner_start=$(<"$lease/process_start")
      [[ ! -r "$lease/process_group" ]] || lease_owner_group=$(<"$lease/process_group")
      normalized_lease_start="${(j: :)${(z)lease_owner_start}}"
      if [[ "$lease_owner_pid" == <-> && "$lease_owner_group" == <-> &&
            "${status_process_starts[$lease_owner_pid]:-}" == "$normalized_lease_start" &&
            "${status_process_groups[$lease_owner_pid]:-}" == "$lease_owner_group" ]]; then
        cco_lease_is_live "$lease" && (( live_count += 1 )) || true
      fi
    done
  fi
  state="ON"
  [[ ! -e "$CCO_DISABLED_MARKER" ]] || state="OFF"
  print -- "Claude PTY agents: $state — busy=$busy_count/$max_busy active=$active_count reserved=$reserved_count orphaned=$orphaned_count stale_reserved=$stale_reserved_count blocked_roots=${#active_roots} live_workers=$live_count legacy_stale_leases=$legacy_stale_count"
  exit 0
fi

if [[ "$action" == "on" ]]; then
  /bin/rm -f -- "$CCO_DISABLED_MARKER"
  print -- "Claude PTY agents: ON — Codex-owned launches and transport may resume; standalone Claude is unchanged."
  exit 0
fi

umask 077
marker_tmp=$(mktemp "$CCO_STATE_DIR/.claude-pty-agents.disabled.XXXXXX")
{
  print -- "disabled_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print -- "owner=toggle-agents.zsh"
} > "$marker_tmp"
/bin/mv -f -- "$marker_tmp" "$CCO_DISABLED_MARKER"

live_count=0
orphan_group_count=0
typeset -a live_groups
for lease in "$CCO_LEASE_ROOT"/*(N/); do
  cco_lease_has_durable_registration "$lease" || continue
  worker_group=$(<"$lease/process_group")
  if cco_lease_is_live "$lease"; then
    live_groups+=("$worker_group")
    live_count=$(( live_count + 1 ))
  elif cco_process_group_has_live_members "$worker_group"; then
    orphan_group_count=$(( orphan_group_count + 1 ))
  fi
done

if (( stop_workers == 0 )); then
  print -- "Claude PTY agents: OFF — conforming future transport is blocked; $live_count verified Codex-owned worker(s) and $orphan_group_count unowned live process group(s) remain. Use 'off --stop' only if termination is intended."
  exit 0
fi

toggle_group=$(cco_process_group $$)
for worker_group in "${live_groups[@]}"; do
  [[ "$worker_group" == <-> && "$worker_group" -gt 1 && "$worker_group" != "$toggle_group" ]] || \
    cco_die 70 "CLAUDE_AGENTS_OFF_UNSAFE_PROCESS_GROUP: pgid=${worker_group:-invalid}"
  /bin/kill -TERM -- "-$worker_group" 2>/dev/null || true
done
for round in {1..30}; do
  remaining=0
  for worker_group in "${live_groups[@]}"; do
    cco_process_group_has_live_members "$worker_group" && remaining=$(( remaining + 1 )) || true
  done
  (( remaining == 0 )) && break
  sleep 0.1
done

remaining=0
for registration in "$CCO_SESSION_ROOT"/*(N/); do
  [[ -r "$registration/owner_kind" && -r "$registration/process_group" ]] || continue
  [[ "$(<"$registration/owner_kind")" == "codex-pty-worker" ]] || continue
  worker_group=$(<"$registration/process_group")
  cco_process_group_has_live_members "$worker_group" && remaining=$(( remaining + 1 )) || true
done
(( remaining == 0 )) || \
  cco_die 70 "CLAUDE_AGENTS_OFF_INCOMPLETE: $remaining registered process group(s) remain; no uncertain group was force-killed"
print -- "Claude PTY agents: OFF — conforming future transport is blocked and $live_count verified Codex-owned process group(s) were stopped; standalone Claude is unchanged."
