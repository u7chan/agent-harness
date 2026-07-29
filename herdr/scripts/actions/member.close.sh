#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local team_id role
  team_id="$(echo "$input" | jq -r '.team_id // ""')"
  role="$(echo "$input" | jq -r '.role // ""')"

  if [ -z "$team_id" ]; then
    envelope_fail "member.close" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi
  if [ -z "$role" ]; then
    envelope_fail "member.close" "MISSING_REQUIRED_FIELD" "Required field 'role' is missing" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_already_applied "member.close" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" '{"team_id":"'"$team_id"'","role":"'"$role"'","closed":true}'
    exit 0
  fi

  local lock_file=""
  lock_file="$(herdr_manifest_lock "$team_id" 30)" || {
    envelope_fail "member.close" "LOCK_FAILED" "Could not acquire lock for team_id: $team_id" true
    exit 1
  }

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"
  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_fail "member.close" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local member
  member="$(echo "$manifest" | jq -c --arg role "$role" '.members[] | select(.role == $role)')"

  if [ -z "$member" ] || [ "$member" = "null" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_already_applied "member.close" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" '{"team_id":"'"$team_id"'","role":"'"$role"'","closed":true}'
    exit 0
  fi

  local current_status
  current_status="$(echo "$member" | jq -r '.status // "active"')"

  if [ "$current_status" = "closed" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_already_applied "member.close" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" '{"team_id":"'"$team_id"'","role":"'"$role"'","closed":true}'
    exit 0
  fi

  local pane_id agent_name
  pane_id="$(echo "$member" | jq -r '.pane_id // ""')"
  agent_name="$(echo "$member" | jq -r '.agent_name // ""')"

  local close_result close_outcome
  if [ -n "$pane_id" ] && [ "$pane_id" != "null" ]; then
    close_result="$(herdr pane close "$pane_id" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')"
    close_outcome="$(herdr_cli_outcome "$close_result")"
  else
    close_outcome="ok"
  fi

  if [ "$close_outcome" = "failed" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_fail "member.close" "CLOSE_FAILED" "Failed to close pane for role '$role'. Manifest preserved for retry." true
    exit 1
  elif [ "$close_outcome" = "unknown" ]; then
    local updated_manifest
    updated_manifest="$(echo "$manifest" | jq -c --arg role "$role" '
      .members = [.members[] | if .role == $role then . + {status: "close-unknown"} else . end]
    ')"
    herdr_manifest_write "$team_id" "$updated_manifest"
    herdr_manifest_unlock "$lock_file"
    envelope_unknown_outcome "member.close" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id: $team_id, role: $role, closed: false}')"
    exit 0
  fi

  local updated_manifest
  updated_manifest="$(echo "$manifest" | jq -c --arg role "$role" '
    .members = [.members[] | if .role == $role then . + {status: "closed"} else . end]
  ')"

  local remaining_active
  remaining_active="$(echo "$updated_manifest" | jq -r '[.members[] | select(.status != "closed")] | length')"

  if [ "$remaining_active" -eq 0 ]; then
    updated_manifest="$(echo "$updated_manifest" | jq -c '.status = "stopped"')"
  fi

  herdr_manifest_write "$team_id" "$updated_manifest"
  herdr_manifest_unlock "$lock_file"

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    '{
      team_id: $team_id,
      role: $role,
      closed: true
    }')"

  envelope_ok "member.close" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
}

main "$@"
