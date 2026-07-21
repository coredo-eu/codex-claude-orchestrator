#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: run-native-agent.zsh <role> <absolute-project-root>"
  print -u2 -- "       task instructions are read from stdin"
  exit 64
}

fail() {
  print -u2 -- "$1"
  exit "${2:-64}"
}

profile_scalar() {
  local key="$1"
  local value
  value=$(LC_ALL=C sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" "$profile")
  [[ -n "$value" && "$value" != *$'\n'* ]] || return 1
  print -r -- "$value"
}

profile_instructions() {
  LC_ALL=C awk '
    BEGIN { inside = 0; found = 0; closed = 0 }
    /^developer_instructions[[:space:]]*=[[:space:]]*"""[[:space:]]*$/ {
      if (found) exit 2
      inside = 1
      found = 1
      next
    }
    inside && /^"""[[:space:]]*$/ {
      inside = 0
      closed = 1
      next
    }
    inside { print }
    END { if (!found || !closed || inside) exit 3 }
  ' "$profile"
}

toml_basic_string() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  value=${value//$'\t'/\\t}
  print -r -- "\"${value}\""
}

(( $# == 2 )) || usage
role="$1"
root="$2"

case "$role" in
  source_explorer|reviewer|security_reviewer)
    required_sandbox="read-only"
    ;;
  mech_executor|test_runner)
    required_sandbox="workspace-write"
    ;;
  *) fail "NATIVE_ROLE_UNSUPPORTED: $role" ;;
esac

[[ "$root" == /* && -d "$root" ]] || usage
root=$(cd -P -- "$root" && pwd -P)
git_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$git_root" && -d "$git_root" ]] || fail "NATIVE_ROOT_NOT_GIT: $root" 66
root=$(cd -P -- "$git_root" && pwd -P)

[[ -n "${HOME:-}" && "$HOME" == /* ]] || fail "HOME_INVALID" 69
codex_home=${CODEX_HOME:-$HOME/.codex}
[[ "$codex_home" == /* ]] || fail "CODEX_HOME_MUST_BE_ABSOLUTE"

script_dir=${0:A:h}
runtime_lib="$script_dir/runtime-lib.zsh"
[[ -r "$runtime_lib" ]] || fail "NATIVE_RUNTIME_LIB_MISSING" 66
source "$runtime_lib"
cco_init
codeindexer_json=$(cco_codeindexer_mcp_json "$CCO_HOME/.claude.json" 0) || {
  fail "NATIVE_CODEINDEXER_CONFIG_INVALID: expected credential-free loopback CodeIndexer" 65
}
codeindexer_url=$(print -rn -- "$codeindexer_json" | "$CCO_JQ" -er '.mcpServers.codeindexer.url') || {
  fail "NATIVE_CODEINDEXER_CONFIG_INVALID: missing URL" 65
}
readonly_codeindexer_tools='["search_code","read_chunk","read_file_range","file_deps","find_bridges","find_by_signature","find_call_chain","find_callees","find_callers","find_execution_flows","find_references","find_related","find_test_coverage"]'
denied_codeindexer_tools='["analyze_corpus","audit_deps","audit_project","briefing","card_chat","consistency_check","find_citations","find_complex_functions","find_dead_code","find_prose_smells","find_tropes","history","investor_report","jobs","memory_cards","projects","refactor_candidates","reports","review_diff","roadmap","skills","solutions","teardown","tech_debt_report","telegram"]'
native_mcp_config="mcp_servers={codeindexer={url=\"$codeindexer_url\",enabled_tools=$readonly_codeindexer_tools,disabled_tools=$denied_codeindexer_tools,default_tools_approval_mode=\"approve\",required=true}}"

skill_dir=${script_dir:h}
profile="$codex_home/agents/$role.toml"
template="$skill_dir/assets/native-agents/$role.toml.in"
[[ -f "$profile" && ! -L "$profile" && -r "$profile" ]] || {
  fail "NATIVE_TRUSTED_ROLE_PROFILE_MISSING: $role (install with setup-native-agents.zsh --target user)" 66
}
[[ -f "$template" && ! -L "$template" && -r "$template" ]] || fail "NATIVE_ROLE_TEMPLATE_MISSING: $role" 66

profile_name=$(profile_scalar name) || fail "NATIVE_ROLE_PROFILE_INVALID: name"
model=$(profile_scalar model) || fail "NATIVE_ROLE_PROFILE_INVALID: model"
effort=$(profile_scalar model_reasoning_effort) || fail "NATIVE_ROLE_PROFILE_INVALID: model_reasoning_effort"
sandbox_mode=$(profile_scalar sandbox_mode) || fail "NATIVE_ROLE_PROFILE_INVALID: sandbox_mode"
instructions=$(profile_instructions) || fail "NATIVE_ROLE_PROFILE_INVALID: developer_instructions"

[[ "$profile_name" == "$role" ]] || fail "NATIVE_ROLE_PROFILE_MISMATCH: expected=$role actual=$profile_name"
[[ "$sandbox_mode" == "$required_sandbox" ]] || {
  fail "NATIVE_ROLE_SANDBOX_MISMATCH: role=$role expected=$required_sandbox actual=$sandbox_mode" 78
}
[[ -n "$model" && ${#model} -le 128 && "$model" =~ '^[A-Za-z0-9._:-]+$' ]] || {
  fail "NATIVE_ROLE_MODEL_INVALID" 78
}
case "$effort" in
  none|minimal|low|medium|high|xhigh|ultra) ;;
  *) fail "NATIVE_ROLE_EFFORT_INVALID" 78 ;;
esac
[[ -n "$instructions" ]] || fail "NATIVE_ROLE_PROFILE_INVALID: empty developer_instructions" 78
LC_ALL=C cmp -s "$profile" <(LC_ALL=C sed "s/@MODEL@/$model/g" "$template") || {
  fail "NATIVE_ROLE_PROFILE_CONTRACT_MISMATCH: $role" 78
}
instructions+=$'\nCodeIndexer boundary: use index tools only when the task supplies the exact indexed project name. Otherwise use ordinary source tools; do not guess a project name or request management tools.'

task=$(cat)
[[ -n "${task//[[:space:]]/}" ]] || fail "NATIVE_TASK_STDIN_REQUIRED"

if [[ -n "${CODEX_NATIVE_EXECUTABLE:-}" ]]; then
  codex_bin="$CODEX_NATIVE_EXECUTABLE"
  [[ "$codex_bin" == /* && -x "$codex_bin" ]] || fail "CODEX_NATIVE_EXECUTABLE_INVALID" 69
else
  codex_bin=$(command -v codex 2>/dev/null || true)
  [[ -n "$codex_bin" && -x "$codex_bin" ]] || fail "CODEX_EXECUTABLE_MISSING" 69
fi

developer_config=$(toml_basic_string "$instructions")
typeset -a command
command=(
  "$codex_bin" exec
  --ephemeral
  --ignore-user-config
  --sandbox "$sandbox_mode"
  --model "$model"
  --disable multi_agent
  --disable apps
  --disable hooks
  --config "model_reasoning_effort=\"$effort\""
  --config 'approval_policy="never"'
  --config 'web_search="disabled"'
  --config "$native_mcp_config"
  --config "developer_instructions=$developer_config"
  --cd "$root"
  -
)

print -u2 -- "CODEX_NATIVE_ISOLATED_START role=$role sandbox=$sandbox_mode model=$model index=codeindexer-readonly"
print -rn -- "$task" | "${command[@]}"
