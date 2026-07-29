#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/config.sh"

herdr_team_generate_id() {
  local kind="${1:-h}"
  local ts
  ts="$(date +%s)"
  local rand
  rand="$(head -c 4 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 4)"
  echo "${kind}-${ts}-${rand}"
}

herdr_get_current_pane() {
  herdr pane current 2>/dev/null | jq -c '.' 2>/dev/null || echo '{}'
}

herdr_pane_split() {
  local direction="${1:-right}"
  local pane_current
  pane_current="$(herdr_get_current_pane)"
  local workspace_id
  workspace_id="$(echo "$pane_current" | jq -r '.result.pane.workspace_id // ""')"
  local tab_id
  tab_id="$(echo "$pane_current" | jq -r '.result.pane.tab_id // ""')"

  herdr pane split --current --direction "$direction" --cwd "$PWD" --no-focus 2>/dev/null \
    | jq -c '.' 2>/dev/null || echo '{"status":"failed"}'
}

herdr_agent_start() {
  local name="$1"
  local kind="$2"
  local pane_id="$3"
  herdr agent start "$name" --kind "$kind" --pane "$pane_id" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{"status":"failed"}'
}

herdr_agent_rename() {
  local pane_id="$1"
  local name="$2"
  herdr agent rename "$pane_id" "$name" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{"status":"failed"}'
}

herdr_agent_prompt() {
  local target="$1"
  local text="$2"
  local timeout="${3:-30000}"
  herdr agent prompt "$target" "$text" --wait --timeout "$timeout" 2>/dev/null | jq -c '.' 2>/dev/null || echo '{"status":"failed"}'
}

