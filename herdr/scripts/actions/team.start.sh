#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/config.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

TEAM_START_LOCK_FILE=""
TEAM_START_PROCESS_ID="$BASHPID"
TEAM_START_LOCK_TOKEN="team-start-${BASHPID}-${RANDOM}-${RANDOM}"

herdr_team_release_lock() {
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  [ "$BASHPID" = "$TEAM_START_PROCESS_ID" ] || return 0
  if [ -n "$TEAM_START_LOCK_FILE" ]; then
    herdr_manifest_unlock "$TEAM_START_LOCK_FILE" "$TEAM_START_LOCK_TOKEN" || true
    TEAM_START_LOCK_FILE=""
  fi
}

herdr_team_generate_id() {
  local ts random_hex
  ts="$(date +%s)"
  random_hex="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  echo "${ts}-${random_hex}"
}

herdr_agent_prepare_before_deadline() {
  local deadline_ms="$1"
  local pane_id="$2"
  local agent_name="$3"
  local member_kind="$4"

  while ! herdr_cli_deadline_expired "$deadline_ms"; do
    local pane_info pane_outcome agent_status
    pane_info="$(herdr_cli_call_before_deadline "$deadline_ms" herdr pane get "$pane_id")"
    pane_outcome="$(herdr_cli_outcome "$pane_info")"
    if [ "$pane_outcome" = "unknown" ]; then
      sleep 0.1
      continue
    fi
    if [ "$pane_outcome" = "failed" ]; then
      printf '%s\n' "$pane_info"
      return 0
    fi

    agent_status="$(jq -r '.result.pane.agent_status // "unknown"' <<< "$pane_info")"
    case "$agent_status" in
      agent_pane_busy|busy|starting|initializing)
        sleep 0.1
        continue
        ;;
    esac

    local remaining result error_code
    remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
    [ "$remaining" -gt 0 ] || break
    if [ "$agent_status" = "unknown" ]; then
      result="$(herdr_cli_safe_call_timeout "$remaining" herdr agent start "$agent_name" --kind "$member_kind" --pane "$pane_id")"
    else
      result="$(herdr_cli_safe_call_timeout "$remaining" herdr agent rename "$pane_id" "$agent_name")"
    fi

    if [ "$result" = "{}" ]; then
      sleep 0.1
      continue
    fi

    error_code="$(herdr_cli_error_code "$result" | tr '[:upper:]' '[:lower:]')"
    case "$error_code" in
      *agent*pane*busy*|*pane*busy*)
        sleep 0.1
        continue
        ;;
    esac
    printf '%s\n' "$result"
    return 0
  done

  echo '{}'
}

herdr_team_rollback_manifest() {
  local manifest="$1"
  local count i
  count="$(jq -r '.members | length' <<< "$manifest")"

  for ((i = 0; i < count; i++)); do
    local pane_id member_status close_result close_outcome
    pane_id="$(jq -r ".members[$i].pane_id // \"\"" <<< "$manifest")"
    member_status="$(jq -r ".members[$i].status // \"pending\"" <<< "$manifest")"

    if [ "$member_status" = "closed" ]; then
      continue
    fi
    if [ -z "$pane_id" ]; then
      if [ "$member_status" = "pane-creating" ] || [ "$member_status" = "pane-unknown" ]; then
        manifest="$(jq -c --argjson i "$i" '.members[$i].status = "close-unknown"' <<< "$manifest")"
      else
        manifest="$(jq -c --argjson i "$i" '.members[$i].status = "closed"' <<< "$manifest")"
      fi
      continue
    fi

    close_result="$(herdr_cli_safe_call_timeout 2000 herdr pane close "$pane_id")"
    close_outcome="$(herdr_cli_outcome "$close_result")"
    case "$close_outcome" in
      ok) member_status="closed" ;;
      failed) member_status="close-failed" ;;
      *) member_status="close-unknown" ;;
    esac
    manifest="$(jq -c --argjson i "$i" --arg status "$member_status" '.members[$i].status = $status' <<< "$manifest")"
  done

  local remaining
  remaining="$(jq -r '[.members[] | select((.status // "pending") != "closed")] | length' <<< "$manifest")"
  if [ "$remaining" -eq 0 ]; then
    jq -c '.status = "rollback-complete" | .start_outcome = "failed"' <<< "$manifest"
  else
    jq -c '.status = "rollback-incomplete" | .start_outcome = "failed"' <<< "$manifest"
  fi
}

