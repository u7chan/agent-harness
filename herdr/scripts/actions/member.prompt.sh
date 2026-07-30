#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

MEMBER_PROMPT_LOCK_FILE=""
MEMBER_PROMPT_PROCESS_ID="$BASHPID"
MEMBER_PROMPT_LOCK_TOKEN="member-prompt-${BASHPID}-${RANDOM}-${RANDOM}"
member_prompt_release_lock() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  [ "$BASHPID" = "$MEMBER_PROMPT_PROCESS_ID" ] || return 0
  if [ -n "$MEMBER_PROMPT_LOCK_FILE" ]; then
    herdr_manifest_unlock "$MEMBER_PROMPT_LOCK_FILE" "$MEMBER_PROMPT_LOCK_TOKEN" || true
    MEMBER_PROMPT_LOCK_FILE=""
  fi
}
main() {
  local input
  input="$(herdr_read_input "$1")"
  local request_id team_id role text timeout
  request_id="$(jq -r '.request_id // ""' <<< "$input")"
  team_id="$(jq -r '.team_id // ""' <<< "$input")"
  role="$(jq -r '.role // ""' <<< "$input")"
  text="$(jq -r '.text // ""' <<< "$input")"
  timeout="$(jq -r '.timeout // 30000' <<< "$input")"

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -lt 1000 ] || [ "$timeout" -gt 300000 ]; then
    envelope_fail "member.prompt" "INVALID_TIMEOUT" "timeout must be an integer from 1000 to 300000 milliseconds" false
    return 1
  fi
  if ! herdr_manifest_exists "$team_id"; then
    envelope_fail "member.prompt" "NOT_FOUND" "Team '$team_id' not found" false
    return 1
  fi

  if herdr_manifest_lock "$team_id" 30 "$MEMBER_PROMPT_LOCK_TOKEN"; then
    MEMBER_PROMPT_LOCK_FILE="$HERDR_MANIFEST_LOCK_FILE"
  else
    envelope_fail "member.prompt" "LOCK_FAILED" "Could not acquire lock for team_id: $team_id" true
    return 1
  fi
  if ! herdr_manifest_exists "$team_id"; then
    member_prompt_release_lock
    envelope_fail "member.prompt" "NOT_FOUND" "Team '$team_id' not found" false
    return 1
  fi

  local manifest workspace_id bound_workspace
  manifest="$(herdr_manifest_read "$team_id")"
  workspace_id="$(herdr_get_workspace_id)"
  bound_workspace="$(jq -r '.workspace_id // ""' <<< "$manifest")"
  if [ "$bound_workspace" != "$workspace_id" ]; then
    member_prompt_release_lock
    envelope_fail "member.prompt" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    return 1
  fi

  local current_status
  current_status="$(jq -r '.status // "active"' <<< "$manifest")"
  if [ "$current_status" != "active" ]; then
    member_prompt_release_lock
    envelope_fail "member.prompt" "TEAM_NOT_ACTIVE" "Team '$team_id' is not active (status: $current_status)" false
    return 1
  fi

  local member
  member="$(jq -c --arg role "$role" '.members[] | select(.role == $role)' <<< "$manifest")"
  if [ -z "$member" ]; then
    member_prompt_release_lock
    envelope_fail "member.prompt" "MEMBER_NOT_FOUND" "Role '$role' not found in team '$team_id'" false
    return 1
  fi

  local prior_record prior_status
  prior_record="$(jq -c --arg role "$role" --arg request_id "$request_id" '
    (.prompt_history[$role] // null) as $history
    | if ($history | type) == "array" then
        if ($history | index($request_id)) == null then null else {status:"succeeded"} end
      elif ($history | type) == "object" then
        ($history[$request_id] // null)
      else null end
  ' <<< "$manifest")"
  prior_status="$(jq -r '.status // empty' <<< "$prior_record")"
  local target data
  target="$(jq -nc --arg team_id "$team_id" --arg role "$role" '{type:"member",team_id:$team_id,role:$role}')"
  data="$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id:$team_id,role:$role,prompt_sent:false}')"
  case "$prior_status" in
    succeeded)
      member_prompt_release_lock
      data="$(jq -c '.prompt_sent = true | .delivery_status = "succeeded"' <<< "$data")"
      envelope_already_applied "member.prompt" "$target" "$data"
      return 0
      ;;
    in_flight|unknown)
      member_prompt_release_lock
      data="$(jq -c --arg status "$prior_status" '.delivery_status = $status' <<< "$data")"
      envelope_unknown_outcome "member.prompt" "$target" "$data"
      return 0
      ;;
  esac

  local activation_outcome
  activation_outcome="$(jq -r --arg role "$role" '.activation_outcomes[$role] // empty' <<< "$manifest")"
  if [ "$activation_outcome" = "in_flight" ] || [ "$activation_outcome" = "unknown" ]; then
    member_prompt_release_lock
    data="$(jq -c --arg status "$activation_outcome" '.delivery_status = $status | .activation_unknown = true' <<< "$data")"
    envelope_unknown_outcome "member.prompt" "$target" "$data"
    return 0
  fi

  local pane_id agent_name activation member_status
  pane_id="$(jq -r '.pane_id // ""' <<< "$member")"
  agent_name="$(jq -r '.agent_name // ""' <<< "$member")"
  activation="$(jq -r '.activation // "deferred"' <<< "$member")"
  member_status="$(jq -r '.status // "active"' <<< "$member")"
  if [ -z "$agent_name" ] || [ -z "$pane_id" ] || [ "$member_status" = "closed" ]; then
    member_prompt_release_lock
    envelope_fail "member.prompt" "MEMBER_STATE_ERROR" "Member '$role' has no active pane/agent" false "$target" "$data"
    return 1
  fi

  local is_deferred=false
  if [ "$activation" = "deferred" ] && jq -e --arg role "$role" '(.deferred // []) | index($role) != null' >/dev/null <<< "$manifest"; then
    is_deferred=true
  fi

  local prompt_text="$text"
  if [ "$is_deferred" = "true" ]; then
    local role_prompt kickoff_context
    role_prompt="$(jq -r --arg role "$role" '.config.prompt_snapshots[$role] // ""' <<< "$manifest")"
    if [ -z "$role_prompt" ]; then
      member_prompt_release_lock
      envelope_fail "member.prompt" "MEMBER_STATE_ERROR" "Deferred prompt snapshot is missing for role '$role'" false "$target" "$data"
      return 1
    fi
    prompt_text="${role_prompt}

