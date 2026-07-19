#!/usr/bin/env zsh

# Shared runtime primitives. Call cco_init before using any other function.

typeset -g CCO_HOME=""
typeset -g CCO_STATE_DIR=""
typeset -g CCO_DISABLED_MARKER=""
typeset -g CCO_GATE_LOCK=""
typeset -g CCO_GATE_DIR=""
typeset -g CCO_LEASE_ROOT=""
typeset -g CCO_SESSION_ROOT=""
typeset -g CCO_JQ=""
typeset -g CCO_GATE_KIND=""
typeset -g CCO_GATE_FD=""

cco_die() {
  local code="$1"
  shift
  print -u2 -r -- "$*"
  exit "$code"
}

cco_init() {
  [[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || cco_die 69 "HOME_INVALID"
  CCO_HOME=$(cd -P -- "$HOME" && pwd -P)
  CCO_STATE_DIR="$CCO_HOME/.codex"
  CCO_DISABLED_MARKER="$CCO_STATE_DIR/claude-pty-agents.disabled"
  CCO_GATE_LOCK="$CCO_STATE_DIR/claude-pty-agents.gate.lock"
  CCO_GATE_DIR="$CCO_STATE_DIR/claude-pty-agents.gate.d"
  CCO_LEASE_ROOT="$CCO_STATE_DIR/claude-pty-leases"
  CCO_SESSION_ROOT="$CCO_STATE_DIR/claude-pty-sessions"
  CCO_JQ=$(command -v jq 2>/dev/null) || cco_die 69 "JQ_NOT_FOUND"
}

cco_hash() {
  local value="$1" hash_bin
  if hash_bin=$(command -v shasum 2>/dev/null); then
    print -rn -- "$value" | "$hash_bin" -a 256 | awk '{print $1}'
  elif hash_bin=$(command -v sha256sum 2>/dev/null); then
    print -rn -- "$value" | "$hash_bin" | awk '{print $1}'
  else
    cco_die 69 "SHA256_TOOL_NOT_FOUND"
  fi
}

cco_canonical_root() {
  local requested="$1" git_root root
  [[ "$requested" == /* && -d "$requested" ]] || return 1
  requested=$(cd -P -- "$requested" && pwd -P) || return 1
  git_root=$(git -C "$requested" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$git_root" && -d "$git_root" ]]; then
    root=$(cd -P -- "$git_root" && pwd -P) || return 1
  else
    root="$requested"
  fi
  [[ "$root" != "/" && "$root" != "$CCO_HOME" ]] || return 1
  print -r -- "$root"
}

cco_process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

cco_process_args() {
  ps -p "$1" -ww -o args= 2>/dev/null || true
}

cco_process_group() {
  ps -p "$1" -o pgid= 2>/dev/null | tr -d '[:space:]' || true
}

cco_process_group_has_live_members() {
  local expected_group="$1" member_pid member_group member_state
  [[ "$expected_group" == <-> && "$expected_group" -gt 1 ]] || return 1
  while read -r member_pid member_group member_state; do
    [[ "$member_pid" == <-> && "$member_group" == <-> ]] || continue
    if [[ "$member_group" == "$expected_group" && "$member_state" != Z* ]]; then
      return 0
    fi
  done < <(ps -axo pid=,pgid=,stat= 2>/dev/null || true)
  return 1
}

cco_process_cwd() {
  local pid="$1" lsof_bin cwd
  if lsof_bin=$(command -v lsof 2>/dev/null); then
    cwd=$("$lsof_bin" -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)
    [[ -n "$cwd" ]] && print -r -- "$cwd"
    return 0
  fi
  if [[ -L "/proc/$pid/cwd" ]]; then
    readlink "/proc/$pid/cwd" 2>/dev/null || true
  fi
}

cco_process_identity_matches() {
  local pid="$1" expected_start="$2" expected_group="${3:-}"
  [[ "$pid" == <-> && -n "$expected_start" && "$(cco_process_start "$pid")" == "$expected_start" ]] || return 1
  [[ -z "$expected_group" || "$(cco_process_group "$pid")" == "$expected_group" ]]
}

cco_scope_overlaps() {
  local left="${1%/}" right="${2%/}"
  [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

cco_validate_model() {
  local model="$1"
  [[ -n "$model" && ${#model} -le 128 && "$model" != *$'\n'* && "$model" =~ '^[A-Za-z0-9._:-]+$' ]]
}

cco_acquire_gate() {
  local lockf_bin flock_bin attempt owner_pid owner_start stale
  /bin/mkdir -p -- "$CCO_STATE_DIR"
  umask 077

  if lockf_bin=$(command -v lockf 2>/dev/null); then
    exec {CCO_GATE_FD}>>"$CCO_GATE_LOCK" || return 73
    "$lockf_bin" -s -t 15 "$CCO_GATE_FD" || return 75
    CCO_GATE_KIND="fd"
    return 0
  fi
  if flock_bin=$(command -v flock 2>/dev/null); then
    exec {CCO_GATE_FD}>>"$CCO_GATE_LOCK" || return 73
    "$flock_bin" -w 15 "$CCO_GATE_FD" || return 75
    CCO_GATE_KIND="fd"
    return 0
  fi

  for attempt in {1..150}; do
    if /bin/mkdir -- "$CCO_GATE_DIR" 2>/dev/null; then
      print -r -- "$$" > "$CCO_GATE_DIR/owner_pid"
      print -r -- "$(cco_process_start $$)" > "$CCO_GATE_DIR/process_start"
      CCO_GATE_KIND="dir"
      return 0
    fi

    owner_pid=""
    owner_start=""
    [[ -r "$CCO_GATE_DIR/owner_pid" ]] && owner_pid=$(<"$CCO_GATE_DIR/owner_pid")
    [[ -r "$CCO_GATE_DIR/process_start" ]] && owner_start=$(<"$CCO_GATE_DIR/process_start")
    if [[ -n "$owner_pid" ]] && cco_process_identity_matches "$owner_pid" "$owner_start"; then
      sleep 0.1
      continue
    fi

    stale="$CCO_STATE_DIR/.claude-pty-gate-stale-$$-$attempt"
    if /bin/mv -- "$CCO_GATE_DIR" "$stale" 2>/dev/null; then
      [[ "$stale" == "$CCO_STATE_DIR"/.claude-pty-gate-stale-* ]] || return 70
      /bin/rm -rf -- "$stale"
    fi
  done
  return 75
}

cco_release_gate() {
  if [[ "$CCO_GATE_KIND" == "fd" && -n "$CCO_GATE_FD" ]]; then
    exec {CCO_GATE_FD}>&-
  elif [[ "$CCO_GATE_KIND" == "dir" && -d "$CCO_GATE_DIR" ]]; then
    local owner_pid="" owner_start=""
    [[ -r "$CCO_GATE_DIR/owner_pid" ]] && owner_pid=$(<"$CCO_GATE_DIR/owner_pid")
    [[ -r "$CCO_GATE_DIR/process_start" ]] && owner_start=$(<"$CCO_GATE_DIR/process_start")
    if [[ "$owner_pid" == "$$" && "$owner_start" == "$(cco_process_start $$)" ]]; then
      /bin/rm -f -- "$CCO_GATE_DIR/owner_pid" "$CCO_GATE_DIR/process_start"
      /bin/rmdir -- "$CCO_GATE_DIR" 2>/dev/null || true
    fi
  fi
  CCO_GATE_KIND=""
  CCO_GATE_FD=""
}

cco_lease_is_live() {
  local lease="$1" owner_pid owner_start owner_group owner_uuid owner_root owner_name args cwd
  for field in owner_pid process_start process_group session_uuid root name; do
    [[ -r "$lease/$field" ]] || return 1
  done
  owner_pid=$(<"$lease/owner_pid")
  owner_start=$(<"$lease/process_start")
  owner_group=$(<"$lease/process_group")
  owner_uuid=$(<"$lease/session_uuid")
  owner_root=$(<"$lease/root")
  owner_name=$(<"$lease/name")
  cco_process_identity_matches "$owner_pid" "$owner_start" "$owner_group" || return 1
  args=$(cco_process_args "$owner_pid")
  [[ "$args" == *"launch-worker.zsh"* ||
     ( "$args" == *"--name $owner_name"* &&
       ( "$args" == *"--session-id $owner_uuid"* || "$args" == *"--resume $owner_uuid"* ) ) ]] || return 1
  cwd=$(cco_process_cwd "$owner_pid")
  [[ -z "$cwd" || "$cwd" == "$owner_root" ]] || return 1
  return 0
}

cco_registration_matches() {
  local registration="$1" root="$2" path_hash="$3" thread_hash="$4" uuid="$5"
  for field in owner_kind root path_hash thread_hash session_uuid process_group; do
    [[ -r "$registration/$field" ]] || return 1
  done
  [[ "$(<"$registration/owner_kind")" == "codex-pty-worker" &&
     "$(<"$registration/root")" == "$root" &&
     "$(<"$registration/path_hash")" == "$path_hash" &&
     "$(<"$registration/thread_hash")" == "$thread_hash" &&
     "$(<"$registration/session_uuid")" == "$uuid" ]]
}

cco_lease_has_durable_registration() {
  local lease="$1" uuid root path_hash registration
  for field in session_uuid root process_group; do
    [[ -r "$lease/$field" ]] || return 1
  done
  uuid=$(<"$lease/session_uuid")
  root=$(<"$lease/root")
  path_hash=$(cco_hash "$root")
  [[ "$lease" == "$CCO_LEASE_ROOT/$path_hash" ]] || return 1
  registration="$CCO_SESSION_ROOT/$uuid"
  for field in owner_kind root path_hash session_uuid process_group runtime_schema_version runtime_version; do
    [[ -r "$registration/$field" ]] || return 1
  done
  local runtime_schema
  runtime_schema=$(<"$registration/runtime_schema_version")
  [[ "$(<"$registration/owner_kind")" == "codex-pty-worker" &&
     "$(<"$registration/root")" == "$root" &&
     "$(<"$registration/path_hash")" == "$path_hash" &&
     "$(<"$registration/session_uuid")" == "$uuid" &&
     "$(<"$registration/process_group")" == "$(<"$lease/process_group")" &&
     ( "$runtime_schema" == "1" || "$runtime_schema" == "2" ) ]]
}