herdr_team_known_failure() {
  local team_id="$1"
  local manifest="$2"
  local keep_on_failure="$3"
  local code="$4"
  local message="$5"
  local role="${6:-}"
  local cleanup_complete=false

  if [ "$keep_on_failure" = "true" ]; then
    manifest="$(jq -c '.status = "start-failed" | .start_outcome = "failed"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"
  else
    manifest="$(herdr_team_rollback_manifest "$manifest")"
    if [ "$(jq -r '.status' <<< "$manifest")" = "rollback-complete" ]; then
      cleanup_complete=true
      herdr_manifest_delete "$team_id"
    else
      herdr_manifest_write "$team_id" "$manifest"
    fi
  fi

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    --argjson cleanup_complete "$cleanup_complete" \
    --argjson members "$(jq -c '[.members[] | {role, pane_id, status}]' <<< "$manifest")" \
    '{team_id: $team_id, failed_role: (if $role == "" then null else $role end), cleanup_complete: $cleanup_complete, members: $members}')"
  herdr_team_release_lock
  envelope_fail "team.start" "$code" "$message" false \
    "$(jq -nc --arg team_id "$team_id" '{type:"team", team_id:$team_id}')" "$data"
  return 1
}

herdr_team_unknown() {
  local team_id="$1"
  local manifest="$2"
  local role="${3:-}"
  local phase="${4:-unknown}"
  manifest="$(jq -c --arg role "$role" --arg phase "$phase" '
    .status = "unknown_outcome"
    | .start_outcome = "unknown"
    | .unknown_phase = $phase
    | .unknown_role = (if $role == "" then null else $role end)
  ' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    --arg phase "$phase" \
    --argjson members "$(jq -c '[.members[] | {role, pane_id, status}]' <<< "$manifest")" \
    '{team_id: $team_id, role: (if $role == "" then null else $role end), phase: $phase, members: $members}')"
  herdr_team_release_lock
  envelope_unknown_outcome "team.start" \
    "$(jq -nc --arg team_id "$team_id" '{type:"team", team_id:$team_id}')" "$data"
}

