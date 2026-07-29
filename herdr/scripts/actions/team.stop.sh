#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local team_id
  team_id="$(echo "$input" | jq -r '.team_id // ""')"

  if [ -z "$team_id" ]; then
    envelope_fail "team.stop" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_already_applied "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" '{"team_id":"'"$team_id"'","stopped_members":[]}'
    exit 0
  fi

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"

  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    envelope_fail "team.stop" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local current_status
  current_status="$(echo "$manifest" | jq -r '.status // "active"')"

  if [ "$current_status" = "stopped" ]; then
    envelope_already_applied "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" '{"team_id":"'"$team_id"'","stopped_members":[]}'
    exit 0
  fi

  local stopped_members="["
  local first=true

  local member_count
  member_count="$(echo "$manifest" | jq -r '.members | length // 0')"
  local i
  for i in $(seq 0 $((member_count - 1))); do
    local pane_id role
    pane_id="$(echo "$manifest" | jq -r ".members[$i].pane_id // \"\"")"
    role="$(echo "$manifest" | jq -r ".members[$i].role // \"\"")"

    if [ -n "$pane_id" ] && [ "$pane_id" != "null" ]; then
      herdr pane close "$pane_id" 2>/dev/null || true
    fi

    if [ "$first" = true ]; then
      first=false
    else
      stopped_members+=","
    fi
    stopped_members+="\"$role\""
  done
  stopped_members+="]"

  herdr_manifest_delete "$team_id"

  local data
  data="$(jq -nc --arg team_id "$team_id" --argjson stopped "$stopped_members" '{
    team_id: $team_id,
    stopped_members: $stopped
  }')"

  envelope_ok "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" "$data"
}

main "$@"
