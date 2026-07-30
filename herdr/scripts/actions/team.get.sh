#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local team_id
  team_id="$(echo "$input" | jq -r '.team_id // ""')"

  if [ -z "$team_id" ]; then
    envelope_fail "team.get" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_fail "team.get" "NOT_FOUND" "Team '$team_id' not found" false
    exit 1
  fi

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"

  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    envelope_fail "team.get" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  envelope_ok "team.get" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" "$manifest"
}

main "$@"
