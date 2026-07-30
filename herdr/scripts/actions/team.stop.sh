#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

TEAM_STOP_LOCK_FILE=""
TEAM_STOP_PROCESS_ID="$BASHPID"
TEAM_STOP_LOCK_TOKEN="team-stop-${BASHPID}-${RANDOM}-${RANDOM}"
team_stop_release_lock() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  [ "$BASHPID" = "$TEAM_STOP_PROCESS_ID" ] || return 0
  if [ -n "$TEAM_STOP_LOCK_FILE" ]; then
    herdr_manifest_unlock "$TEAM_STOP_LOCK_FILE" "$TEAM_STOP_LOCK_TOKEN" || true
    TEAM_STOP_LOCK_FILE=""
  fi
}
main() {
  local input team_id target
  input="$(herdr_read_input "$1")"
  team_id="$(jq -r '.team_id // ""' <<< "$input")"
  target="$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')"

  if ! herdr_manifest_exists "$team_id"; then
    envelope_already_applied "team.stop" "$target" "$(jq -nc --arg team_id "$team_id" '{team_id:$team_id,stopped_members:[],results:[]}')"
    return 0
  fi

  if herdr_manifest_lock "$team_id" 30 "$TEAM_STOP_LOCK_TOKEN"; then
    TEAM_STOP_LOCK_FILE="$HERDR_MANIFEST_LOCK_FILE"
  else
    envelope_fail "team.stop" "LOCK_FAILED" "Could not acquire lock for team_id: $team_id" true "$target"
    return 1
  fi
  if ! herdr_manifest_exists "$team_id"; then
    team_stop_release_lock
    envelope_already_applied "team.stop" "$target" "$(jq -nc --arg team_id "$team_id" '{team_id:$team_id,stopped_members:[],results:[]}')"
    return 0
  fi

  local manifest workspace_id bound_workspace
  manifest="$(herdr_manifest_read "$team_id")"
  workspace_id="$(herdr_get_workspace_id)"
  bound_workspace="$(jq -r '.workspace_id // ""' <<< "$manifest")"
  if [ "$bound_workspace" != "$workspace_id" ]; then
    team_stop_release_lock
    envelope_fail "team.stop" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false "$target"
    return 1
  fi

  if jq -e '[.members[] | select((.status // "active") != "closed")] | length == 0' >/dev/null <<< "$manifest"; then
    herdr_manifest_delete "$team_id"
    team_stop_release_lock
    envelope_already_applied "team.stop" "$target" "$(jq -nc --arg team_id "$team_id" '{team_id:$team_id,stopped_members:[],results:[],manifest_removed:true}')"
    return 0
  fi

  local results='[]' count i
  count="$(jq -r '.members | length' <<< "$manifest")"
  for ((i = 0; i < count; i++)); do
    local role pane_id member_status close_outcome
    role="$(jq -r ".members[$i].role" <<< "$manifest")"
    pane_id="$(jq -r ".members[$i].pane_id // \"\"" <<< "$manifest")"
    member_status="$(jq -r ".members[$i].status // \"active\"" <<< "$manifest")"

    if [ "$member_status" = "closed" ]; then
      close_outcome="already_closed"
    elif [ -z "$pane_id" ]; then
      case "$member_status" in
        pending)
          close_outcome="ok"
          member_status="closed"
          ;;
        *)
          close_outcome="unknown"
          member_status="close-unknown"
          ;;
      esac
    else
      local close_result
      close_result="$(herdr_cli_safe_call_timeout 30000 herdr pane close "$pane_id")"
      close_outcome="$(herdr_cli_outcome "$close_result")"
      case "$close_outcome" in
        ok) member_status="closed" ;;
        failed)
          local stop_close_err
          stop_close_err="$(herdr_cli_error_code "$close_result" | tr '[:upper:]' '[:lower:]')"
          if [[ "$stop_close_err" =~ (pane.*not.?found|not.?found.*pane|no.*such.*pane) ]]; then
            member_status="closed"
          else
            member_status="close-failed"
          fi
          ;;
        *) member_status="close-unknown" ;;
      esac
    fi

    manifest="$(jq -c --argjson i "$i" --arg status "$member_status" '.members[$i].status = $status' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"
    local result_outcome="$close_outcome"
    if [ "$member_status" = "closed" ] && [ "$close_outcome" = "failed" ]; then
      result_outcome="ok"
    fi
    results="$(jq -c --arg role "$role" --arg pane_id "$pane_id" --arg outcome "$result_outcome" '. + [{role:$role,pane_id:(if $pane_id == "" then null else $pane_id end),outcome:$outcome}]' <<< "$results")"
  done

  local remaining unknown_count failed_count data
  remaining="$(jq -r '[.members[] | select((.status // "active") != "closed")] | length' <<< "$manifest")"
  unknown_count="$(jq -r '[.[] | select(.outcome == "unknown")] | length' <<< "$results")"
  failed_count="$(jq -r '[.[] | select(.outcome == "failed")] | length' <<< "$results")"
  data="$(jq -nc --arg team_id "$team_id" --argjson results "$results" '{
    team_id:$team_id,
    stopped_members:[$results[] | select(.outcome == "ok" or .outcome == "already_closed") | .role],
    failed_members:[$results[] | select(.outcome == "failed") | .role],
    unknown_members:[$results[] | select(.outcome == "unknown") | .role],
    results:$results
  }')"

  if [ "$remaining" -eq 0 ]; then
    herdr_manifest_delete "$team_id"
    team_stop_release_lock
    envelope_ok "team.stop" "$target" "$data"
  else
    manifest="$(jq -c '.status = "close-incomplete"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"
    team_stop_release_lock
    if [ "$unknown_count" -gt 0 ]; then
      envelope_unknown_outcome "team.stop" "$target" "$data"
      return 0
    fi
    if [ "$failed_count" -gt 0 ]; then
      envelope_fail "team.stop" "PARTIAL_CLOSE" "Some panes explicitly failed to close; manifest preserved for retry" true "$target" "$data"
      return 1
    fi
    envelope_unknown_outcome "team.stop" "$target" "$data"
  fi
}

main "$@"
