#!/usr/bin/env zsh
set -u

# Parent-only PreToolUse checkpoint. It persists counters and usage metadata,
# never transcript content. A checkpoint blocks another tool call but does not
# claim completion, transfer custody, retire, or signal the worker.

registration="${1:-}"
lock_dir=""
jq_bin=$(command -v jq 2>/dev/null || true)

cleanup() {
  if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then
    /bin/rmdir -- "$lock_dir" 2>/dev/null || true
  fi
}

emit_deny() {
  local reason="${1:-Stage health state is unavailable.}"
  cleanup
  if [[ -n "$jq_bin" ]]; then
    "$jq_bin" -cn --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  else
    print -r -- '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Stage health state is unavailable. Stop tool use and return the Required handoff with custody."}}'
  fi
  exit 0
}

emit_warning() {
  local context="$1"
  cleanup
  "$jq_bin" -cn --arg context "$context" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$context}}'
  exit 0
}

write_scalar() {
  local target="$1" value="$2" tmp
  tmp=$(mktemp "${target:h}/.${target:t}.XXXXXX") || return 1
  print -r -- "$value" > "$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  /bin/chmod 600 "$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  /bin/mv -- "$tmp" "$target" || { /bin/rm -f -- "$tmp"; return 1; }
}

write_json() {
  local target="$1" value="$2" tmp
  tmp=$(mktemp "${target:h}/.${target:t}.XXXXXX") || return 1
  print -rn -- "$value" > "$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  /bin/chmod 600 "$tmp" || { /bin/rm -f -- "$tmp"; return 1; }
  /bin/mv -- "$tmp" "$target" || { /bin/rm -f -- "$tmp"; return 1; }
}

file_size() {
  local path="$1" observed
  observed=$(/usr/bin/stat -f '%z' "$path" 2>/dev/null) || \
    observed=$(/usr/bin/stat -c '%s' "$path" 2>/dev/null) || return 1
  [[ "$observed" == <-> ]] || return 1
  print -r -- "$observed"
}

payload=$(<&0) || emit_deny
[[ -n "$jq_bin" ]] || emit_deny

