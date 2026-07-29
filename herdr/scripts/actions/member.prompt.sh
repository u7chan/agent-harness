#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/config.sh"

main() {
  local input
  input="$(herdr_read_input "$1")"
  local request_id team_id role text timeout
  request_id="$(echo "$input" | jq -r '.request_id // ""')"
  team_id="$(echo "$input" | jq -r '.team_id // ""')"
  role="$(echo "$input" | jq -r '.role // ""')"
  text="$(echo "$input" | jq -r '.text // ""')"
  timeout="$(echo "$input" | jq -r '.timeout // 30000')"

  if [ -z "$request_id" ]; then
    envelope_fail "member.prompt" "MISSING_REQUIRED_FIELD" "Required field 'request_id' is missing" false
    exit 1
  fi
  if [ -z "$team_id" ]; then
    envelope_fail "member.prompt" "MISSING_REQUIRED_FIELD" "Required field 'team_id' is missing" false
    exit 1
  fi
  if [ -z "$role" ]; then
    envelope_fail "member.prompt" "MISSING_REQUIRED_FIELD" "Required field 'role' is missing" false
    exit 1
  fi
  if [ -z "$text" ]; then
    envelope_fail "member.prompt" "MISSING_REQUIRED_FIELD" "Required field 'text' is missing" false
    exit 1
  fi

  if [ "$timeout" -gt 300000 ] 2>/dev/null; then
    timeout=300000
  elif [ "$timeout" -lt 1000 ] 2>/dev/null; then
    timeout=30000
  fi

  if ! herdr_manifest_exists "$team_id"; then
    envelope_fail "member.prompt" "NOT_FOUND" "Team '$team_id' not found" false
    exit 1
  fi

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  local workspace_id
  workspace_id="$(herdr_get_workspace_id)"
  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    envelope_fail "member.prompt" "WORKSPACE_MISMATCH" "Team '$team_id' is bound to workspace '$bound_workspace', current is '$workspace_id'" false
    exit 1
  fi

  local current_status
  current_status="$(echo "$manifest" | jq -r '.status // "active"')"
  if [ "$current_status" != "active" ]; then
    envelope_fail "member.prompt" "TEAM_NOT_ACTIVE" "Team '$team_id' is not active (status: $current_status)" false
    exit 1
  fi

  local member
  member="$(echo "$manifest" | jq -c --arg role "$role" '.members[] | select(.role == $role)')"

  if [ -z "$member" ] || [ "$member" = "null" ]; then
    envelope_fail "member.prompt" "MEMBER_NOT_FOUND" "Role '$role' not found in team '$team_id'" false
    exit 1
  fi

  local prompt_history
  prompt_history="$(echo "$manifest" | jq -c --arg request_id "$request_id" --arg role "$role" '
    .prompt_history // {}
    | if .[$role] and (.[$role] | index($request_id)) then true else false end
  ')"
  if [ "$prompt_history" = "true" ]; then
    envelope_already_applied "member.prompt" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$(jq -nc --arg team_id "$team_id" --arg role "$role" '{team_id: $team_id, role: $role, prompt_sent: true}')"
    exit 0
  fi

  local pane_id agent_name activation
  pane_id="$(echo "$member" | jq -r '.pane_id // ""')"
  agent_name="$(echo "$member" | jq -r '.agent_name // ""')"
  activation="$(echo "$member" | jq -r '.activation // "deferred"')"

  if [ -z "$agent_name" ] || [ "$agent_name" = "null" ]; then
    envelope_fail "member.prompt" "MEMBER_STATE_ERROR" "Agent name not found for role '$role'" false
    exit 1
  fi

  local config_json
  config_json="$(herdr_config_resolve "" "$(echo "$member" | jq -r '.kind // "opencode"')")"

  local is_deferred="false"
  local deferred_list
  deferred_list="$(echo "$manifest" | jq -r --arg role "$role" '
    .deferred // [] | index($role)
  ')"
  if [ -n "$deferred_list" ] && [ "$deferred_list" != "null" ]; then
    is_deferred="true"
  fi

  local prompt_text="$text"

  if [ "$is_deferred" = "true" ] && [ "$activation" = "deferred" ]; then
    local role_prompt
    role_prompt="$(herdr_config_resolve_prompt "$config_json" "$role" 2>/dev/null || echo "")"
    if [ -n "$role_prompt" ]; then
      prompt_text="${role_prompt}\n\n---\n\n${text}"
    fi

    local kickoff_context
    kickoff_context="$(echo "$manifest" | jq -c '.kickoff_context // {}')"
    if [ -n "$kickoff_context" ] && [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
      prompt_text="${prompt_text}\n\n## Kickoff Context\n\n$(echo "$kickoff_context" | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")')"
    fi

    manifest="$(echo "$manifest" | jq -c --arg role "$role" '
      .deferred = ((.deferred // []) - [$role])
    ')"
  fi

  local result
  result="$(herdr agent prompt "$agent_name" "$prompt_text" --wait --timeout "$timeout" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{"status":"unknown"}')"

  local prompt_status
  prompt_status="$(echo "$result" | jq -r '.status // "unknown"')"

  manifest="$(echo "$manifest" | jq -c --arg request_id "$request_id" --arg role "$role" '
    .prompt_history[$role] = ((.prompt_history[$role] // []) + [$request_id])
  ')"

  herdr_manifest_write "$team_id" "$manifest"

  local data
  data="$(jq -nc \
    --arg team_id "$team_id" \
    --arg role "$role" \
    --arg pane_id "$pane_id" \
    --arg agent_name "$agent_name" \
    --argjson prompt_sent "$([ "$prompt_status" = "ok" ] || [ "$prompt_status" = "completed" ] && echo true || echo false)" \
    '{
      team_id: $team_id,
      role: $role,
      pane_id: $pane_id,
      agent_name: $agent_name,
      prompt_sent: $prompt_sent
    }')"

  if [ "$prompt_status" = "ok" ] || [ "$prompt_status" = "completed" ]; then
    envelope_ok "member.prompt" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
  elif [ "$prompt_status" = "unknown" ]; then
    envelope_unknown_outcome "member.prompt" "{\"type\":\"member\",\"team_id\":\"$team_id\",\"role\":\"$role\"}" "$data"
  else
    envelope_fail "member.prompt" "PROMPT_FAILED" "Failed to send prompt to $role: status=$prompt_status" true
  fi
}

main "$@"
