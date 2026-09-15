#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <direct-parent-pane> <completed|blocked> "<body>"\n' "$0" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_workspace() {
  [[ "$1" =~ ^[[:alnum:]_.-]+$ ]]
}

valid_pane() {
  [[ "$1" =~ ^[[:alnum:]_.-]+:[[:alnum:]_.-]+$ ]]
}

[ "$#" -eq 3 ] || usage

parent_pane="$1"
status="$2"
body="$3"
child_pane="${HERDR_PANE_ID:-}"
workspace="${HERDR_WORKSPACE_ID:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scope.sh
source "$script_dir/lib/scope.sh"

valid_pane "$parent_pane" || usage
case "$status" in
  completed|blocked) ;;
  *) usage ;;
esac
[ -n "$body" ] || usage
valid_pane "$child_pane" || fail 'HERDR_PANE_ID must be a valid pane ID'
valid_workspace "$workspace" || fail 'HERDR_WORKSPACE_ID must be a valid workspace ID'
[ "${child_pane%%:*}" = "$workspace" ] || fail 'HERDR_PANE_ID must belong to HERDR_WORKSPACE_ID'
[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'

# Scope check before the prompt call. The return uses the same rules as the
# delegation that created the edge, in the reverse direction.
target_workspace="${parent_pane%%:*}"
[ "$parent_pane" != "$child_pane" ] || scope_reject self-pane
if [ "$target_workspace" != "$workspace" ]; then
  scope_require "$workspace" "$target_workspace"
fi

result_message="status: ${status}
body:
${body}"

exec herdr agent prompt "$parent_pane" "$result_message"
