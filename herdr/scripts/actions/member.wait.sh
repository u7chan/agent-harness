#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local team_id role timeout
  team_id="$(echo "$input" | jq -r '.team_id // ""')"
  role="$(echo "$input" | jq -r '.role // ""')"
  timeout="$(echo "$input" | jq -r '.timeout // 60000')"

  if [ -z "$team_id" ]; then
    envelope_fail "member.wait" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi
  if [ -z "$role" ]; then
    envelope_fail "member.wait" "MISSING_REQUIRED_FIELD" "Required field 'role' is missing" false
    exit 1
  fi

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -lt 1000 ] || [ "$timeout" -gt 60000 ]; then
    envelope_fail "member.wait" "INVALID_TIMEOUT" "timeout must be an integer from 1000 to 60000 milliseconds" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_fail "member.wait" "NOT_FOUND" "Team '$team_id' not found" false
    exit 1
  fi

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"
  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    envelope_fail "member.wait" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local member
  member="$(echo "$manifest" | jq -c --arg role "$role" '.members[] | select(.role == $role)')"

  if [ -z "$member" ] || [ "$member" = "null" ]; then
    envelope_fail "member.wait" "MEMBER_NOT_FOUND" "Role '$role' not found in team '$team_id'" false
    exit 1
  fi

  local agent_name
  agent_name="$(echo "$member" | jq -r '.agent_name // ""')"

  if [ -z "$agent_name" ] || [ "$agent_name" = "null" ]; then
    envelope_fail "member.wait" "MEMBER_STATE_ERROR" "Agent name not found for role '$role'" false
    exit 1
  fi

  local result outer_timeout
  outer_timeout=$((timeout + 1000))
  result="$(herdr_cli_safe_call_timeout "$outer_timeout" herdr agent wait "$agent_name" --timeout "$timeout")"

  local wait_state agent_status
  wait_state="$(herdr_cli_wait_state "$result")"
  case "$wait_state" in
    completed) agent_status="$(jq -r '.result.agent.status // .result.status // "completed"' <<< "$result")" ;;
    waiting) agent_status="waiting" ;;
    failed) agent_status="failed" ;;
    *) agent_status="unknown" ;;
  esac

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    --arg agent_name "$agent_name" \
    --arg agent_status "$agent_status" \
    '{
      team_id: $team_id,
      role: $role,
      agent_name: $agent_name,
      agent_status: $agent_status
    }')"

  if [ "$wait_state" = "completed" ]; then
    envelope_ok "member.wait" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
  elif [ "$wait_state" = "waiting" ]; then
    envelope_waiting "member.wait" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
  elif [ "$wait_state" = "unknown" ]; then
    envelope_unknown_outcome "member.wait" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
  else
    envelope_fail "member.wait" "WAIT_FAILED" "Agent wait returned an explicit failure" true \
      "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
    exit 1
  fi
}

main "$@"