---

${text}"
    kickoff_context="$(jq -c '.kickoff_context // {}' <<< "$manifest")"
    if [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
      prompt_text="${prompt_text}

## Kickoff Context

$(jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")' <<< "$kickoff_context")"
    fi
  fi

  manifest="$(jq -c \
    --arg role "$role" \
    --arg request_id "$request_id" \
    --argjson was_deferred "$is_deferred" '
    .prompt_history = (.prompt_history // {})
    | .prompt_history[$role] = (
        if ((.prompt_history[$role] // null) | type) == "object"
        then .prompt_history[$role]
        else {} end
      )
    | .prompt_history[$role][$request_id] = {
        status: "in_flight",
        was_deferred: $was_deferred,
        updated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }
    | if $was_deferred then .activation_outcomes[$role] = "in_flight" else . end
  ' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"

  local result prompt_status
  result="$(herdr_cli_safe_call_timeout "$timeout" herdr agent prompt "$agent_name" "$prompt_text" --wait --timeout "$timeout")"
  prompt_status="$(herdr_cli_outcome "$result")"

  local prompt_err
  prompt_err="$(herdr_cli_error_code "$result" | tr '[:upper:]' '[:lower:]')"
  case "$prompt_status" in
    ok)
      manifest="$(jq -c --arg role "$role" --arg request_id "$request_id" --argjson was_deferred "$is_deferred" '
        .prompt_history[$role][$request_id].status = "succeeded"
        | .prompt_history[$role][$request_id].updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        | if $was_deferred then
            .deferred = ((.deferred // []) - [$role])
            | .activation_outcomes[$role] = "succeeded"
          else . end
      ' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
      member_prompt_release_lock
      data="$(jq -nc --arg team_id "$team_id" --arg role "$role" --arg pane_id "$pane_id" --arg agent_name "$agent_name" '{team_id:$team_id,role:$role,pane_id:$pane_id,agent_name:$agent_name,prompt_sent:true,delivery_status:"succeeded"}')"
      envelope_ok "member.prompt" "$target" "$data"
      ;;
    failed)
      if [[ "$prompt_err" == *timeout* ]] || [[ "$prompt_err" == *timed*out* ]] || [[ "$prompt_err" == *deadline* ]]; then
        manifest="$(jq -c --arg role "$role" --arg request_id "$request_id" --argjson was_deferred "$is_deferred" '
          .prompt_history[$role][$request_id].status = "unknown"
          | .prompt_history[$role][$request_id].updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          | if $was_deferred then .activation_outcomes[$role] = "unknown" else . end
        ' <<< "$manifest")"
        herdr_manifest_write "$team_id" "$manifest"
        member_prompt_release_lock
        data="$(jq -c '.delivery_status = "unknown"' <<< "$data")"
        envelope_unknown_outcome "member.prompt" "$target" "$data"
      else
        manifest="$(jq -c --arg role "$role" --arg request_id "$request_id" --argjson was_deferred "$is_deferred" '
          .prompt_history[$role][$request_id].status = "failed"
          | .prompt_history[$role][$request_id].updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          | if $was_deferred then .activation_outcomes[$role] = "failed" else . end
        ' <<< "$manifest")"
        herdr_manifest_write "$team_id" "$manifest"
        member_prompt_release_lock
        data="$(jq -c '.delivery_status = "failed"' <<< "$data")"
        envelope_fail "member.prompt" "PROMPT_FAILED" "Failed to send prompt to role '$role'" true "$target" "$data"
        return 1
      fi
      ;;
    *)
      manifest="$(jq -c --arg role "$role" --arg request_id "$request_id" --argjson was_deferred "$is_deferred" '
        .prompt_history[$role][$request_id].status = "unknown"
        | .prompt_history[$role][$request_id].updated_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        | if $was_deferred then .activation_outcomes[$role] = "unknown" else . end
      ' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
      member_prompt_release_lock
      data="$(jq -c '.delivery_status = "unknown"' <<< "$data")"
      envelope_unknown_outcome "member.prompt" "$target" "$data"
      ;;
  esac
}

main "$@"