main() {
  local input
  input="$(herdr_read_input "$1")"
  local request_id config_path origin_kind keep_on_failure kickoff_context timeout
  request_id="$(jq -r '.request_id // ""' <<< "$input")"
  config_path="$(jq -r '.config_path // ""' <<< "$input")"
  origin_kind="$(jq -r '.origin_kind // ""' <<< "$input")"
  keep_on_failure="$(jq -r '.keep_on_failure // false' <<< "$input")"
  kickoff_context="$(jq -c '.kickoff_context // {}' <<< "$input")"
  timeout="$(jq -r '.timeout // 30000' <<< "$input")"

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -lt 5000 ] || [ "$timeout" -gt 300000 ]; then
    envelope_fail "team.start" "INVALID_TIMEOUT" "timeout must be an integer from 5000 to 300000 milliseconds" false
    return 1
  fi

  local deadline_ms lock_timeout_sec
  deadline_ms="$(herdr_cli_deadline_from_timeout "$timeout")"
  lock_timeout_sec="$(awk -v ms="$timeout" 'BEGIN { printf "%.3f", ms / 1000 }')"
  if herdr_manifest_lock "$request_id" "$lock_timeout_sec" "$TEAM_START_LOCK_TOKEN"; then
    TEAM_START_LOCK_FILE="$HERDR_MANIFEST_LOCK_FILE"
  else
    if herdr_cli_deadline_expired "$deadline_ms"; then
      envelope_fail "team.start" "TIMEOUT" "Start deadline expired while waiting for request lock" true
    else
      envelope_fail "team.start" "LOCK_FAILED" "Could not acquire lock for request_id: $request_id" true
    fi
    return 1
  fi

  local current_pane current_outcome workspace_id detected_kind kind
  current_pane="$(herdr_cli_call_before_deadline "$deadline_ms" herdr pane current)"
  current_outcome="$(herdr_cli_outcome "$current_pane")"
  if [ "$current_outcome" != "ok" ]; then
    herdr_team_release_lock
    if [ "$current_outcome" = "unknown" ]; then
      envelope_unknown_outcome "team.start" '{"type":"team"}' '{"phase":"pane.current"}'
      return 0
    fi
    envelope_fail "team.start" "HERDR_ERROR" "Cannot determine current Herdr pane" false
    return 1
  fi
  workspace_id="$(jq -r '.result.pane.workspace_id // ""' <<< "$current_pane")"
  detected_kind="$(jq -r '.result.pane.agent // ""' <<< "$current_pane")"
  kind="${origin_kind:-$detected_kind}"
  [ -n "$kind" ] || kind="opencode"
  if [ -z "$workspace_id" ]; then
    herdr_team_release_lock
    envelope_fail "team.start" "HERDR_ERROR" "Current pane response has no workspace_id" false
    return 1
  fi

  local existing_duplicate
  existing_duplicate="$(herdr_manifest_find_by_request_id "$request_id" "$workspace_id")"
  if [ -n "$existing_duplicate" ]; then
    local duplicate dup_status dup_data
    duplicate="$(herdr_manifest_read "$existing_duplicate")"
    dup_status="$(jq -r '.status // "active"' <<< "$duplicate")"
    dup_data="$(jq -c '{team_id, start_outcome: (.start_outcome // null), members: [.members[] | {role, kind, activation, agent_name, pane_id, status}]}' <<< "$duplicate")"
    herdr_team_release_lock
    case "$dup_status" in
      active|stopped)
        envelope_already_applied "team.start" "$(jq -nc --arg team_id "$existing_duplicate" '{type:"team",team_id:$team_id}')" "$dup_data"
        ;;
      *)
        envelope_unknown_outcome "team.start" "$(jq -nc --arg team_id "$existing_duplicate" '{type:"team",team_id:$team_id}')" "$dup_data"
        ;;
    esac
    return 0
  fi

  local config_json
  if ! config_json="$(herdr_config_resolve "$config_path" "$kind" 2>/dev/null)"; then
    herdr_team_release_lock
    envelope_fail "team.start" "CONFIG_ERROR" "Config resolution or schema validation failed" false
    return 1
  fi
  if ! herdr_config_validate_members "$config_json" 2>/dev/null; then
    herdr_team_release_lock
    envelope_fail "team.start" "CONFIG_ERROR" "Config validation failed" false
    return 1
  fi

  local prompt_snapshots
  if ! prompt_snapshots="$(herdr_config_snapshot_prompts "$config_json" 2>/dev/null)"; then
    herdr_team_release_lock
    envelope_fail "team.start" "CONFIG_ERROR" "Could not snapshot all role prompts" false
    return 1
  fi

  local team_id team_short_id members_json deferred_json saved_config_json manifest
  team_id="$(herdr_team_generate_id)"
  team_short_id="${team_id: -8}"
  members_json="$(jq -c --arg kind "$kind" --arg team_sid "$team_short_id" '
    [.members[] | {
      role,
      kind: (.kind // $kind),
      activation: (.activation // (if .role == "impl" then "immediate" else "deferred" end)),
      prompt_file: (.prompt_file // null),
      agent_name: ((.kind // $kind) + "-" + .role + "-" + $team_sid),
      pane_display_name: (.role + " [" + (.kind // $kind) + "]"),
      pane_id: null,
      status: "pending"
    }]
  ' <<< "$config_json")"
  deferred_json="$(jq -c '[.[] | select(.activation == "deferred") | .role]' <<< "$members_json")"
  saved_config_json="$(jq -c --argjson prompts "$prompt_snapshots" '{
    schema_version, _config_dir, _config_path,
    members: [.members[] | {role, kind, activation, prompt_file}],
    prompt_snapshots: $prompts
  }' <<< "$config_json")"
  manifest="$(jq -nc \
    --arg team_id "$team_id" \
    --arg workspace_id "$workspace_id" \
    --arg request_id "$request_id" \
    --argjson members "$members_json" \
    --argjson kickoff_context "$kickoff_context" \
    --argjson deferred "$deferred_json" \
    --argjson config "$saved_config_json" '
    {
      schema_version: 1,
      team_id: $team_id,
      workspace_id: $workspace_id,
      request_id: $request_id,
      members: $members,
      config: $config,
      kickoff_context: $kickoff_context,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "starting",
      start_outcome: "in_flight",
      deferred: $deferred,
      prompt_history: {}
    }')"
  herdr_manifest_write "$team_id" "$manifest"

  local layout_dir="right" pane_width
  pane_width="$(jq -r '.result.pane.cols // 0' <<< "$current_pane")"
  if [ "$pane_width" -lt 120 ] 2>/dev/null || [ "$pane_width" -eq 0 ] 2>/dev/null; then
    layout_dir="down"
  fi

  local count i
  count="$(jq -r '.members | length' <<< "$manifest")"
  for ((i = 0; i < count; i++)); do
    local role agent_name pane_display_name activation member_kind
    role="$(jq -r ".members[$i].role" <<< "$manifest")"
    agent_name="$(jq -r ".members[$i].agent_name" <<< "$manifest")"
    pane_display_name="$(jq -r ".members[$i].pane_display_name" <<< "$manifest")"
    activation="$(jq -r ".members[$i].activation" <<< "$manifest")"
    member_kind="$(jq -r ".members[$i].kind" <<< "$manifest")"

    if herdr_cli_deadline_expired "$deadline_ms"; then
      herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" "TIMEOUT" "Start deadline expired before pane creation" "$role"
      return $?
    fi

    manifest="$(jq -c --argjson i "$i" '.members[$i].status = "pane-creating"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"

    local split_result split_outcome pane_id
    split_result="$(herdr_cli_call_before_deadline "$deadline_ms" herdr pane split --current --direction "$layout_dir" --cwd "$PWD" --no-focus)"
    split_outcome="$(herdr_cli_outcome "$split_result")"
    pane_id="$(jq -r '.result.pane.pane_id // ""' <<< "$split_result")"
    if [ "$split_outcome" = "failed" ]; then
      manifest="$(jq -c --argjson i "$i" '.members[$i].status = "pane-failed"' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
      herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" "PANE_CREATE_FAILED" "Failed to split pane for role '$role'" "$role"
      return $?
    fi
    if [ "$split_outcome" = "unknown" ] || [ -z "$pane_id" ]; then
      manifest="$(jq -c --argjson i "$i" '.members[$i].status = "pane-unknown"' <<< "$manifest")"
      herdr_team_unknown "$team_id" "$manifest" "$role" "pane.split"
      return 0
    fi

    manifest="$(jq -c --argjson i "$i" --arg pane_id "$pane_id" '.members[$i].pane_id = $pane_id | .members[$i].status = "pane-created"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"

    sleep 0.2

    local agent_result agent_outcome
    agent_result="$(herdr_agent_prepare_before_deadline "$deadline_ms" "$pane_id" "$agent_name" "$member_kind")"
    agent_outcome="$(herdr_cli_outcome "$agent_result")"
    if [ "$agent_outcome" = "failed" ]; then
      herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" "AGENT_START_FAILED" "Failed to start or rename agent for role '$role'" "$role"
      return $?
    fi
    if [ "$agent_outcome" = "unknown" ]; then
      manifest="$(jq -c --argjson i "$i" '.members[$i].status = "agent-unknown"' <<< "$manifest")"
      herdr_team_unknown "$team_id" "$manifest" "$role" "agent.start"
      return 0
    fi

    manifest="$(jq -c --argjson i "$i" '.members[$i].status = "active"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"
    local label_remaining
    label_remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
    if [ "$label_remaining" -gt 0 ]; then
      herdr_cli_safe_call_timeout "$label_remaining" herdr pane label "$pane_id" "$pane_display_name" >/dev/null
    fi

    if [ "$activation" = "immediate" ]; then
      local role_prompt prompt_text
      role_prompt="$(jq -r --arg role "$role" '.[$role] // ""' <<< "$prompt_snapshots")"
      prompt_text="$role_prompt"
      if [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
        prompt_text="${prompt_text}

## Kickoff Context

$(jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")' <<< "$kickoff_context")"
      fi

      manifest="$(jq -c --arg role "$role" '.start_prompt = {role: $role, status: "in_flight"}' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
      local remaining prompt_result prompt_outcome
      remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
      if [ "$remaining" -le 0 ]; then
        prompt_result='{}'
      else
        prompt_result="$(herdr_cli_safe_call_timeout "$remaining" herdr agent prompt "$agent_name" "$prompt_text" --wait --timeout "$remaining")"
      fi
      prompt_outcome="$(herdr_cli_outcome "$prompt_result")"
      if [ "$prompt_outcome" = "failed" ]; then
        local start_prompt_err
        start_prompt_err="$(herdr_cli_error_code "$prompt_result" | tr '[:upper:]' '[:lower:]')"
        if [[ "$start_prompt_err" == *timeout* ]] || [[ "$start_prompt_err" == *timed*out* ]] || [[ "$start_prompt_err" == *deadline* ]]; then
          manifest="$(jq -c '.start_prompt.status = "unknown"' <<< "$manifest")"
          herdr_team_unknown "$team_id" "$manifest" "$role" "kickoff.prompt"
          return 0
        fi
        manifest="$(jq -c '.start_prompt.status = "failed"' <<< "$manifest")"
        herdr_manifest_write "$team_id" "$manifest"
        herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" "PROMPT_FAILED" "Failed to send kickoff prompt to role '$role'" "$role"
        return $?
      fi
      if [ "$prompt_outcome" = "unknown" ]; then
        manifest="$(jq -c '.start_prompt.status = "unknown"' <<< "$manifest")"
        herdr_team_unknown "$team_id" "$manifest" "$role" "kickoff.prompt"
        return 0
      fi
      manifest="$(jq -c '.start_prompt.status = "succeeded"' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
    fi
  done

  manifest="$(jq -c '.status = "active" | .start_outcome = "succeeded"' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"
  local summary
  summary="$(jq -c --arg manifest_path "$(herdr_manifest_path "$team_id")" '{
    team_id,
    members: [.members[] | {role, kind, activation, agent_name, pane_id, status}],
    manifest_path: $manifest_path
  }' <<< "$manifest")"
  herdr_team_release_lock
  envelope_ok "team.start" "$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')" "$summary"
}

main "$@"
