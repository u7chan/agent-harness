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

# Best-effort display name for the parent pane, matching what Herdr shows on
# the pane border: manual label first, then detected agent kind. Cosmetic only;
# any lookup failure falls back to the bare pane ID.
display_name="$parent_pane"
if command -v python3 >/dev/null 2>&1; then
  pane_json="$(herdr pane get "$parent_pane" 2>/dev/null)" || pane_json=''
  if [ -n "$pane_json" ]; then
    name="$(printf '%s' "$pane_json" | python3 -c '
import json, sys
try:
    pane = json.load(sys.stdin)["result"]["pane"]
    print(pane.get("label") or pane.get("agent") or "")
except Exception:
    pass
' 2>/dev/null)" || name=''
    if [ -n "$name" ]; then
      display_name="$parent_pane ($name)"
    fi
  fi
fi

delegation_prompt="${prompt}

Direct parent pane for result return: ${display_name}
Return the final status and body with this helper, using completed or blocked as the status:
\"${child_script}\" \"${parent_pane}\" <completed|blocked> \"<body>\""

exec herdr agent prompt "$target" "$delegation_prompt"
