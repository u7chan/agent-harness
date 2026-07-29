#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$SCRIPT_DIR/../common/envelope.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local action_name
  action_name="$(echo "$input" | jq -r '.action // ""')"

  if [ -z "$action_name" ]; then
    envelope_fail "actions.describe" "MISSING_INPUT" "Required field 'action' is missing" false
    exit 1
  fi

  local action_def
  action_def="$(jq -c --arg name "$action_name" '
    .actions[] | select(.name == $name)
  ' "$HERDR_DIR/actions.json")"

  if [ -z "$action_def" ]; then
    envelope_fail "actions.describe" "UNKNOWN_ACTION" "Unknown action: $action_name" false
    exit 1
  fi

  envelope_ok "actions.describe" '{"type":"catalog"}' "$action_def"
}

main "$@"
