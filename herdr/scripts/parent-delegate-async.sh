#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <agent-or-pane> "<prompt>"\n' "$0" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_target() {
  [[ "$1" =~ ^[[:alnum:]_.:-]+$ ]]
}

[ "$#" -eq 2 ] || usage

target="$1"
prompt="$2"
parent_pane="${HERDR_PANE_ID:-}"

valid_target "$target" || usage
valid_target "$parent_pane" || fail 'HERDR_PANE_ID must be a valid pane ID'
[ -n "$prompt" ] || usage
[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'

delegation_prompt="${prompt}

Direct parent pane for result return: ${parent_pane}
Use child-return-result.sh to return the final status and body to this pane."

exec herdr agent prompt "$target" "$delegation_prompt"
