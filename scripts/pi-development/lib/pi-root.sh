#!/usr/bin/env bash
# Shared resolution of the installed pi package root.
#
# Two wrappers need the same answer: `resolve-model-spec.sh` and
# `refresh-models.sh` both have to find the package that backs the `pi`
# command. Keeping the rule here means a change to the launcher layout is
# fixed once instead of drifting between the two copies.
#
# Usage from a wrapper:
#
#   # shellcheck source=lib/pi-root.sh
#   source "$SCRIPT_DIR/lib/pi-root.sh"
#   pi_root="$(pi_root_from_command)" || pi_root=""

# Print the package root of the installed pi. `command -v pi` returns the
# launcher (for example <prefix>/bin/pi -> <pkg>/dist/bundle/cli.js); resolve
# the symlink chain and walk up to the nearest directory with package.json.
pi_root_from_command() {
  local pi_path resolved dir
  pi_path="$(command -v pi 2>/dev/null)" || return 1
  [ -n "$pi_path" ] || return 1
  resolved="$(readlink -f -- "$pi_path" 2>/dev/null)" || return 1
  [ -n "$resolved" ] || return 1
  dir="$(dirname -- "$resolved")"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/package.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname -- "$dir")"
  done
  return 1
}

# Print the pi-ai package root that ships inside the pi package.
pi_ai_root_from_pi_root() {
  local pi_root="$1"
  [ -n "$pi_root" ] || return 1
  printf '%s\n' "$pi_root/node_modules/@earendil-works/pi-ai"
}
