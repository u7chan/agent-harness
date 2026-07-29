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

  local stopped_ok=""
  local stopped_failed=""
  local first_ok=true
  local first_fail=true
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
      continue
    fi

    local close_result close_status
    if [ -n "$pane_id" ] && [ "$pane_id" != "null" ]; then
      close_result="$(herdr pane close "$pane_id" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{"status":"failed"}')"
      close_status="$(echo "$close_result" | jq -r '.status // "failed"')"
    else
      close_status="no_pane"
    fi

    if [ "$close_status" = "ok" ] || [ "$close_status" = "no_pane" ]; then
      if [ "$first_ok" = true ]; then
        first_ok=false
      fi
      stopped_ok="${stopped_ok}\"${role}\","
    else
      if [ "$first_fail" = true ]; then
        first_fail=false
      fi
      stopped_failed="${stopped_failed}\"${role}\","
      all_closed=false
    fi
  done

  if [ "$all_closed" = true ]; then
    herdr_manifest_delete "$team_id"
  else
    local updated_manifest
    updated_manifest="$(echo "$manifest" | jq -c '.status = "stop-failed"')"
    herdr_manifest_write "$team_id" "$updated_manifest"
    local failed_list
    failed_list="[${stopped_failed%,}]"
    envelope_fail "team.stop" "CLOSE_FAILED" "Failed to close some panes. Manifest preserved for retry. Failed: $failed_list" true
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
