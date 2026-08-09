#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <child-pane> "<prompt>"\n' "$0" >&2
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

[ "$#" -eq 2 ] || usage

target="$1"
prompt="$2"
parent_pane="${HERDR_PANE_ID:-}"
workspace="${HERDR_WORKSPACE_ID:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
child_script="$script_dir/child-return-result.sh"

valid_pane "$target" || usage
valid_pane "$parent_pane" || fail 'HERDR_PANE_ID must be a valid pane ID'
valid_workspace "$workspace" || fail 'HERDR_WORKSPACE_ID must be a valid workspace ID'
[ "${target%%:*}" = "$workspace" ] || fail 'child pane must belong to HERDR_WORKSPACE_ID'
[ "${parent_pane%%:*}" = "$workspace" ] || fail 'HERDR_PANE_ID must belong to HERDR_WORKSPACE_ID'
[ -n "$prompt" ] || usage
[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'
[ -x "$child_script" ] || fail 'child-return-result.sh is required'

delegation_prompt="${prompt}

Direct parent pane for result return: ${parent_pane}
Return the final status and body with this helper, using completed or blocked as the status:
\"${child_script}\" \"${parent_pane}\" <completed|blocked> \"<body>\""

exec herdr agent prompt "$target" "$delegation_prompt"
