#!/usr/bin/env zsh
set -u

deny() {
  print -r -- '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This worker has read-only CodeIndexer access."}}'
  exit 0
}

jq_bin=$(command -v jq 2>/dev/null) || deny
payload=$(<&0) || deny

tool_name=$(
  print -rn -- "$payload" | "$jq_bin" -er '
    select(.hook_event_name == "PreToolUse")
    | .tool_name
    | select(type == "string")
  ' 2>/dev/null
) || deny

print -rn -- "$payload" | "$jq_bin" -e '.tool_input | type == "object"' >/dev/null 2>&1 || deny

case "$tool_name" in
  mcp__codeindexer__search_code|\
  mcp__codeindexer__read_chunk|\
  mcp__codeindexer__read_file_range|\
  mcp__codeindexer__file_deps|\
  mcp__codeindexer__find_bridges|\
  mcp__codeindexer__find_by_signature|\
  mcp__codeindexer__find_call_chain|\
  mcp__codeindexer__find_callees|\
  mcp__codeindexer__find_callers|\
  mcp__codeindexer__find_execution_flows|\
  mcp__codeindexer__find_references|\
  mcp__codeindexer__find_related|\
  mcp__codeindexer__find_test_coverage)
    exit 0
    ;;
  mcp__codeindexer__projects)
    action=$(print -rn -- "$payload" | "$jq_bin" -er '.tool_input.action | select(type == "string")' 2>/dev/null) || deny
    case "$action" in
      list|report|outline|git_stats) exit 0 ;;
      diff)
        print -rn -- "$payload" | "$jq_bin" -e '(.tool_input.audit // false) == false' >/dev/null 2>&1 || deny
        exit 0
        ;;
      *) deny ;;
    esac
    ;;
  mcp__codeindexer__solutions|mcp__codeindexer__skills)
    action=$(print -rn -- "$payload" | "$jq_bin" -er '.tool_input.action | select(type == "string")' 2>/dev/null) || deny
    [[ "$action" == "find" ]] || deny
    exit 0
    ;;
  *) deny ;;
esac
