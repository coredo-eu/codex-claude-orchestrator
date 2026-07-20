#!/usr/bin/env zsh
set -u

# PostCompact supplies compact_summary on stdin. Drain it unread and append one
# content-free event marker; observation must never break Claude Code.
(( $# == 1 )) || exit 0
context_dir="$1"
/bin/cat >/dev/null 2>&1 || true

[[ -d "$context_dir" && ! -L "$context_dir" ]] || exit 0
schema="$context_dir/context_schema_version"
events="$context_dir/compactions.log"
[[ -f "$schema" && ! -L "$schema" && "$(<"$schema")" == "1" ]] || exit 0
[[ -f "$events" && ! -L "$events" ]] || exit 0

umask 077
pending="$context_dir/.compaction-pending.$$"
/bin/mkdir -- "$pending" 2>/dev/null || exit 0
if print -r -- "1" >> "$events" 2>/dev/null; then
  /bin/rmdir -- "$pending" 2>/dev/null || true
fi
exit 0
