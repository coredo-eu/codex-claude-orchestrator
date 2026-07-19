#!/usr/bin/env zsh
set -euo pipefail

repo_root=${0:A:h:h}
skill="$repo_root/plugins/codex-claude-orchestrator/skills/claude-pty-agents"

for script in "$repo_root"/scripts/*.zsh(N) "$skill"/scripts/*.zsh(N); do
  zsh -n "$script"
done

python3 "$repo_root/tests/test_invariants.py"
python3 "$repo_root/tests/test_runtime.py"

print -- "codex-claude-orchestrator self-check: PASS"