event=$(
  print -rn -- "$payload" | "$jq_bin" -cer '
    select(.hook_event_name == "PreToolUse")
    | {
        session_id:(.session_id | select(type == "string")),
        transcript_path:(.transcript_path // "" | select(type == "string")),
        tool_name:(.tool_name | select(type == "string")),
        agent_id:(.agent_id // "" | select(type == "string")),
        agent_role:(if (.tool_input.subagent_type? | type) == "string" then .tool_input.subagent_type else "" end)
      }
  ' 2>/dev/null
) || emit_deny

# Settings hooks also run inside subagents. Their work is bounded by the parent
# Agent call and role contract, so do not double-count their internal tools.
[[ "$(print -rn -- "$event" | "$jq_bin" -r '.agent_id')" == "" ]] || exit 0

[[ "$registration" == /* && -d "$registration" && ! -L "$registration" ]] || emit_deny
health="$registration/health"
[[ -d "$health" && ! -L "$health" ]] || emit_deny
[[ ! -e "$registration/retirement.json" && ! -L "$registration/retirement.json" ]] || \
  emit_deny "This worker is retired. Stop tool use and return custody to Codex."

session_id=$(print -rn -- "$event" | "$jq_bin" -r '.session_id')
[[ -f "$registration/session_uuid" && ! -L "$registration/session_uuid" && \
   "$(<"$registration/session_uuid")" == "$session_id" ]] || emit_deny

for attempt in {1..50}; do
  if /bin/mkdir -- "$health/.stage-guard.lock" 2>/dev/null; then
    lock_dir="$health/.stage-guard.lock"
    break
  fi
  /bin/sleep 0.01
done
[[ -n "$lock_dir" ]] || emit_deny "Stage health accounting is busy or ambiguous. Stop tool use and return the Required handoff with custody."
trap 'cleanup' EXIT HUP INT TERM

required_files=(
  health_schema_version policy.json assignment.json parent_tool_calls agent_calls
  agent_calls_by_role.json transcript_cursor_bytes max_cache_read_input_tokens
  request_keys.log warning_emitted
)
for file in "${required_files[@]}"; do
  [[ -f "$health/$file" && ! -L "$health/$file" ]] || emit_deny
done
[[ "$(<"$health/health_schema_version")" == "1" ]] || emit_deny
if [[ -e "$health/checkpoint.json" || -L "$health/checkpoint.json" ]]; then
  [[ -f "$health/checkpoint.json" && ! -L "$health/checkpoint.json" ]] || emit_deny
  "$jq_bin" -e '
    type == "object" and .schema_version == 1 and .state == "checkpoint" and
    (.task_id | type == "string" and length > 0 and length <= 200) and
    (.observed_at_epoch | type == "number" and floor == . and . >= 0) and
    (.reasons | type == "array" and length > 0 and all(.[]; type == "string"))
  ' "$health/checkpoint.json" >/dev/null 2>&1 || emit_deny
  emit_deny "This bounded stage is checkpointed. Do not call more tools. Return the compact Required handoff and custody; the checkpoint is not outer-goal completion."
fi

policy=$(
  "$jq_bin" -cer '
    select(type == "object" and .schema_version == 1)
    | select(all(
        .warn_requests,.max_requests,.warn_cache_read_input_tokens,
        .max_cache_read_input_tokens,.warn_elapsed_seconds,.max_elapsed_seconds,
        .warn_parent_tool_calls,.max_parent_tool_calls;
        type == "number" and floor == . and . >= 0
      ))
    | select((.max_requests == 0 or .warn_requests < .max_requests) and
             (.max_cache_read_input_tokens == 0 or .warn_cache_read_input_tokens < .max_cache_read_input_tokens) and
             (.max_elapsed_seconds == 0 or .warn_elapsed_seconds < .max_elapsed_seconds) and
             (.max_parent_tool_calls > 0 and .warn_parent_tool_calls < .max_parent_tool_calls))
  ' "$health/policy.json" 2>/dev/null
) || emit_deny
assignment=$(
  "$jq_bin" -cer '
    select(type == "object" and .schema_version == 1)
    | select(.assigned_at_epoch | type == "number" and floor == . and . >= 0)
    | select((.task_id == null) or (.task_id | type == "string" and length > 0 and length <= 200 and (contains("\\n") | not)))
  ' "$health/assignment.json" 2>/dev/null
) || emit_deny

assigned_at=$(print -rn -- "$assignment" | "$jq_bin" -r '.assigned_at_epoch')
task_id=$(print -rn -- "$assignment" | "$jq_bin" -r '.task_id // ""')
if (( assigned_at == 0 )); then
  cleanup
  exit 0
fi

parent_calls=$(<"$health/parent_tool_calls")
agent_calls=$(<"$health/agent_calls")
agent_calls_by_role=$("$jq_bin" -cer '
  select(
    type == "object" and .schema_version == 1 and
    (keys | sort) == ["calls","schema_version"] and
    (.calls | type == "object") and
    (.calls | keys | sort) == ["debugger","explorer","implementer","log-analyzer","long-horizon","reviewer","scout","security-reviewer","test-triager"] and
    all(.calls[]; type == "number" and floor == . and . >= 0)
  )
' "$health/agent_calls_by_role.json" 2>/dev/null) || emit_deny
cursor=$(<"$health/transcript_cursor_bytes")
max_cache=$(<"$health/max_cache_read_input_tokens")
warning_emitted=$(<"$health/warning_emitted")
[[ "$parent_calls" == <-> && "$agent_calls" == <-> && "$cursor" == <-> && \
   "$max_cache" == <-> && ( "$warning_emitted" == "0" || "$warning_emitted" == "1" ) ]] || emit_deny

(( parent_calls += 1 ))
tool_name=$(print -rn -- "$event" | "$jq_bin" -r '.tool_name')
agent_role=$(print -rn -- "$event" | "$jq_bin" -r '.agent_role')
if [[ "$tool_name" == "Agent" ]]; then
  (( agent_calls += 1 ))
  case "$agent_role" in
    explorer|log-analyzer|test-triager|scout|implementer|debugger|reviewer|security-reviewer|long-horizon)
      agent_calls_by_role=$(print -rn -- "$agent_calls_by_role" | "$jq_bin" -cer --arg role "$agent_role" '.calls[$role] += 1') || emit_deny
      ;;
  esac
fi
write_scalar "$health/parent_tool_calls" "$parent_calls" || emit_deny
write_scalar "$health/agent_calls" "$agent_calls" || emit_deny
write_json "$health/agent_calls_by_role.json" "$agent_calls_by_role" || emit_deny

transcript_state="unavailable"
transcript_path=$(print -rn -- "$event" | "$jq_bin" -r '.transcript_path')
projects_root="${HOME:-}/.claude/projects"
if [[ -n "${HOME:-}" && "$HOME" == /* && -d "$projects_root" && ! -L "$projects_root" && \
      "$transcript_path" == /* && -f "$transcript_path" && ! -L "$transcript_path" ]]; then
  projects_root=$(cd -P -- "$projects_root" 2>/dev/null && pwd -P) || projects_root=""
  transcript_dir=$(cd -P -- "${transcript_path:h}" 2>/dev/null && pwd -P) || transcript_dir=""
  transcript_real="$transcript_dir/${transcript_path:t}"
  if [[ -n "$projects_root" && "$transcript_real" == "$projects_root"/* && \
        "${transcript_real:t}" == "$session_id.jsonl" ]]; then
    current_size=$(file_size "$transcript_real" 2>/dev/null || true)
    if [[ "$current_size" == <-> && "$current_size" -ge "$cursor" ]]; then
      delta=$(( current_size - cursor ))
      observations=""
      parse_status=0
      if (( delta > 0 )); then
        observations=$(
          /usr/bin/tail -c "+$(( cursor + 1 ))" "$transcript_real" 2>/dev/null \
            | /usr/bin/head -c "$delta" \
            | "$jq_bin" -rc '
                select(.type == "assistant" and .isSidechain != true)
                | select(.message.usage | type == "object")
                | [
                    (.requestId // .message.id // .uuid // empty),
                    (.message.usage.cache_read_input_tokens // 0)
                  ]
                | select(.[0] | type == "string" and length > 0 and length <= 200)
                | select(.[0] | test("^[A-Za-z0-9._:-]+$"))
                | select(.[1] | type == "number" and floor == . and . >= 0)
                | @tsv
              ' 2>/dev/null
        ) || parse_status=$?
      fi
      if (( parse_status == 0 )); then
        transcript_state="observed"
        if [[ -n "$observations" ]]; then
          while IFS=$'\t' read -r request_key cache_read; do
            [[ -n "$request_key" && "$request_key" != *$'\n'* && "$cache_read" == <-> ]] || continue
            if ! /usr/bin/grep -Fqx -- "$request_key" "$health/request_keys.log" 2>/dev/null; then
              print -r -- "$request_key" >> "$health/request_keys.log" || emit_deny
            fi
            (( cache_read <= max_cache )) || max_cache="$cache_read"
          done <<< "$observations"
        fi
        write_scalar "$health/max_cache_read_input_tokens" "$max_cache" || emit_deny
        write_scalar "$health/transcript_cursor_bytes" "$current_size" || emit_deny
      fi
    fi
  fi
fi

request_count=$(/usr/bin/awk 'END { print NR + 0 }' "$health/request_keys.log" 2>/dev/null) || emit_deny
[[ "$request_count" == <-> ]] || emit_deny
now_epoch=$(date +%s)
[[ "$now_epoch" == <-> && "$now_epoch" -ge "$assigned_at" ]] || emit_deny
elapsed=$(( now_epoch - assigned_at ))

warn_requests=$(print -rn -- "$policy" | "$jq_bin" -r '.warn_requests')
max_requests=$(print -rn -- "$policy" | "$jq_bin" -r '.max_requests')
warn_cache=$(print -rn -- "$policy" | "$jq_bin" -r '.warn_cache_read_input_tokens')
max_cache_policy=$(print -rn -- "$policy" | "$jq_bin" -r '.max_cache_read_input_tokens')
warn_elapsed=$(print -rn -- "$policy" | "$jq_bin" -r '.warn_elapsed_seconds')
max_elapsed=$(print -rn -- "$policy" | "$jq_bin" -r '.max_elapsed_seconds')
warn_parent_calls=$(print -rn -- "$policy" | "$jq_bin" -r '.warn_parent_tool_calls')
max_parent_calls=$(print -rn -- "$policy" | "$jq_bin" -r '.max_parent_tool_calls')

typeset -a checkpoint_reasons warning_reasons
(( max_requests > 0 && request_count >= max_requests )) && checkpoint_reasons+=("requests")
(( max_cache_policy > 0 && max_cache >= max_cache_policy )) && checkpoint_reasons+=("cache_read_input_tokens")
(( max_elapsed > 0 && elapsed >= max_elapsed )) && checkpoint_reasons+=("elapsed_seconds")
(( parent_calls >= max_parent_calls )) && checkpoint_reasons+=("parent_tool_calls")
(( warn_requests > 0 && request_count >= warn_requests )) && warning_reasons+=("requests")
(( warn_cache > 0 && max_cache >= warn_cache )) && warning_reasons+=("cache_read_input_tokens")
(( warn_elapsed > 0 && elapsed >= warn_elapsed )) && warning_reasons+=("elapsed_seconds")
(( warn_parent_calls > 0 && parent_calls >= warn_parent_calls )) && warning_reasons+=("parent_tool_calls")

state="healthy"
(( ${#warning_reasons[@]} == 0 )) || state="warning"
(( ${#checkpoint_reasons[@]} == 0 )) || state="checkpoint"
observation_tmp=$(mktemp "$health/.last-observation.XXXXXX") || emit_deny
"$jq_bin" -cn \
  --arg task_id "$task_id" --arg state "$state" --arg transcript_state "$transcript_state" \
  --argjson observed_at_epoch "$now_epoch" --argjson assigned_at_epoch "$assigned_at" \
  --argjson elapsed_seconds "$elapsed" --argjson parent_tool_calls "$parent_calls" \
  --argjson agent_calls "$agent_calls" --argjson requests "$request_count" \
  --argjson agent_calls_by_role "$(if [[ -n "$agent_calls_by_role" ]]; then print -rn -- "$agent_calls_by_role" | "$jq_bin" -c '.calls'; else print -r -- null; fi)" \
  --argjson max_cache_read_input_tokens "$max_cache" \
  --argjson warning_reasons "$(printf '%s\n' "${warning_reasons[@]}" | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson checkpoint_reasons "$(printf '%s\n' "${checkpoint_reasons[@]}" | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0))')" \
  '{schema_version:1,task_id:$task_id,state:$state,transcript_state:$transcript_state,
    observed_at_epoch:$observed_at_epoch,assigned_at_epoch:$assigned_at_epoch,
    elapsed_seconds:$elapsed_seconds,parent_tool_calls:$parent_tool_calls,agent_calls:$agent_calls,agent_calls_by_role:$agent_calls_by_role,
    requests:$requests,max_cache_read_input_tokens:$max_cache_read_input_tokens,
    warning_reasons:$warning_reasons,checkpoint_reasons:$checkpoint_reasons}' > "$observation_tmp" || emit_deny
/bin/chmod 600 "$observation_tmp" && /bin/mv -- "$observation_tmp" "$health/last_observation.json" || emit_deny

if (( ${#checkpoint_reasons[@]} > 0 )); then
  checkpoint_tmp=$(mktemp "$health/.checkpoint.XXXXXX") || emit_deny
  "$jq_bin" -cn --arg task_id "$task_id" --argjson observed_at_epoch "$now_epoch" \
    --argjson reasons "$(printf '%s\n' "${checkpoint_reasons[@]}" | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0))')" \
    '{schema_version:1,state:"checkpoint",task_id:$task_id,observed_at_epoch:$observed_at_epoch,reasons:$reasons}' \
    > "$checkpoint_tmp" || emit_deny
  /bin/chmod 600 "$checkpoint_tmp" && /bin/mv -- "$checkpoint_tmp" "$health/checkpoint.json" || emit_deny
  emit_deny "Stage runtime checkpoint reached (${(j:,:)checkpoint_reasons}). Do not call more tools. Return the compact Required handoff and custody. Use ready_for_verification only if Done when already holds; otherwise return blocked. This checkpoint is not outer-goal completion."
fi

if (( ${#warning_reasons[@]} > 0 && warning_emitted == 0 )); then
  write_scalar "$health/warning_emitted" "1" || emit_deny
  emit_warning "Stage health warning (${(j:,:)warning_reasons}). Reassess the bounded stage; if independent evidence, context isolation, or safe parallelism has expected net value after transfer and integration costs, use the eligible role whose description matches. Long-horizon remains explicit-only. No completion or custody transfer occurred."
fi

cleanup
exit 0
