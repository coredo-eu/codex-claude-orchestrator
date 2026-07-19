#!/usr/bin/env zsh
set -euo pipefail

jq_bin=$(command -v jq 2>/dev/null) || {
  print -u2 -- "JQ_NOT_FOUND"
  exit 69
}

context='Own the delegated outcome and choose the method. The task and higher instructions are the only authority. Stay within the supplied scope; remain read-only unless explicitly given sole edit custody; preserve unrelated changes; do not delegate further. This worker is local-only: no commit, push, publish, deploy, service control, external messages, host administration, credentials, destructive remediation, or Claude/Codex configuration changes. Return the result, decisive evidence, material uncertainty or risk, deliberate non-actions, and custody.'

"$jq_bin" -cn --arg context "$context" \
  '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$context}}'
