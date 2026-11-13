#!/usr/bin/env bash
# Shared resolver: locate the installed pi package and run resolve-model-spec.mjs.
#
# This wrapper stays thin: it locates the pi package root (following the `pi`
# command's symlink chain) and forwards every argument to the .mjs, which loads
# the public pi API and prints the one-line key=value result. An unresolved pi
# root is reported by the .mjs as result=unknown with a nonzero exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$SCRIPT_DIR/resolve-model-spec.mjs"

usage() {
  cat <<'EOF'
Usage: resolve-model-spec.sh --provider <id> --model <id> --thinking <level> [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>]

Resolves the exact provider/model/thinking specification through the installed
pi runtime and prints one key=value line with provider, model, requested,
supported, effective, result, and thinking_level_map. Exit status is 0 only for
result=ok; every other result is unresolved.

--pi-root overrides the pi package root. Without it, the root is derived from
the `pi` command on PATH (symlink target plus the nearest package.json).
--pi-ai-root overrides the pi-ai package root (default:
<pi-root>/node_modules/@earendil-works/pi-ai).
EOF
}

# The pi root is derived from the `pi` command on PATH. The rule is shared
# with refresh-models.sh, so a change to the launcher layout is fixed once.
# shellcheck source=lib/pi-root.sh
source "$SCRIPT_DIR/lib/pi-root.sh"

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

command -v node >/dev/null 2>&1 || {
  printf 'resolve-model-spec: node is required to run %s\n' "$MJS" >&2
  exit 1
}

args=()
have_pi_root=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pi-root)
      # Tracked so that a resolved root is not appended when the caller
      # supplied one. A dangling --pi-root is forwarded as-is, so the .mjs
      # reports it through the shared argument-error path as one
      # result=unknown line with a nonzero exit.
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
