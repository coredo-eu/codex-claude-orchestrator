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
typeset -gr CCO_CONTEXT_COMPACTION_THRESHOLD=2

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

cco_is_uuid() {
  local value="$1"
  [[ "$value" != *$'\n'* ]] || return 1
  print -r -- "$value" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

cco_is_short_text() {
  local value="$1" limit="$2"
  [[ -n "$value" && ${#value} -le "$limit" && "$value" != *$'\n'* ]]
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

# Print "<completed-compactions> <acknowledged-compactions>". Every completed
# PostCompact event is one literal line; no summary or task content is stored.
cco_context_counts() {
  local registration="$1" context_dir schema events acknowledged pending
  context_dir="$registration/context"
  [[ -d "$context_dir" && ! -L "$context_dir" ]] || return 1
  [[ -w "$context_dir" ]] || return 1
  for pending in "$context_dir"/.compaction-pending.*(N); do
    return 1
  done
  for file in context_schema_version compactions.log acknowledged_compactions; do
    [[ -f "$context_dir/$file" && ! -L "$context_dir/$file" ]] || return 1
  done
  schema=$(<"$context_dir/context_schema_version")
  [[ "$schema" == "1" ]] || return 1
  events=$(awk '$0 != "1" { exit 1 } END { print NR }' "$context_dir/compactions.log") || return 1
  acknowledged=$(<"$context_dir/acknowledged_compactions")
  [[ "$events" == <-> && "$acknowledged" == <-> && ${#acknowledged} -le 9 ]] || return 1
  (( acknowledged <= events )) || return 1
  print -r -- "$events $acknowledged"
}

# Extract one credential-free loopback CodeIndexer server. Strict mode also
# requires the file itself to be the minimal session snapshot.
cco_codeindexer_mcp_json() {
  local config="$1" strict="${2:-0}"
  [[ -f "$config" && ! -L "$config" && ( "$strict" == "0" || "$strict" == "1" ) ]] || return 1
  "$CCO_JQ" -ce --arg strict "$strict" '
    select(type == "object")
    | select($strict != "1" or (keys | sort) == ["mcpServers"])
    | .mcpServers as $servers
    | select(($servers | type) == "object")
    | select($strict != "1" or ($servers | keys | sort) == ["codeindexer"])
    | $servers.codeindexer as $server
    | select(
        ($server | type) == "object" and
        ($server | keys | sort) == ["type", "url"] and
        $server.type == "http"
      )
    | ($server.url | capture(
        "^http://(?<host>127\\.0\\.0\\.1|localhost|\\[::1\\]):(?<port>[1-9][0-9]{0,4})/mcp$"
      )) as $address
    | select(($address.port | tonumber) <= 65535)
    | {mcpServers:{codeindexer:$server}}
  ' "$config" 2>/dev/null
}

# Resolve the durable lease belonging to exactly this session UUID. Current
# leases are keyed by the session UUID so that any number of Codex-owned
# workers may hold one in the same canonical root. Schema-1..4 leases were
# keyed by the root path hash and stay usable by the session that wrote them.
# Return 2 when both keys claim this UUID: that state is ambiguous and every
# caller must fail closed rather than guess which lease is authoritative.
cco_worker_lease() {
  local uuid="$1" registration root path_hash candidate
  typeset -a found
  registration="$CCO_SESSION_ROOT/$uuid"
  [[ -r "$registration/root" ]] || return 1
  root=$(<"$registration/root")
  path_hash=$(cco_hash "$root")
  found=()
  for candidate in "$CCO_LEASE_ROOT/$uuid" "$CCO_LEASE_ROOT/$path_hash"; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    [[ -r "$candidate/session_uuid" ]] || continue
    [[ "$(<"$candidate/session_uuid")" == "$uuid" ]] || continue
    found+=("$candidate")
  done
  (( ${#found} == 1 )) || { (( ${#found} == 0 )) && return 1 || return 2; }
  print -r -- "${found[1]}"
  return 0
}

# Report the first live signal for exactly this session UUID. Ownership, not
# scope, is the boundary: other Codex-owned workers in the same canonical root
# are never consulted, and no standalone Claude is ever discovered by process
# name. Ambiguous or unreadable lease state is reported as live so that every
# lifecycle caller fails closed.
cco_worker_live_reason() {
  # Note: never name a local "status" here; zsh reserves it as an alias for $?.
  local uuid="$1" registration root name group lease lease_status pid args field
  registration="$CCO_SESSION_ROOT/$uuid"
  # Every caller proves ownership before reaching this point, so degraded
  # registration state here is unexplained. Report it as live: missing identity
  # must never be read as proof that a running worker is dead.
  for field in owner_kind root session_uuid process_group; do
    if [[ ! -r "$registration/$field" ]]; then
      print -r -- "uuid=$uuid registration=degraded missing=$field"
      return 0
    fi
  done
  if [[ "$(<"$registration/owner_kind")" != "codex-pty-worker" ||
        "$(<"$registration/session_uuid")" != "$uuid" ]]; then
    print -r -- "uuid=$uuid registration=degraded"
    return 0
  fi
  root=$(<"$registration/root")
  group=$(<"$registration/process_group")
  # The recorded name only sharpens the process-argument scan below. Its absence
  # must narrow that scan to the UUID, never skip a liveness signal.
  name=""
  [[ ! -r "$registration/name" ]] || name=$(<"$registration/name")

  lease_status=0
  lease=$(cco_worker_lease "$uuid") || lease_status=$?
  if (( lease_status == 2 )); then
    print -r -- "uuid=$uuid root=$root lease=ambiguous"
    return 0
  fi
  if (( lease_status == 0 )) && cco_lease_is_live "$lease"; then
    print -r -- "uuid=$uuid root=$root lease=$lease"
    return 0
  fi
  if cco_process_group_has_live_members "$group"; then
    print -r -- "uuid=$uuid root=$root pgid=$group"
    return 0
  fi
  for pid in "${(@f)$(ps -axo pid= 2>/dev/null || true)}"; do
    pid=${pid//[[:space:]]/}
    [[ "$pid" == <-> ]] || continue
    args=$(cco_process_args "$pid")
    if [[ ( -z "$name" || "$args" == *"--name $name"* ) &&
          ( "$args" == *"--session-id $uuid"* || "$args" == *"--resume $uuid"* ) ]]; then
      print -r -- "uuid=$uuid root=$root pid=$pid"
      return 0
    fi
  done
  return 1
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
  # Session-keyed leases are current; root-keyed leases are the legacy layout.
  [[ "$lease" == "$CCO_LEASE_ROOT/$uuid" || "$lease" == "$CCO_LEASE_ROOT/$path_hash" ]] || return 1
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
     ( "$runtime_schema" == "1" || "$runtime_schema" == "2" || "$runtime_schema" == "3" || "$runtime_schema" == "4" ) ]]
}
