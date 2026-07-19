#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: setup-native-agents.zsh [--target project|user] [--root <absolute-project-root>] [--model <model>] [--role-model <role=model>]... [--apply [--yes]]"
  exit 64
}

target="project"
root="$PWD"
uniform_model=${CODEX_NATIVE_AGENT_MODEL:-}
apply=0
yes=0
roles=(source_explorer mech_executor reviewer security_reviewer test_runner)
typeset -A default_models selected_models role_overrides
default_models=(
  source_explorer gpt-5.6-luna
  test_runner gpt-5.6-luna
  mech_executor gpt-5.6-terra
  reviewer gpt-5.6-terra
  security_reviewer gpt-5.6-sol
)

valid_model() {
  local candidate="$1"
  [[ -n "$candidate" && ${#candidate} -le 128 && "$candidate" =~ '^[A-Za-z0-9._:-]+$' ]]
}

valid_role() {
  case "$1" in
    source_explorer|mech_executor|reviewer|security_reviewer|test_runner) return 0 ;;
    *) return 1 ;;
  esac
}

while (( $# > 0 )); do
  case "$1" in
    --target)
      (( $# >= 2 )) || usage
      target="$2"
      shift 2
      ;;
    --root)
      (( $# >= 2 )) || usage
      root="$2"
      shift 2
      ;;
    --model)
      (( $# >= 2 )) || usage
      uniform_model="$2"
      shift 2
      ;;
    --role-model)
      (( $# >= 2 )) || usage
      spec="$2"
      [[ "$spec" == *=* ]] || usage
      role_name=${spec%%=*}
      role_model=${spec#*=}
      valid_role "$role_name" && valid_model "$role_model" || usage
      role_overrides[$role_name]="$role_model"
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    --yes)
      yes=1
      shift
      ;;
    *) usage ;;
  esac
done

[[ "$target" == "project" || "$target" == "user" ]] || usage
(( yes == 0 || apply == 1 )) || usage
[[ -z "$uniform_model" ]] || valid_model "$uniform_model" || {
  print -u2 -- "INVALID_NATIVE_AGENT_MODEL"
  exit 64
}

for role in "${roles[@]}"; do
  selected_models[$role]="${default_models[$role]}"
  [[ -z "$uniform_model" ]] || selected_models[$role]="$uniform_model"
  role_override="${role_overrides[$role]:-}"
  [[ -z "$role_override" ]] || selected_models[$role]="$role_override"
  valid_model "${selected_models[$role]}" || {
    print -u2 -- "INVALID_NATIVE_AGENT_MODEL: role=$role"
    exit 64
  }
done

script_dir=${0:A:h}
skill_dir=${script_dir:h}
template_dir="$skill_dir/assets/native-agents"

if [[ "$target" == "project" ]]; then
  [[ "$root" == /* && -d "$root" ]] || usage
  root=$(cd -P -- "$root" && pwd -P)
  git_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n "$git_root" && -d "$git_root" ]] && root=$(cd -P -- "$git_root" && pwd -P)
  destination="$root/.codex/agents"
else
  [[ -n "${HOME:-}" && "$HOME" == /* ]] || {
    print -u2 -- "HOME_INVALID"
    exit 69
  }
  codex_home=${CODEX_HOME:-$HOME/.codex}
  [[ "$codex_home" == /* ]] || {
    print -u2 -- "CODEX_HOME_MUST_BE_ABSOLUTE"
    exit 64
  }
  destination="$codex_home/agents"
fi

for role in "${roles[@]}"; do
  [[ -r "$template_dir/$role.toml.in" ]] || {
    print -u2 -- "TEMPLATE_MISSING: $template_dir/$role.toml.in"
    exit 66
  }
done

print -- "Native Codex agent setup"
print -- "  target: $target"
print -- "  destination: $destination"
for role in "${roles[@]}"; do
  print -- "  create: $destination/$role.toml (model=${selected_models[$role]})"
done

if (( apply == 0 )); then
  print -- "DRY_RUN: no files written. Re-run with --apply to confirm interactively, or --apply --yes for explicit non-interactive consent."
  exit 0
fi

collisions=0
for role in "${roles[@]}"; do
  if [[ -e "$destination/$role.toml" || -L "$destination/$role.toml" ]]; then
    print -u2 -- "REFUSING_TO_OVERWRITE: $destination/$role.toml"
    collisions=$(( collisions + 1 ))
  fi
done
(( collisions == 0 )) || exit 73

if (( yes == 0 )); then
  [[ -t 0 ]] || {
    print -u2 -- "CONFIRMATION_REQUIRED: use --apply --yes only after reviewing the dry run"
    exit 64
  }
  print -n -- "Create these files? [y/N] "
  read -r answer
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || {
    print -- "Cancelled; no files written."
    exit 1
  }
fi

umask 077
/bin/mkdir -p -- "$destination"
install_lock="$destination/.codex-claude-orchestrator-install.lock"
if ! /bin/mkdir -- "$install_lock" 2>/dev/null; then
  print -u2 -- "NATIVE_AGENT_SETUP_BUSY: $install_lock"
  exit 75
fi
lock_held=1
typeset -a staged_files
staged_files=()
cleanup_install() {
  local staged_file
  for staged_file in "${staged_files[@]}"; do
    [[ -n "$staged_file" && -e "$staged_file" ]] && /bin/rm -f -- "$staged_file"
  done
  if (( ${lock_held:-0} == 1 )); then
    /bin/rmdir -- "$install_lock" 2>/dev/null || true
    lock_held=0
  fi
}
trap 'cleanup_install' EXIT
trap 'cleanup_install; exit 129' HUP
trap 'cleanup_install; exit 130' INT
trap 'cleanup_install; exit 143' TERM

# Repeat the collision check while holding the destination lock. This closes the
# race between two cooperative installers; the exclusive link below also
# protects against non-cooperating writers.
for role in "${roles[@]}"; do
  if [[ -e "$destination/$role.toml" || -L "$destination/$role.toml" ]]; then
    print -u2 -- "REFUSING_TO_OVERWRITE: $destination/$role.toml"
    exit 73
  fi
done

for role in "${roles[@]}"; do
  tmp=$(mktemp "$destination/.$role.toml.XXXXXX")
  staged_files+=("$tmp")
  sed "s/@MODEL@/${selected_models[$role]}/g" "$template_dir/$role.toml.in" > "$tmp"
  /bin/chmod 600 "$tmp"
done

for role in "${roles[@]}"; do
  tmp="${staged_files[1]}"
  # link(2) creates the destination atomically and fails for every existing
  # directory entry, including a dangling symlink. Unlike mv, it cannot replace
  # a target introduced between the preflight and this final installation step.
  if ! /bin/ln -- "$tmp" "$destination/$role.toml" 2>/dev/null; then
    print -u2 -- "REFUSING_TO_OVERWRITE: $destination/$role.toml"
    exit 73
  fi
  /bin/rm -f -- "$tmp"
  staged_files=("${staged_files[@]:1}")
done
cleanup_install
trap - EXIT HUP INT TERM
print -- "Installed ${#roles} native Codex role files. Existing files were not overwritten."
