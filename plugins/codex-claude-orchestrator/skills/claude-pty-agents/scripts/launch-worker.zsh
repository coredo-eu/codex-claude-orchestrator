#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: launch-worker.zsh <absolute-worktree-root> [--resume <worker-uuid>]"
  exit 64
}

(( $# == 1 || $# == 3 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage

mode="new"
session_uuid=""
if (( $# == 3 )); then
  [[ "$2" == "--resume" ]] || usage
  print -r -- "$3" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || usage
  mode="resume"
  session_uuid="${3:l}"
fi

script_dir=${0:A:h}
skill_dir=${script_dir:h}
source "$script_dir/runtime-lib.zsh"
cco_init

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"

codex_thread_id=${CODEX_THREAD_ID:-}
[[ -n "$codex_thread_id" ]] || cco_die 69 "CODEX_THREAD_ID_MISSING"
thread_hash=$(cco_hash "$codex_thread_id")
root=$(cco_canonical_root "$1") || usage
cd -P -- "$root"
path_hash=$(cco_hash "$root")

claude_bin=$(command -v claude 2>/dev/null) || cco_die 69 "CLAUDE_NOT_FOUND"
zsh_bin=$(command -v zsh 2>/dev/null) || cco_die 69 "ZSH_NOT_FOUND"
prompt_file="$skill_dir/assets/worker-system-prompt.txt"
subagent_hook="$script_dir/worker-subagent-contract.zsh"
[[ -r "$prompt_file" ]] || cco_die 66 "WORKER_PROMPT_MISSING: $prompt_file"
[[ -x "$subagent_hook" ]] || cco_die 66 "WORKER_SUBAGENT_HOOK_MISSING: $subagent_hook"

[[ -t 0 && -t 1 ]] || cco_die 69 "PTY_REQUIRED"
worker_group=$(cco_process_group $$)
[[ "$worker_group" == <-> && "$worker_group" -gt 1 && "$worker_group" == "$$" ]] || \
  cco_die 69 "PTY_PROCESS_GROUP_ISOLATION_REQUIRED: pid=$$ pgid=${worker_group:-unknown}; invoke the launcher as the PTY command or with exec"

parent_model=${CODEX_CLAUDE_PARENT_MODEL:-opus}
subagent_model=${CODEX_CLAUDE_SUBAGENT_MODEL:-haiku}

if [[ "$mode" == "new" ]]; then
  if command -v uuidgen >/dev/null 2>&1; then
    session_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    session_uuid=$(</proc/sys/kernel/random/uuid)
  else
    cco_die 69 "UUID_TOOL_NOT_FOUND"
  fi
fi

base=${root:t}
safe_base=$(print -rn -- "$base" | LC_ALL=C tr -cs 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//')
[[ -n "$safe_base" ]] || safe_base="repo"
safe_base=${safe_base[1,28]}
worker_name="codex-pty-${safe_base}-${path_hash[1,8]}-${session_uuid[1,8]}"
registration="$CCO_SESSION_ROOT/$session_uuid"
lease="$CCO_LEASE_ROOT/$path_hash"

# Best-effort standalone isolation: never attach to or overlap any visible
# Claude process already rooted in the same canonical scope.
for pid in "${(@f)$(ps -axo pid=,comm= 2>/dev/null | awk '
  { name=$2; sub(/^.*\//, "", name); if (name == "claude") print $1 }
' || true)}"; do
  [[ -n "$pid" ]] || continue
  live_cwd=$(cco_process_cwd "$pid")
  [[ -n "$live_cwd" && -d "$live_cwd" ]] || continue
  live_root=$(cco_canonical_root "$live_cwd" 2>/dev/null || true)
  [[ -n "$live_root" ]] || continue
  if cco_scope_overlaps "$root" "$live_root"; then
    cco_die 75 "CLAUDE_CWD_CONFLICT: pid=$pid root=$root live_root=$live_root"
  fi
done

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

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"
/bin/mkdir -p -- "$CCO_LEASE_ROOT" "$CCO_SESSION_ROOT"

if [[ "$mode" == "resume" ]]; then
  [[ ! -e "$registration/retirement.json" ]] || cco_die 77 "CLAUDE_RESUME_RETIRED: uuid=$session_uuid root=$root"
  cco_registration_matches "$registration" "$root" "$path_hash" "$thread_hash" "$session_uuid" || \
    cco_die 77 "CLAUDE_RESUME_OWNERSHIP_UNPROVEN: uuid=$session_uuid root=$root"
  [[ -r "$registration/runtime_schema_version" && "$(<"$registration/runtime_schema_version")" == "1" ]] || \
    cco_die 77 "CLAUDE_RESUME_SCHEMA_UNSUPPORTED: uuid=$session_uuid"
  for snapshot in parent_model subagent_model runtime/worker-settings.json runtime/worker-system-prompt.txt runtime/worker-subagent-contract.zsh; do
    [[ -r "$registration/$snapshot" ]] || cco_die 77 "CLAUDE_RESUME_SNAPSHOT_INCOMPLETE: uuid=$session_uuid missing=$snapshot"
  done
  parent_model=$(<"$registration/parent_model")
  subagent_model=$(<"$registration/subagent_model")
fi

cco_validate_model "$parent_model" || cco_die 64 "INVALID_PARENT_MODEL"
cco_validate_model "$subagent_model" || cco_die 64 "INVALID_SUBAGENT_MODEL"

for other_lease in "$CCO_LEASE_ROOT"/*(N/); do
  [[ "$other_lease" != "$lease" ]] || continue
  if cco_lease_has_durable_registration "$other_lease"; then
    other_root=$(<"$other_lease/root")
    other_group=$(<"$other_lease/process_group")
    if ( cco_lease_is_live "$other_lease" || cco_process_group_has_live_members "$other_group" ) && \
       cco_scope_overlaps "$root" "$other_root"; then
      cco_die 75 "LEASE_SCOPE_CONFLICT: root=$root live_root=$other_root lease=$other_lease"
    fi
  fi
done

for other_registration in "$CCO_SESSION_ROOT"/*(N/); do
  for field in owner_kind root process_group; do
    [[ -r "$other_registration/$field" ]] || continue 2
  done
  [[ "$(<"$other_registration/owner_kind")" == "codex-pty-worker" ]] || continue
  other_root=$(<"$other_registration/root")
  other_group=$(<"$other_registration/process_group")
  if cco_scope_overlaps "$root" "$other_root" && cco_process_group_has_live_members "$other_group"; then
    cco_die 75 "REGISTRATION_PROCESS_GROUP_CONFLICT: root=$root live_root=$other_root pgid=$other_group"
  fi
done

if [[ -e "$lease" ]]; then
  if cco_lease_is_live "$lease"; then
    cco_die 75 "LEASE_CONFLICT: root=$root lease=$lease"
  fi
  if cco_lease_has_durable_registration "$lease"; then
    stale_group=$(<"$lease/process_group")
    cco_process_group_has_live_members "$stale_group" && \
      cco_die 75 "LEASE_PROCESS_GROUP_CONFLICT: root=$root lease=$lease pgid=$stale_group"
  fi
  stale="$CCO_LEASE_ROOT/.stale-${path_hash}-$$"
  /bin/mv -- "$lease" "$stale" 2>/dev/null || cco_die 75 "LEASE_RECLAIM_FAILED: $lease"
  [[ "$stale" == "$CCO_LEASE_ROOT"/.stale-* ]] || cco_die 70 "UNSAFE_STALE_PATH"
  /bin/rm -rf -- "$stale"
fi
/bin/mkdir -- "$lease" || cco_die 75 "LEASE_ACQUIRE_FAILED: $lease"

umask 077
print -r -- "$$" > "$lease/owner_pid"
print -r -- "$session_uuid" > "$lease/session_uuid"
print -r -- "$root" > "$lease/root"
print -r -- "$worker_name" > "$lease/name"
print -r -- "$worker_group" > "$lease/process_group"
print -r -- "$(cco_process_start $$)" > "$lease/process_start"
print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$lease/started_at"

if [[ "$mode" == "new" ]]; then
  /bin/mkdir -- "$registration" 2>/dev/null || cco_die 75 "CLAUDE_SESSION_REGISTRATION_CONFLICT: uuid=$session_uuid"
  print -r -- "codex-pty-worker" > "$registration/owner_kind"
  print -r -- "$root" > "$registration/root"
  print -r -- "$path_hash" > "$registration/path_hash"
  print -r -- "$thread_hash" > "$registration/thread_hash"
  print -r -- "$session_uuid" > "$registration/session_uuid"
  print -r -- "$worker_name" > "$registration/name"
  print -r -- "$worker_group" > "$registration/process_group"
  print -r -- "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$registration/created_at"
  print -r -- "1" > "$registration/runtime_schema_version"
  print -r -- "0.1.0" > "$registration/runtime_version"
else
  process_group_tmp=$(mktemp "$registration/.process-group.XXXXXX")
  print -r -- "$worker_group" > "$process_group_tmp"
  /bin/chmod 600 "$process_group_tmp"
  /bin/mv -- "$process_group_tmp" "$registration/process_group"
fi

runtime_dir="$registration/runtime"
/bin/mkdir -p -- "$runtime_dir"
runtime_prompt="$runtime_dir/worker-system-prompt.txt"
runtime_hook="$runtime_dir/worker-subagent-contract.zsh"
runtime_settings="$runtime_dir/worker-settings.json"
settings_tmp=""
cleanup_runtime_tmp() {
  [[ -n "${settings_tmp:-}" && -e "$settings_tmp" ]] && /bin/rm -f -- "$settings_tmp"
}
trap 'cleanup_runtime_tmp; cleanup_gate' EXIT
trap 'cleanup_runtime_tmp; cleanup_gate; exit 129' HUP
trap 'cleanup_runtime_tmp; cleanup_gate; exit 130' INT
trap 'cleanup_runtime_tmp; cleanup_gate; exit 143' TERM

if [[ "$mode" == "new" ]]; then
  /bin/cp -- "$prompt_file" "$runtime_prompt"
  /bin/cp -- "$subagent_hook" "$runtime_hook"
  /bin/chmod 600 "$runtime_prompt"
  /bin/chmod 700 "$runtime_hook"
  /bin/chmod 700 "$runtime_dir"
  hook_command="${(q)zsh_bin} ${(q)runtime_hook}"
  settings_tmp=$(mktemp "$runtime_dir/.worker-settings.XXXXXX")

  "$CCO_JQ" -n \
    --arg hook "$hook_command" \
    --arg home "$CCO_HOME" \
    --arg root "$root" '
  {
    disableAllHooks: false,
    disableArtifact: true,
    disableClaudeAiConnectors: true,
    disableRemoteControl: true,
    permissions: {
      disableBypassPermissionsMode: "disable",
      deny: [
        "Edit(/" + $home + "/.claude/**)",
        "Edit(/" + $home + "/.codex/**)",
        "Edit(/" + $home + "/.agents/**)",
        "Read(/" + $home + "/**/.claude/settings.local.json)",
        "Edit(/" + $root + "/.claude/**)",
        "Edit(/" + $root + "/.codex/**)",
        "Edit(/" + $root + "/.agents/**)",
        "Edit(/" + $root + "/.git/**)",
        "Edit(/" + $root + "/CLAUDE.md)",
        "Edit(/" + $root + "/CLAUDE.local.md)",
        "Edit(/" + $root + "/.mcp.json)"
      ]
    },
    hooks: {
      SubagentStart: [{
        hooks: [{type: "command", command: $hook, timeout: 5}]
      }]
    }
  }
' > "$settings_tmp"
  /bin/chmod 600 "$settings_tmp"
  /bin/mv -- "$settings_tmp" "$runtime_settings"
  settings_tmp=""

  print -r -- "$parent_model" > "$registration/parent_model"
  print -r -- "$subagent_model" > "$registration/subagent_model"
fi

deny_rules=(
  'Bash(git commit *)' 'Bash(git * commit *)'
  'Bash(git push *)' 'Bash(git * push *)'
  'Bash(git pull *)' 'Bash(git * pull *)'
  'Bash(git fetch *)' 'Bash(git * fetch *)'
  'Bash(git tag *)' 'Bash(git * tag *)'
  'Bash(git merge *)' 'Bash(git * merge *)'
  'Bash(git rebase *)' 'Bash(git * rebase *)'
  'Bash(git cherry-pick *)' 'Bash(git * cherry-pick *)'
  'Bash(git reset --hard *)' 'Bash(git clean *)'
  'Bash(gh *)'
  'Bash(docker * start *)' 'Bash(docker * run *)' 'Bash(docker * exec *)'
  'Bash(docker * restart *)' 'Bash(docker * stop *)' 'Bash(docker * rm *)'
  'Bash(docker * up *)' 'Bash(docker * down *)'
  'Bash(brew services *)' 'Bash(launchctl *)' 'Bash(systemctl *)'
  'Bash(kubectl * apply *)' 'Bash(kubectl * delete *)' 'Bash(kubectl * rollout restart *)'
  'Bash(helm * install *)' 'Bash(helm * upgrade *)' 'Bash(helm * uninstall *)'
  'Bash(terraform * apply *)'
  'Bash(rsync *)' 'Bash(scp *)' 'Bash(ssh *)'
  'Bash(curl *)' 'Bash(wget *)'
  'Bash(nohup *)' 'Bash(setsid *)' 'Bash(disown *)' 'Bash(daemon *)'
  'Bash(npm publish *)' 'Bash(pnpm publish *)' 'Bash(yarn npm publish *)'
  'Bash(sudo *)' 'Bash(open *)' 'Bash(osascript *)' 'Bash(crontab *)'
  'Bash(defaults write *)'
  'Bash(*retire-native-fallback.zsh*)'
  'Bash(kill *)' 'Bash(pkill *)' 'Bash(shutdown *)' 'Bash(reboot *)'
  'Bash(rm -rf *)'
)

session_args=(--session-id "$session_uuid")
[[ "$mode" == "resume" ]] && session_args=(--resume "$session_uuid")

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"
ready_json=$("$CCO_JQ" -cn \
  --arg uuid "$session_uuid" \
  --arg name "$worker_name" \
  --arg root "$root" \
  --arg lease "$lease" \
  --arg mode "$mode" \
  --arg parent_model "$parent_model" \
  --arg subagent_model "$subagent_model" \
  '{uuid:$uuid,name:$name,root:$root,lease:$lease,mode:$mode,parent_model:$parent_model,subagent_model:$subagent_model}')
print -- "CODEX_PTY_WORKER_READY $ready_json"

cco_release_gate
gate_held=0
trap - EXIT HUP INT TERM

exec env \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 \
  CLAUDE_CODE_SUBAGENT_MODEL="$subagent_model" \
  "$claude_bin" \
  "${session_args[@]}" \
  --name "$worker_name" \
  --model "$parent_model" \
  --no-chrome \
  --ax-screen-reader \
  --setting-sources "" \
  --settings "$runtime_settings" \
  --strict-mcp-config \
  --append-system-prompt-file "$runtime_prompt" \
  --disallowedTools "${deny_rules[@]}"
