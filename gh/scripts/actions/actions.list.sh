#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$SCRIPT_DIR/../common/envelope.sh"

main() {
  local actions
  actions="$(jq -c '[.actions[] | {name: .name, description: .description, category: .category, permission: .permission}]' "$GH_DIR/actions.json")"

  envelope_ok "actions.list" '{"type":"catalog"}' "$actions"
}

main "$@"
