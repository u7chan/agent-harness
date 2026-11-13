#!/usr/bin/env bash
# Generate the model master for the local profile editor.
#
# This wrapper stays thin: it locates the pi package root (following the `pi`
# command's symlink chain, the same rule as resolve-model-spec.sh) and forwards
# every argument to the .mjs, which loads the public pi API and writes
# models.json under the shared user asset. An unresolved pi root is reported by
# the .mjs as result=failed with a nonzero exit, and the existing master is left
# untouched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$SCRIPT_DIR/refresh-models.mjs"

usage() {
  cat <<'EOF'
Usage: refresh-models.sh [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>] [--out <file>]

Writes ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-development/models.json from
the authenticated models in the installed pi catalog.

--pi-root overrides the pi package root. Without it, the root is derived from
the `pi` command on PATH (symlink target plus the nearest package.json).
--pi-ai-root overrides the pi-ai package root (default:
<pi-root>/node_modules/@earendil-works/pi-ai).
--out overrides the destination file.

A failure or an empty catalog leaves the existing file untouched.
EOF
}

# shellcheck source=lib/pi-root.sh
source "$SCRIPT_DIR/lib/pi-root.sh"

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

command -v node >/dev/null 2>&1 || {
  printf 'refresh-models: node is required to run %s\n' "$MJS" >&2
  exit 1
}

args=()
have_pi_root=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pi-root)
      # Tracked so that a resolved root is not appended when the caller
      # supplied one. A dangling --pi-root is forwarded as-is, so the .mjs
      # reports it through the shared failure path as one result=failed line.
      have_pi_root=1
      args+=("$1")
      shift
      if [ "$#" -gt 0 ]; then
        args+=("$1")
        shift
      fi
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [ "$have_pi_root" -eq 0 ]; then
  pi_root="$(pi_root_from_command)" || pi_root=""
  if [ -n "$pi_root" ]; then
    args+=(--pi-root "$pi_root")
  fi
fi

exec node "$MJS" "${args[@]}"
