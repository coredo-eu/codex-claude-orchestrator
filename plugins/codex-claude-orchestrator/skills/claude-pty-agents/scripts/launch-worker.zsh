#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: launch-worker.zsh <absolute-worktree-root> [--resume <worker-uuid> | --successor-of <rotated-uuid>]"
  exit 64
}

script_dir=${0:A:h}
skill_dir=${script_dir:h}
source "$script_dir/runtime-lib.zsh"

(( $# == 1 || $# == 3 )) || usage
[[ "$1" == /* && -d "$1" ]] || usage

mode="new"
session_uuid=""
predecessor_uuid=""
if (( $# == 3 )); then
  cco_is_uuid "$3" || usage
  case "$2" in
    --resume)
      mode="resume"
      session_uuid="${3:l}"
      ;;
    --successor-of)
      predecessor_uuid="${3:l}"
      ;;
    *) usage ;;
  esac
fi

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
agents_file="$skill_dir/assets/worker-agents.json"
subagent_hook="$script_dir/worker-subagent-contract.zsh"
agent_router="$script_dir/worker-agent-router.zsh"
compaction_counter="$script_dir/worker-compaction-counter.zsh"
codeindexer_guard="$script_dir/worker-codeindexer-guard.zsh"
[[ -r "$prompt_file" ]] || cco_die 66 "WORKER_PROMPT_MISSING: $prompt_file"
[[ -r "$agents_file" ]] || cco_die 66 "WORKER_AGENTS_MISSING: $agents_file"
[[ -x "$subagent_hook" ]] || cco_die 66 "WORKER_SUBAGENT_HOOK_MISSING: $subagent_hook"
[[ -x "$agent_router" ]] || cco_die 66 "WORKER_AGENT_ROUTER_MISSING: $agent_router"
[[ -x "$compaction_counter" ]] || cco_die 66 "WORKER_COMPACTION_COUNTER_MISSING: $compaction_counter"
[[ -x "$codeindexer_guard" ]] || cco_die 66 "WORKER_CODEINDEXER_GUARD_MISSING: $codeindexer_guard"

worker_mcp_json=""
if [[ "$mode" == "new" ]]; then
  claude_state_file="$CCO_HOME/.claude.json"
  worker_mcp_json=$(cco_codeindexer_mcp_json "$claude_state_file" 0) || \
    cco_die 65 "WORKER_MCP_CONFIG_INVALID: expected credential-free loopback CodeIndexer at $claude_state_file"
fi

[[ -t 0 && -t 1 ]] || cco_die 69 "PTY_REQUIRED"
worker_group=$(cco_process_group $$)
[[ "$worker_group" == <-> && "$worker_group" -gt 1 && "$worker_group" == "$$" ]] || \
  cco_die 69 "PTY_PROCESS_GROUP_ISOLATION_REQUIRED: pid=$$ pgid=${worker_group:-unknown}; invoke the launcher as the PTY command or with exec"

parent_model=${CODEX_CLAUDE_PARENT_MODEL:-opus}
parent_effort="max"
runtime_schema="4"
legacy_subagent_model=""

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
# Ownership, not exclusivity: the lease is keyed by this session's own UUID, so
# any number of Codex-owned workers may run in the same canonical root. No
# standalone or foreign Claude process is ever discovered, inspected, or
# treated as a launch conflict.
lease="$CCO_LEASE_ROOT/$session_uuid"

context_threshold="$CCO_CONTEXT_COMPACTION_THRESHOLD"
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

lineage_id=""
registered_lineage_id=""
lineage_kind=""
if [[ "$mode" == "new" ]]; then
  lineage_kind="standalone"
  [[ -z "$predecessor_uuid" ]] || lineage_kind="attempt"
fi

if [[ "$mode" == "resume" ]]; then
  [[ ! -e "$registration/retirement.json" ]] || cco_die 77 "CLAUDE_RESUME_RETIRED: uuid=$session_uuid root=$root"
  cco_registration_matches "$registration" "$root" "$path_hash" "$thread_hash" "$session_uuid" || \
    cco_die 77 "CLAUDE_RESUME_OWNERSHIP_UNPROVEN: uuid=$session_uuid root=$root"
  [[ -r "$registration/runtime_schema_version" ]] || \
    cco_die 77 "CLAUDE_RESUME_SCHEMA_UNSUPPORTED: uuid=$session_uuid"
  runtime_schema=$(<"$registration/runtime_schema_version")
  case "$runtime_schema" in
    1)
      required_snapshots=(parent_model subagent_model runtime/worker-settings.json runtime/worker-system-prompt.txt runtime/worker-subagent-contract.zsh)
      ;;
    2)
      required_snapshots=(parent_model runtime/worker-agents.json runtime/worker-settings.json runtime/worker-system-prompt.txt runtime/worker-subagent-contract.zsh runtime/worker-agent-router.zsh)
      ;;
    3|4)
      required_snapshots=(parent_model runtime/worker-agents.json runtime/worker-settings.json runtime/worker-system-prompt.txt runtime/worker-subagent-contract.zsh runtime/worker-agent-router.zsh runtime/worker-compaction-counter.zsh)
      if [[ "$runtime_schema" == "4" ]]; then
        required_snapshots+=(runtime/worker-codeindexer-guard.zsh runtime/codeindexer-mcp.json)
      fi
      lineage_kind_file="$registration/lineage_kind"
      [[ -f "$lineage_kind_file" && ! -L "$lineage_kind_file" ]] || \
        cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid"
      lineage_kind="$(<"$lineage_kind_file")"
      predecessor_file="$registration/predecessor_session_uuid"
      lineage_file="$registration/lineage_id"
      case "$lineage_kind" in
        standalone)
          [[ ! -e "$predecessor_file" && ! -L "$predecessor_file" && ! -e "$lineage_file" && ! -L "$lineage_file" ]] || \
            cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid"
          ;;
        attempt)
          [[ -f "$predecessor_file" && ! -L "$predecessor_file" && -f "$lineage_file" && ! -L "$lineage_file" ]] || \
            cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid"
          predecessor_uuid="$(<"$predecessor_file")"
          cco_is_uuid "$predecessor_uuid" || cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid"
          predecessor_uuid="${predecessor_uuid:l}"
          registered_lineage_id="$(<"$lineage_file")"
          cco_is_short_text "$registered_lineage_id" 128 || cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid"
          ;;
        *) cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid" ;;
      esac
      ;;
    *) cco_die 77 "CLAUDE_RESUME_SCHEMA_UNSUPPORTED: uuid=$session_uuid schema=$runtime_schema" ;;
  esac
  for snapshot in "${required_snapshots[@]}"; do
    [[ -r "$registration/$snapshot" ]] || cco_die 77 "CLAUDE_RESUME_SNAPSHOT_INCOMPLETE: uuid=$session_uuid missing=$snapshot"
  done
  parent_model=$(<"$registration/parent_model")
  if [[ -f "$registration/parent_effort" && ! -L "$registration/parent_effort" ]]; then
    parent_effort=$(<"$registration/parent_effort")
  elif [[ -e "$registration/parent_effort" || -L "$registration/parent_effort" ]]; then
    cco_die 77 "CLAUDE_RESUME_EFFORT_INVALID: uuid=$session_uuid"
  else
    if [[ "$runtime_schema" != "1" ]]; then
      "$CCO_JQ" -e 'type == "object" and all(.[]; has("effort") | not)' \
        "$registration/runtime/worker-agents.json" >/dev/null 2>&1 || \
        cco_die 77 "CLAUDE_RESUME_EFFORT_MISSING: uuid=$session_uuid"
    fi
    parent_effort=""
  fi
  if [[ "$runtime_schema" == "1" ]]; then
    legacy_subagent_model=$(<"$registration/subagent_model")
  fi
fi

if [[ -n "$predecessor_uuid" ]]; then
  predecessor_registration="$CCO_SESSION_ROOT/$predecessor_uuid"
  cco_registration_matches "$predecessor_registration" "$root" "$path_hash" "$thread_hash" "$predecessor_uuid" || \
    cco_die 77 "CLAUDE_LINEAGE_OWNERSHIP_UNPROVEN: predecessor=$predecessor_uuid root=$root"
  predecessor_retirement="$predecessor_registration/retirement.json"
  [[ -r "$predecessor_retirement" ]] || \
    cco_die 75 "CLAUDE_LINEAGE_PREDECESSOR_NOT_ROTATED: predecessor=$predecessor_uuid"
  predecessor_state=$("$CCO_JQ" -r '.state // empty' "$predecessor_retirement" 2>/dev/null || true)
  [[ "$predecessor_state" == "rotated_context" ]] || \
    cco_die 75 "CLAUDE_LINEAGE_PREDECESSOR_NOT_ROTATED: predecessor=$predecessor_uuid state=${predecessor_state:-invalid}"
  lineage_id=$("$CCO_JQ" -r '.lineage_id // empty' "$predecessor_retirement" 2>/dev/null || true)
  cco_is_short_text "$lineage_id" 128 || cco_die 75 "CLAUDE_LINEAGE_ID_MISSING: predecessor=$predecessor_uuid"
  [[ -z "$registered_lineage_id" || "$registered_lineage_id" == "$lineage_id" ]] || \
    cco_die 77 "CLAUDE_RESUME_LINEAGE_INVALID: uuid=$session_uuid predecessor=$predecessor_uuid"
fi

cco_validate_model "$parent_model" || cco_die 64 "INVALID_PARENT_MODEL"
[[ -z "$parent_effort" || "$parent_effort" == "max" ]] || cco_die 64 "INVALID_PARENT_EFFORT"
[[ "$runtime_schema" != "1" ]] || cco_validate_model "$legacy_subagent_model" || cco_die 64 "INVALID_SUBAGENT_MODEL"

# Only this session's own lease is consulted. A resume must prove the session
# it names is fully dead, which is what rejects a duplicate resume of a live
# UUID; a live worker in the same root under a different UUID is irrelevant.
if [[ "$mode" == "resume" ]]; then
  if live_reason=$(cco_worker_live_reason "$session_uuid"); then
    cco_die 75 "CLAUDE_RESUME_WORKER_STILL_LIVE: $live_reason"
  fi
  for stale_lease in "$CCO_LEASE_ROOT/$session_uuid" "$CCO_LEASE_ROOT/$path_hash"; do
    [[ -d "$stale_lease" && ! -L "$stale_lease" ]] || continue
    [[ -r "$stale_lease/session_uuid" ]] || continue
    [[ "$(<"$stale_lease/session_uuid")" == "$session_uuid" ]] || continue
    stale="$CCO_LEASE_ROOT/.stale-${session_uuid}-$$-${stale_lease:t}"
    /bin/mv -- "$stale_lease" "$stale" 2>/dev/null || cco_die 75 "LEASE_RECLAIM_FAILED: $stale_lease"
    [[ "$stale" == "$CCO_LEASE_ROOT"/.stale-* ]] || cco_die 70 "UNSAFE_STALE_PATH"
    /bin/rm -rf -- "$stale"
  done
fi

# A fresh UUID must never already hold a lease, and a reclaimed one was just
# removed above. Either way an existing lease here is unexplained state.
[[ ! -e "$lease" ]] || cco_die 75 "LEASE_CONFLICT: uuid=$session_uuid lease=$lease"
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
  print -r -- "4" > "$registration/runtime_schema_version"
  print -r -- "0.3.1" > "$registration/runtime_version"
  print -r -- "$lineage_kind" > "$registration/lineage_kind"
  if [[ -n "$predecessor_uuid" ]]; then
    print -r -- "$predecessor_uuid" > "$registration/predecessor_session_uuid"
    print -r -- "$lineage_id" > "$registration/lineage_id"
  fi
  /bin/mkdir -- "$registration/context"
  print -r -- "1" > "$registration/context/context_schema_version"
  : > "$registration/context/compactions.log"
  print -r -- "0" > "$registration/context/acknowledged_compactions"
  /bin/chmod 700 "$registration/context"
  /bin/chmod 600 "$registration/context/"*
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
runtime_agent_router="$runtime_dir/worker-agent-router.zsh"
runtime_compaction_counter="$runtime_dir/worker-compaction-counter.zsh"
runtime_codeindexer_guard="$runtime_dir/worker-codeindexer-guard.zsh"
runtime_mcp="$runtime_dir/codeindexer-mcp.json"
runtime_settings="$runtime_dir/worker-settings.json"
runtime_agents="$runtime_dir/worker-agents.json"
registration_context_dir="$registration/context"
compaction_command="${(q)zsh_bin} ${(q)runtime_compaction_counter} ${(q)registration_context_dir}"
codeindexer_command="${(q)zsh_bin} ${(q)runtime_codeindexer_guard}"
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
  /bin/cp -- "$agents_file" "$runtime_agents"
  /bin/cp -- "$subagent_hook" "$runtime_hook"
  /bin/cp -- "$agent_router" "$runtime_agent_router"
  /bin/cp -- "$compaction_counter" "$runtime_compaction_counter"
  /bin/cp -- "$codeindexer_guard" "$runtime_codeindexer_guard"
  print -r -- "$worker_mcp_json" > "$runtime_mcp"
  /bin/chmod 600 "$runtime_prompt"
  /bin/chmod 600 "$runtime_agents"
  /bin/chmod 700 "$runtime_hook"
  /bin/chmod 700 "$runtime_agent_router"
  /bin/chmod 700 "$runtime_compaction_counter"
  /bin/chmod 700 "$runtime_codeindexer_guard"
  /bin/chmod 600 "$runtime_mcp"
  /bin/chmod 700 "$runtime_dir"
  hook_command="${(q)zsh_bin} ${(q)runtime_hook}"
  router_command="${(q)zsh_bin} ${(q)runtime_agent_router}"
  settings_tmp=$(mktemp "$runtime_dir/.worker-settings.XXXXXX")

  "$CCO_JQ" -n \
    --arg hook "$hook_command" \
    --arg router "$router_command" \
    --arg codeindexer "$codeindexer_command" \
    --arg compaction "$compaction_command" \
    --arg home "$CCO_HOME" \
    --arg root "$root" '
  {
    disableAllHooks: false,
    disableArtifact: true,
    disableClaudeAiConnectors: true,
    disableRemoteControl: true,
    permissions: {
      defaultMode: "auto",
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
      PreToolUse: [
        {
          matcher: "Agent",
          hooks: [{type: "command", command: $router, timeout: 5}]
        },
        {
          matcher: "mcp__codeindexer__.*",
          hooks: [{type: "command", command: $codeindexer, timeout: 5}]
        }
      ],
      SubagentStart: [{
        hooks: [{type: "command", command: $hook, timeout: 5}]
      }],
      PostCompact: [{
        hooks: [{type: "command", command: $compaction, timeout: 5}]
      }]
    }
  }
' > "$settings_tmp"
  /bin/chmod 600 "$settings_tmp"
  /bin/mv -- "$settings_tmp" "$runtime_settings"
  settings_tmp=""

  print -r -- "$parent_model" > "$registration/parent_model"
  print -r -- "$parent_effort" > "$registration/parent_effort"
fi

if [[ "$runtime_schema" != "1" ]]; then
  "$CCO_JQ" -e '
    type == "object" and
    (keys | sort) == [
      "debugger", "explorer", "implementer", "log-analyzer",
      "long-horizon", "reviewer", "security-reviewer", "test-triager"
    ] and
    .explorer.model == "haiku" and
    .["log-analyzer"].model == "haiku" and
    .["test-triager"].model == "haiku" and
    .implementer.model == "sonnet" and
    .debugger.model == "sonnet" and
    .reviewer.model == "opus" and
    .["security-reviewer"].model == "opus" and
    .["long-horizon"].model == "fable" and
    (
      (all(.[]; has("effort") | not)) or
      (
        (.explorer | has("effort") | not) and
        (.["log-analyzer"] | has("effort") | not) and
        (.["test-triager"] | has("effort") | not) and
        .implementer.effort == "high" and
        .debugger.effort == "xhigh" and
        .reviewer.effort == "high" and
        .["security-reviewer"].effort == "xhigh" and
        .["long-horizon"].effort == "xhigh"
      )
    ) and
    .explorer.tools == ["Read", "Grep", "Glob", "Bash"] and
    .["log-analyzer"].tools == ["Read", "Grep", "Glob", "Bash"] and
    .["test-triager"].tools == ["Read", "Grep", "Glob", "Bash"] and
    .implementer.tools == ["Read", "Grep", "Glob", "Edit", "Write", "Bash"] and
    .debugger.tools == ["Read", "Grep", "Glob", "Bash"] and
    .reviewer.tools == ["Read", "Grep", "Glob", "Bash"] and
    .["security-reviewer"].tools == ["Read", "Grep", "Glob", "Bash"] and
    .["long-horizon"].tools == ["Read", "Grep", "Glob", "Edit", "Write", "Bash"] and
    all(to_entries[];
      (.value.description | type) == "string" and
      (.value.prompt | type) == "string" and
      (if (.key == "implementer" or .key == "long-horizon") then
        (.value | del(.effort) | keys | sort) == ["description", "model", "prompt", "tools"]
      else
        (.value | del(.effort) | keys | sort) == ["description", "model", "permissionMode", "prompt", "tools"] and
        .value.permissionMode == "plan"
      end)
    )
  ' "$runtime_agents" >/dev/null || cco_die 66 "WORKER_AGENTS_INVALID: $runtime_agents"
  agents_json=$(<"$runtime_agents")
  agent_models=$("$CCO_JQ" -c 'with_entries(.value = .value.model)' "$runtime_agents")
else
  agents_json=""
  agent_models=$("$CCO_JQ" -cn --arg model "$legacy_subagent_model" '{"*":$model}')
fi

if [[ "$runtime_schema" == "3" || "$runtime_schema" == "4" ]]; then
  pinned_compaction_command=$("$CCO_JQ" -er '
    .hooks.PostCompact
    | select(type == "array" and length == 1)
    | .[0].hooks
    | select(type == "array" and length == 1)
    | .[0]
    | select(.type == "command" and .timeout == 5)
    | .command
  ' "$runtime_settings" 2>/dev/null) || \
    cco_die 66 "WORKER_COMPACTION_HOOK_INVALID: $runtime_settings"
  [[ "$pinned_compaction_command" == "$compaction_command" ]] || \
    cco_die 66 "WORKER_COMPACTION_HOOK_INVALID: $runtime_settings"
fi

if [[ "$runtime_schema" == "4" ]]; then
  [[ -x "$runtime_codeindexer_guard" ]] || \
    cco_die 66 "WORKER_CODEINDEXER_GUARD_INVALID: $runtime_codeindexer_guard"
  worker_mcp_json=$(cco_codeindexer_mcp_json "$runtime_mcp" 1) || \
    cco_die 66 "WORKER_MCP_CONFIG_INVALID: $runtime_mcp"
  pinned_codeindexer_command=$("$CCO_JQ" -er '
    .hooks.PreToolUse
    | select(type == "array" and length == 2)
    | .[1]
    | select(.matcher == "mcp__codeindexer__.*")
    | .hooks
    | select(type == "array" and length == 1)
    | .[0]
    | select(.type == "command" and .timeout == 5)
    | .command
  ' "$runtime_settings" 2>/dev/null) || \
    cco_die 66 "WORKER_CODEINDEXER_HOOK_INVALID: $runtime_settings"
  [[ "$pinned_codeindexer_command" == "$codeindexer_command" ]] || \
    cco_die 66 "WORKER_CODEINDEXER_HOOK_INVALID: $runtime_settings"
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
  'Bash(*assign-worker.zsh*)' 'Bash(*rotate-worker.zsh*)'
  'Bash(*retire-native-fallback.zsh*)'
  'Bash(kill *)' 'Bash(pkill *)' 'Bash(shutdown *)' 'Bash(reboot *)'
  'Bash(rm -rf *)'
)
if [[ "$runtime_schema" != "1" ]]; then
  deny_rules=(
    'Agent(Explore)' 'Agent(Plan)' 'Agent(general-purpose)'
    'Agent(statusline-setup)' 'Agent(claude-code-guide)'
    "${deny_rules[@]}"
  )
fi

session_args=(--session-id "$session_uuid")
[[ "$mode" == "resume" ]] && session_args=(--resume "$session_uuid")

[[ ! -e "$CCO_DISABLED_MARKER" ]] || cco_die 78 "CLAUDE_AGENTS_DISABLED: $CCO_DISABLED_MARKER"

context_compactions=0
context_acknowledged=0
if [[ "$runtime_schema" == "3" || "$runtime_schema" == "4" ]]; then
  context_counts=$(cco_context_counts "$registration") || \
    cco_die 70 "CLAUDE_CONTEXT_CORRUPT: uuid=$session_uuid"
  context_compactions="${context_counts%% *}"
  context_acknowledged="${context_counts##* }"
  if (( context_compactions < context_threshold )); then
    context_state="observed"
  elif (( context_acknowledged == context_compactions )); then
    context_state="continued"
  else
    context_state="decision_required"
  fi
else
  context_state="unobserved_legacy"
fi

ready_json=$("$CCO_JQ" -cn \
  --arg uuid "$session_uuid" \
  --arg name "$worker_name" \
  --arg root "$root" \
  --arg lease "$lease" \
  --arg mode "$mode" \
  --arg parent_model "$parent_model" \
  --arg runtime_schema "$runtime_schema" \
  --arg context_state "$context_state" \
  --arg lineage_kind "$lineage_kind" \
  --arg predecessor_uuid "$predecessor_uuid" \
  --arg lineage_id "$lineage_id" \
  --argjson context_compactions "$context_compactions" \
  --argjson context_acknowledged "$context_acknowledged" \
  --argjson agent_models "$agent_models" \
  '{uuid:$uuid,name:$name,root:$root,lease:$lease,mode:$mode,
    runtime_schema:$runtime_schema,parent_model:$parent_model,agent_models:$agent_models,
    context_state:$context_state,context_compactions:$context_compactions,
    context_acknowledged:$context_acknowledged,
    lineage_kind:(if $lineage_kind == "" then null else $lineage_kind end),
    predecessor_session_uuid:(if $predecessor_uuid == "" then null else $predecessor_uuid end),
    lineage_id:(if $lineage_id == "" then null else $lineage_id end)}')
print -r -- "CODEX_PTY_WORKER_READY $ready_json"

cco_release_gate
gate_held=0
trap - EXIT HUP INT TERM

typeset -a model_env agent_args builtin_agent_env mcp_args effort_env effort_args
if [[ "$runtime_schema" == "1" ]]; then
  model_env=("CLAUDE_CODE_SUBAGENT_MODEL=$legacy_subagent_model")
  agent_args=()
  builtin_agent_env=()
else
  model_env=(-u CLAUDE_CODE_SUBAGENT_MODEL -u CODEX_CLAUDE_SUBAGENT_MODEL)
  agent_args=(--agents "$agents_json")
  builtin_agent_env=(CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1)
fi
effort_env=(-u CLAUDE_CODE_EFFORT_LEVEL)
effort_args=()
if [[ -n "$parent_effort" ]]; then
  effort_args=(--effort "$parent_effort")
fi
mcp_args=()
[[ "$runtime_schema" != "4" ]] || mcp_args=(--mcp-config "$runtime_mcp")

exec /usr/bin/env \
  "${effort_env[@]}" \
  "${model_env[@]}" \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
  "${builtin_agent_env[@]}" \
  CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 \
  "$claude_bin" \
  "${session_args[@]}" \
  --name "$worker_name" \
  --model "$parent_model" \
  "${effort_args[@]}" \
  "${agent_args[@]}" \
  --no-chrome \
  --ax-screen-reader \
  --setting-sources "" \
  --settings "$runtime_settings" \
  --strict-mcp-config \
  "${mcp_args[@]}" \
  --append-system-prompt-file "$runtime_prompt" \
  --disallowedTools "${deny_rules[@]}"
