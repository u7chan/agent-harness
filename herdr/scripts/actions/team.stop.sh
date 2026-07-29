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
    envelope_fail "team.stop" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_already_applied "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" '{"team_id":"'"$team_id"'","stopped_members":[]}'
    exit 0
  fi

  local lock_file=""
  lock_file="$(herdr_manifest_lock "$team_id" 30)" || {
    envelope_fail "team.stop" "LOCK_FAILED" "Could not acquire lock for team_id: $team_id" true
    exit 1
  }

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  if [ "$manifest" = "{}" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_already_applied "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" '{"team_id":"'"$team_id"'","stopped_members":[]}'
    exit 0
  fi

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"

  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_fail "team.stop" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local current_status
  current_status="$(echo "$manifest" | jq -r '.status // "active"')"

  if [ "$current_status" = "stopped" ]; then
    herdr_manifest_unlock "$lock_file"
    envelope_already_applied "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" '{"team_id":"'"$team_id"'","stopped_members":[]}'
    exit 0
  fi

  local stopped_ok=""
  local stopped_failed=""
  local all_closed=true

  local member_count
  member_count="$(echo "$manifest" | jq -r '.members | length // 0')"
  local i
  for i in $(seq 0 $((member_count - 1))); do
    local pane_id role member_status
    pane_id="$(echo "$manifest" | jq -r ".members[$i].pane_id // \"\"")"
    role="$(echo "$manifest" | jq -r ".members[$i].role // \"\"")"
    member_status="$(echo "$manifest" | jq -r ".members[$i].status // \"active\"")"

    if [ "$member_status" = "closed" ]; then
      stopped_ok="${stopped_ok}\"${role}\","
      continue
    fi

    local close_result close_outcome
    if [ -n "$pane_id" ] && [ "$pane_id" != "null" ]; then
      close_result="$(herdr pane close "$pane_id" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}')"
      close_outcome="$(herdr_cli_outcome "$close_result")"
    else
      close_outcome="ok"
    fi

    if [ "$close_outcome" = "ok" ]; then
      stopped_ok="${stopped_ok}\"${role}\","
      manifest="$(echo "$manifest" | jq -c --arg role "$role" '
        .members = [.members[] | if .role == $role then . + {status: "closed"} else . end]
      ')"
    elif [ "$close_outcome" = "unknown" ]; then
      stopped_failed="${stopped_failed}\"${role}\","
      all_closed=false
      manifest="$(echo "$manifest" | jq -c --arg role "$role" '
        .members = [.members[] | if .role == $role then . + {status: "close-unknown"} else . end]
      ')"
    else
      stopped_failed="${stopped_failed}\"${role}\","
      all_closed=false
    fi
  done

  if [ "$all_closed" = true ]; then
    herdr_manifest_delete "$team_id"
    herdr_manifest_unlock "$lock_file"
  else
    local updated_manifest
    updated_manifest="$(echo "$manifest" | jq -c '.status = "close-incomplete"')"
    herdr_manifest_write "$team_id" "$updated_manifest"
    herdr_manifest_unlock "$lock_file"
    local ok_list
    ok_list="[${stopped_ok%,}]"
    local fail_list
    fail_list="[${stopped_failed%,}]"
    local data
    data="$(jq -nc --arg team_id "$team_id" --argjson stopped_ok "$ok_list" --argjson stopped_failed "$fail_list" '{
      team_id: $team_id,
      stopped_members: $stopped_ok,
      failed_members: $stopped_failed
    }')"
    envelope_fail "team.stop" "PARTIAL_CLOSE" "Some panes could not be closed. Manifest preserved for retry." true
    exit 1
  fi

  local stopped_list
  stopped_list="[${stopped_ok%,}]"

  local data
  data="$(jq -nc --arg team_id "$team_id" --argjson stopped "$stopped_list" '{
    team_id: $team_id,
    stopped_members: $stopped
  }')"

  envelope_ok "team.stop" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" "$data"
}

main "$@"
