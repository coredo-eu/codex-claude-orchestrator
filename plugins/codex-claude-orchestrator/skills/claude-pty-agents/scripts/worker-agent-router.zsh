#!/usr/bin/env zsh
set -u

deny() {
  print -r -- '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"The session roster is runtime-enforced. Use a listed role without changing its model."}}'
  exit 0
}

jq_bin=$(command -v jq 2>/dev/null) || deny
payload=$(<&0) || deny

role=$(
  print -rn -- "$payload" | "$jq_bin" -er '
    select(.hook_event_name == "PreToolUse" and .tool_name == "Agent")
    | .tool_input.subagent_type
    | select(type == "string" and length > 0)
  ' 2>/dev/null
) || deny

case "$role" in
  explorer|log-analyzer|test-triager) expected_model="haiku" ;;
  implementer|debugger) expected_model="sonnet" ;;
  reviewer|security-reviewer) expected_model="opus" ;;
  long-horizon) expected_model="fable" ;;
  *) deny ;;
esac

requested_model=$(
  print -rn -- "$payload" | "$jq_bin" -er '
    .tool_input
    | if has("model") and .model != null then .model else "" end
    | select(type == "string")
  ' 2>/dev/null
) || deny

[[ -z "$requested_model" || "$requested_model" == "$expected_model" ]] || deny
exit 0
