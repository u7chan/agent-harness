#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local team_id role lines
  team_id="$(echo "$input" | jq -r '.team_id // ""')"
  role="$(echo "$input" | jq -r '.role // ""')"
  lines="$(echo "$input" | jq -r '.lines // 200')"

  if [ -z "$team_id" ]; then
    envelope_fail "member.read" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi
  if [ -z "$role" ]; then
    envelope_fail "member.read" "MISSING_REQUIRED_FIELD" "Required field 'role' is missing" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_fail "member.read" "NOT_FOUND" "Team '$team_id' not found" false
    exit 1
  fi

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"
  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    envelope_fail "member.read" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local member
  member="$(echo "$manifest" | jq -c --arg role "$role" '.members[] | select(.role == $role)')"

  if [ -z "$member" ] || [ "$member" = "null" ]; then
    envelope_fail "member.read" "MEMBER_NOT_FOUND" "Role '$role' not found in team '$team_id'" false
    exit 1
  fi

  local agent_name
  agent_name="$(echo "$member" | jq -r '.agent_name // ""')"

  if [ -z "$agent_name" ] || [ "$agent_name" = "null" ]; then
    envelope_fail "member.read" "MEMBER_STATE_ERROR" "Agent name not found for role '$role'" false
    exit 1
  fi

  local result
  result="$(herdr agent read "$agent_name" --source recent-unwrapped --lines "$lines" 2>/dev/null || echo '')"

  local output_text
  if [ -z "$result" ]; then
    output_text=""
  else
    output_text="$result"
  fi

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    --arg agent_name "$agent_name" \
    --arg output "$output_text" \
    '{
      team_id: $team_id,
      role: $role,
      agent_name: $agent_name,
      output: $output
    }')"

  envelope_ok "member.read" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
}

main "$@"
