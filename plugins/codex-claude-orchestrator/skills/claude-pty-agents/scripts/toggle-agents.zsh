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
  if [[ -e "$CCO_DISABLED_MARKER" ]]; then
    print -- "Claude PTY agents: OFF"
  else
    print -- "Claude PTY agents: ON"
  fi
  exit 0
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