main() {
  local input
  input="$(herdr_read_input "$1")"
  local request_id config_path origin_kind grant keep_on_failure kickoff_context
  request_id="$(echo "$input" | jq -r '.request_id // ""')"
  config_path="$(echo "$input" | jq -r '.config_path // ""')"
  origin_kind="$(echo "$input" | jq -r '.origin_kind // ""')"
  keep_on_failure="$(echo "$input" | jq -r '.keep_on_failure // false')"
  kickoff_context="$(echo "$input" | jq -c '.kickoff_context // {}')"

  if [ -z "$request_id" ]; then
    envelope_fail "team.start" "MISSING_REQUIRED_FIELD" "Required field 'request_id' is missing" false
    exit 1
  fi

  local existing_duplicate
  existing_duplicate="$(herdr_manifest_find_by_request_id "$request_id")"
  if [ -n "$existing_duplicate" ] && [ "$existing_duplicate" != "null" ]; then
    local dup_manifest
    dup_manifest="$(herdr_manifest_read "$existing_duplicate")"
    local dup_members
    dup_members="$(echo "$dup_manifest" | jq -c '{
      team_id: .team_id,
      members: [.members[] | {role: .role, kind: .kind, activation: .activation, agent_name: .agent_name, pane_id: .pane_id}],
      manifest_path: "'"$(herdr_manifest_path "$existing_duplicate")"'"
    }')"
    envelope_already_applied "team.start" "{\"type\":\"team\",\"team_id\":\"$existing_duplicate\"}" "$dup_members"
    exit 0
  fi

  local current_pane workspace_id
  current_pane="$(herdr_get_current_pane)"
  workspace_id="$(echo "$current_pane" | jq -r '.result.pane.workspace_id // ""')"

  if [ -z "$workspace_id" ] || [ "$workspace_id" = "null" ]; then
    envelope_fail "team.start" "HERDR_ERROR" "Cannot determine current workspace. Is herdr running?" false
    exit 1
  fi

  local detected_kind
  detected_kind="$(echo "$current_pane" | jq -r '.result.pane.agent // ""')"
  local kind="${origin_kind:-$detected_kind}"
  if [ -z "$kind" ] || [ "$kind" = "null" ]; then
    kind="opencode"
  fi

  local config_json
  config_json="$(herdr_config_resolve "$config_path" "$kind")"

  local member_count
  member_count="$(echo "$config_json" | jq -r '.members | length // 0')"

  if [ "$member_count" -eq 0 ]; then
    envelope_fail "team.start" "CONFIG_ERROR" "No valid team members found in config" false
    exit 1
  fi

  local team_id
  team_id="$(herdr_team_generate_id "$kind")"

  local deferred_prompts=""
  local created_panes=""
  local created_agents=""
  local members_json=""

  members_json="$(echo "$config_json" | jq -c --arg kind "$kind" --arg team_id "$team_id" '
    .members | [.[] | {
      role: .role,
      kind: (.kind // $kind),
      activation: (.activation // (if .role == "impl" then "immediate" else "deferred" end)),
      prompt_file: (.prompt_file // null),
      agent_name: (.kind // $kind) + "-" + .role + "-" + ($team_id[0:8]),
      pane_display_name: .role + " [" + (.kind // $kind) + "]"
    }]
  ')"

  local layout_dir="right"
  local pane_width
  pane_width="$(echo "$current_pane" | jq -r '.result.pane.cols // 0')"
  if [ "$pane_width" -lt 120 ] 2>/dev/null || [ "$pane_width" = "0" ]; then
    layout_dir="down"
  fi

  local count
  count="$(echo "$members_json" | jq -r 'length')"
  local i
  for i in $(seq 0 $((count - 1))); do
    local member role agent_name pane_display_name activation
    member="$(echo "$members_json" | jq -c ".[$i]")"
    role="$(echo "$member" | jq -r '.role')"
    agent_name="$(echo "$member" | jq -r '.agent_name')"
    pane_display_name="$(echo "$member" | jq -r '.pane_display_name')"
    activation="$(echo "$member" | jq -r '.activation')"

    local split_result pane_id
    split_result="$(herdr_pane_split "$layout_dir")"
    pane_id="$(echo "$split_result" | jq -r '.result.pane.pane_id // ""')"

    if [ -z "$pane_id" ] || [ "$pane_id" = "null" ]; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      envelope_fail "team.start" "PANEL_CREATE_FAILED" "Failed to split pane for role '$role'" false
      exit 1
    fi

    created_panes="${created_panes}${pane_id}\n"

    local agent_status
    agent_status="$(herdr pane get "$pane_id" 2>/dev/null | jq -r '.result.pane.agent_status // "unknown"')"

    local agent_result
    if [ "$agent_status" = "unknown" ]; then
      agent_result="$(herdr_agent_start "$agent_name" "$kind" "$pane_id")"
    else
      agent_result="$(herdr_agent_rename "$pane_id" "$agent_name")"
    fi

    local agent_start_ok
    agent_start_ok="$(echo "$agent_result" | jq -r '.status // "failed"')"

    if [ "$agent_start_ok" != "ok" ] && [ "$agent_start_ok" != "completed" ]; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      envelope_fail "team.start" "AGENT_START_FAILED" "Failed to start agent for role '$role'" false
      exit 1
    fi

    created_agents="${created_agents}${agent_name}\n"

    if [ "$activation" = "immediate" ]; then
      local role_prompt
      role_prompt="$(herdr_config_resolve_prompt "$config_json" "$role")"
      local prompt_text="$role_prompt"
      if [ -n "$kickoff_context" ] && [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
        prompt_text="${prompt_text}\n\n## Kickoff Context\n\n$(echo "$kickoff_context" | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")')"
      fi

      local prompt_result
      prompt_result="$(herdr_agent_prompt "$agent_name" "$prompt_text" 30000)"
      local prompt_status
      prompt_status="$(echo "$prompt_result" | jq -r '.status // "failed"')"

      if [ "$prompt_status" != "ok" ] && [ "$prompt_status" != "completed" ]; then
        echo "WARNING: prompt to $role ($agent_name) may not have been sent: $prompt_status" >&2
      fi
    else
      deferred_prompts="${deferred_prompts}${role}\n"
    fi

    members_json="$(echo "$members_json" | jq -c --arg i "$i" --arg pane_id "$pane_id" '
      .[$i|tonumber] |= . + {pane_id: $pane_id}
    ')"
  done

  local manifest_json
  manifest_json="$(jq -nc \
    --arg team_id "$team_id" \
    --arg workspace_id "$workspace_id" \
    --arg request_id "$request_id" \
    --argjson members "$members_json" \
    --argjson kickoff_context "$(echo "$kickoff_context" | jq -c '. // {}')" \
    '{
      schema_version: 1,
      team_id: $team_id,
      workspace_id: $workspace_id,
      request_id: $request_id,
      members: $members,
      kickoff_context: $kickoff_context,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "active",
      deferred: [],
      prompt_history: {}
    }')"

  herdr_manifest_write "$team_id" "$manifest_json"

  local summary
  summary="$(echo "$members_json" | jq -c '{
    team_id: "'"$team_id"'",
    members: [.[] | {role: .role, kind: .kind, activation: .activation, agent_name: .agent_name, pane_id: .pane_id}],
    manifest_path: "'"$(herdr_manifest_path "$team_id")"'"
  }')"

  envelope_ok "team.start" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" "$summary"
}

herdr_rollback_panes() {
  local panes="$1"
  if [ -z "$panes" ]; then
    return 0
  fi
  echo -e "$panes" | while read -r pane_id; do
    [ -z "$pane_id" ] && continue
    herdr pane close "$pane_id" 2>/dev/null || true
  done
}

main "$@"
