#!/usr/bin/env bash
# Shared resolver: locate the installed pi package and run resolve-model-spec.mjs.
#
# This wrapper stays thin: it locates the pi package root (following the `pi`
# command's symlink chain) and forwards every argument to the .mjs, which loads
# the public pi API and prints the one-line key=value result. An unresolved pi
# root is reported by the .mjs as result=unknown with a nonzero exit. A Claude
# request needs no pi root at all: its model exists only after launch, so the
# .mjs validates the shape and the enumerations and reports
# verification=postlaunch. A Claude request may omit --permission-mode; the
# .mjs fills the shared default defined in lib/model-spec.mjs and rejects an
# explicit empty value.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$SCRIPT_DIR/resolve-model-spec.mjs"

usage() {
  cat <<'EOF'
Usage: resolve-model-spec.sh [--harness <pi|claude>] [options]

Resolves one role specification and prints one key=value line with harness,
provider, model, requested, supported, effective, result, verification, and the
harness's own vocabulary field (thinking_level_map for pi, permission_mode for
claude). Exit status is 0 only for result=ok.

pi (default):
  --provider <id> --model <id> --thinking <level>
  [--pi-root <pi-package>] [--pi-ai-root <pi-ai-package>]
  The model must match the installed catalog exactly; the result is
  verification=exact.

claude:
  --model <id-or-alias> --effort <level> [--permission-mode <mode>]
  Only the model shape and the effort/permission vocabularies are checked and
  the result is verification=postlaunch. No alias table is kept and no
  effective value is reported before launch. When --permission-mode is
  omitted, the .mjs fills the shared default defined in lib/model-spec.mjs;
  an explicit empty value is a usage error.

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
harness=''

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
    --harness)
      # Forwarded unchanged; only the pi-root lookup depends on it. A dangling
      # --harness is forwarded so the .mjs reports the argument error.
      args+=("$1")
      shift
      if [ "$#" -gt 0 ]; then
        harness="$1"
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

if [ "$have_pi_root" -eq 0 ] && [ "$harness" != 'claude' ]; then
  pi_root="$(pi_root_from_command)" || pi_root=""
  if [ -n "$pi_root" ]; then
    args+=(--pi-root "$pi_root")
  fi
fi

exec node "$MJS" "${args[@]}"
