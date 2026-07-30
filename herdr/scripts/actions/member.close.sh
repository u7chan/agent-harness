#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

MEMBER_CLOSE_LOCK_FILE=""
MEMBER_CLOSE_PROCESS_ID="$BASHPID"
MEMBER_CLOSE_LOCK_TOKEN="member-close-${BASHPID}-${RANDOM}-${RANDOM}"
member_close_release_lock() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  [ "$BASHPID" = "$MEMBER_CLOSE_PROCESS_ID" ] || return 0
  if [ -n "$MEMBER_CLOSE_LOCK_FILE" ]; then
    herdr_manifest_unlock "$MEMBER_CLOSE_LOCK_FILE" "$MEMBER_CLOSE_LOCK_TOKEN" || true
    MEMBER_CLOSE_LOCK_FILE=""
  fi
}
main() {
  local input team_id role target
  input="$(herdr_read_input "$1")"
  team_id="$(jq -r '.team_id // ""' <<< "$input")"
  role="$(jq -r '.role // ""' <<< "$input")"
  target="$(jq -nc --arg team_id "$team_id" --arg role "$role" '{type:"member",team_id:$team_id,role:$role}')"

  if ! herdr_manifest_exists "$team_id"; then
    envelope_already_applied "member.close" "$target" "$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id:$team_id,role:$role,closed:true}')"
    return 0
  fi
  if herdr_manifest_lock "$team_id" 30 "$MEMBER_CLOSE_LOCK_TOKEN"; then
    MEMBER_CLOSE_LOCK_FILE="$HERDR_MANIFEST_LOCK_FILE"
  else
    envelope_fail "member.close" "LOCK_FAILED" "Could not acquire lock for team_id: $team_id" true "$target"
    return 1
  fi

  local manifest workspace_id bound_workspace member
  manifest="$(herdr_manifest_read "$team_id")"
  workspace_id="$(herdr_get_workspace_id)"
  bound_workspace="$(jq -r '.workspace_id // ""' <<< "$manifest")"
  if [ "$bound_workspace" != "$workspace_id" ]; then
    member_close_release_lock
    envelope_fail "member.close" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false "$target"
    return 1
  fi
  member="$(jq -c --arg role "$role" '.members[] | select(.role == $role)' <<< "$manifest")"
  if [ -z "$member" ]; then
    member_close_release_lock
    envelope_already_applied "member.close" "$target" "$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id:$team_id,role:$role,closed:true}')"
    return 0
  fi

  local member_status pane_id close_outcome
  member_status="$(jq -r '.status // "active"' <<< "$member")"
  pane_id="$(jq -r '.pane_id // ""' <<< "$member")"
  if [ "$member_status" = "closed" ]; then
    member_close_release_lock
    envelope_already_applied "member.close" "$target" "$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id:$team_id,role:$role,closed:true}')"
    return 0
  fi

  if [ -z "$pane_id" ]; then
    if [ "$member_status" = "pending" ]; then
      close_outcome="ok"
    else
      close_outcome="unknown"
    fi
  else
    local close_result
    close_result="$(herdr_cli_safe_call_timeout 30000 herdr pane close "$pane_id")"
    close_outcome="$(herdr_cli_outcome "$close_result")"
  fi

  local new_status
  case "$close_outcome" in
    ok) new_status="closed" ;;
    failed)
      local close_err
      close_err="$(herdr_cli_error_code "$close_result" | tr '[:upper:]' '[:lower:]')"
      if [[ "$close_err" =~ (pane.*not.?found|not.?found.*pane|no.*such.*pane) ]]; then
        new_status="closed"
      else
        new_status="close-failed"
      fi
      ;;
    *) new_status="close-unknown" ;;
  esac
  manifest="$(jq -c --arg role "$role" --arg status "$new_status" '.members = [.members[] | if .role == $role then .status = $status else . end]' <<< "$manifest")"
  if jq -e '[.members[] | select((.status // "active") != "closed")] | length == 0' >/dev/null <<< "$manifest"; then
    manifest="$(jq -c '.status = "stopped"' <<< "$manifest")"
  fi
  herdr_manifest_write "$team_id" "$manifest"
  member_close_release_lock

  local data data_outcome="$close_outcome"
  local is_closed=false
  if [ "$new_status" = "closed" ]; then
    is_closed=true
    if [ "$close_outcome" != "ok" ]; then
      data_outcome="ok"
    fi
  fi
  data="$(jq -nc --arg team_id "$team_id" --arg role "$role" --arg pane_id "$pane_id" --arg outcome "$data_outcome" --argjson closed "$is_closed" '{team_id:$team_id,role:$role,pane_id:(if $pane_id == "" then null else $pane_id end),closed:$closed,outcome:$outcome}')"
  case "$new_status" in
    closed) envelope_ok "member.close" "$target" "$data" ;;
    close-unknown)
      envelope_unknown_outcome "member.close" "$target" "$data"
      ;;
    *)
      envelope_fail "member.close" "CLOSE_FAILED" "Pane close explicitly failed; manifest preserved for retry" true "$target" "$data"
      return 1
      ;;
  esac
}

main "$@"
