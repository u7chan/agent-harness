#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ACTIONS_JSON="${PW_ACTIONS_JSON:-$PW_ROOT/actions.json}"
source "$SCRIPT_DIR/../common/envelope.sh"

main() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    input='{}'
  fi

  local action_name
  action_name="$(jq -r '.action // ""' <<< "$input")"

  local action_def
  action_def="$(jq -c --arg name "$action_name" '.actions[] | select(.name == $name)' "$ACTIONS_JSON" 2>/dev/null || true)"
  if [ -z "$action_def" ]; then
    pw_envelope_fail "validation" "UNKNOWN_ACTION" "Unknown action: $action_name" false
    exit 1
  fi

  pw_envelope_ok "$action_def" "[]" "null"
}

main "$@"
