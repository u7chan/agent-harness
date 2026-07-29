#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/config.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"

herdr_team_generate_id() {
  local ts
  ts="$(date +%s)"
  local rand
  rand="$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
  echo "${ts}-${rand}"
}

herdr_get_current_pane() {
  herdr_cli_safe_call herdr pane current
}

herdr_pane_split() {
  local direction="${1:-right}"
  herdr_cli_safe_call herdr pane split --current --direction "$direction" --cwd "$PWD" --no-focus
}

herdr_agent_start() {
  local name="$1"
  local kind="$2"
  local pane_id="$3"
  herdr_cli_safe_call herdr agent start "$name" --kind "$kind" --pane "$pane_id"
}

herdr_agent_rename() {
  local pane_id="$1"
  local name="$2"
  herdr_cli_safe_call herdr agent rename "$pane_id" "$name"
}

herdr_agent_prompt() {
  local target="$1"
  local text="$2"
  local timeout="${3:-30000}"
  herdr_cli_safe_call herdr agent prompt "$target" "$text" --wait --timeout "$timeout"
}

herdr_agent_label() {
  local pane_id="$1"
  local label="$2"
  herdr pane label "$pane_id" "$label" >/dev/null 2>&1 || true
}

herdr_agent_ready_wait() {
  local pane_id="$1"
  local deadline_epoch="$2"
  local max_attempts=10
  local attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if herdr_cli_deadline_expired "$deadline_epoch"; then
      return 1
    fi
    local info
    info="$(herdr_cli_safe_call herdr pane get "$pane_id")"
    local agent_status
    agent_status="$(echo "$info" | jq -r '.result.pane.agent_status // "unknown"')"
    if [ "$agent_status" = "running" ] || [ "$agent_status" = "idle" ] || [ "$agent_status" = "unknown" ]; then
      return 0
    elif [ "$agent_status" = "agent_pane_busy" ]; then
      sleep 0.5
      attempt=$((attempt + 1))
    else
      return 0
    fi
  done
  return 1
}

main() {
  local input
  input="$(herdr_read_input "$1")"
  local request_id config_path origin_kind grant keep_on_failure kickoff_context timeout
  request_id="$(echo "$input" | jq -r '.request_id // ""')"
  config_path="$(echo "$input" | jq -r '.config_path // ""')"
  origin_kind="$(echo "$input" | jq -r '.origin_kind // ""')"
  keep_on_failure="$(echo "$input" | jq -r '.keep_on_failure // false')"
  kickoff_context="$(echo "$input" | jq -c '.kickoff_context // {}')"
  timeout="$(echo "$input" | jq -r '.timeout // 30000')"

  if [ -z "$request_id" ]; then
    envelope_fail "team.start" "MISSING_REQUIRED_FIELD" "Required field 'request_id' is missing" false
    exit 1
  fi

  if [ "$timeout" -gt 300000 ] 2>/dev/null; then
    timeout=300000
  elif [ "$timeout" -lt 5000 ] 2>/dev/null; then
    timeout=30000
  fi

  local deadline_epoch
  deadline_epoch="$(herdr_cli_deadline_from_timeout "$timeout")"

  local lock_file=""
  lock_file="$(herdr_manifest_lock "$request_id" 30)" || {
    envelope_fail "team.start" "LOCK_FAILED" "Could not acquire lock for request_id: $request_id" true
    exit 1
  }

  local existing_duplicate
  existing_duplicate="$(herdr_manifest_find_by_request_id "$request_id")"
  if [ -n "$existing_duplicate" ] && [ "$existing_duplicate" != "null" ]; then
    local dup_manifest
    dup_manifest="$(herdr_manifest_read "$existing_duplicate")"
    local dup_status
    dup_status="$(echo "$dup_manifest" | jq -r '.status // "active"')"
    herdr_manifest_unlock "$lock_file"

    if [ "$dup_status" = "unknown_outcome" ]; then
      envelope_unknown_outcome "team.start" "{\"type\":\"team\",\"team_id\":\"$existing_duplicate\"}" "$(echo "$dup_manifest" | jq -c '{team_id: .team_id, members: [.members[] | {role: .role, kind: .kind, activation: .activation, agent_name: .agent_name, pane_id: .pane_id}]}')"
    else
      local dup_members
      dup_members="$(echo "$dup_manifest" | jq -c '{
        team_id: .team_id,
        members: [.members[] | {role: .role, kind: .kind, activation: .activation, agent_name: .agent_name, pane_id: .pane_id}],
        manifest_path: "'"$(herdr_manifest_path "$existing_duplicate")"'"
      }')"
      envelope_already_applied "team.start" "{\"type\":\"team\",\"team_id\":\"$existing_duplicate\"}" "$dup_members"
    fi
    exit 0
  fi

  local current_pane workspace_id
  current_pane="$(herdr_get_current_pane)"
  workspace_id="$(echo "$current_pane" | jq -r '.result.pane.workspace_id // ""')"

  if [ -z "$workspace_id" ] || [ "$workspace_id" = "null" ]; then
    herdr_manifest_unlock "$lock_file"
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
    herdr_manifest_unlock "$lock_file"
    envelope_fail "team.start" "CONFIG_ERROR" "No valid team members found in config" false
    exit 1
  fi

  if ! herdr_config_validate_members "$config_json"; then
    herdr_manifest_unlock "$lock_file"
    envelope_fail "team.start" "CONFIG_ERROR" "Config validation failed (see stderr)" false
    exit 1
  fi

  local team_id
  team_id="$(herdr_team_generate_id)"

  local team_short_id="${team_id: -8}"

  local prompt_snapshots
  prompt_snapshots="$(herdr_config_snapshot_prompts "$config_json")"

  local deferred_roles=""
  local members_json
  members_json="$(echo "$config_json" | jq -c --arg kind "$kind" --arg team_sid "$team_short_id" '
    .members | [.[] | {
      role: .role,
      kind: (.kind // $kind),
      activation: (.activation // (if .role == "impl" then "immediate" else "deferred" end)),
      prompt_file: (.prompt_file // null),
      agent_name: ((.kind // $kind) + "-" + .role + "-" + $team_sid),
      pane_display_name: (.role + " [" + (.kind // $kind) + "]")
    }]
  ')"

  local layout_dir="right"
  local pane_width
  pane_width="$(echo "$current_pane" | jq -r '.result.pane.cols // 0')"
  if [ "$pane_width" -lt 120 ] 2>/dev/null || [ "$pane_width" = "0" ]; then
    layout_dir="down"
  fi

  local created_panes=""
  local created_agents=""
  local count
  count="$(echo "$members_json" | jq -r 'length')"
  local i
  for i in $(seq 0 $((count - 1))); do
    local member role agent_name pane_display_name activation member_kind
    member="$(echo "$members_json" | jq -c ".[$i]")"
    role="$(echo "$member" | jq -r '.role')"
    agent_name="$(echo "$member" | jq -r '.agent_name')"
    pane_display_name="$(echo "$member" | jq -r '.pane_display_name')"
    activation="$(echo "$member" | jq -r '.activation')"
    member_kind="$(echo "$member" | jq -r '.kind')"

    if herdr_cli_deadline_expired "$deadline_epoch"; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      herdr_manifest_unlock "$lock_file"
      envelope_fail "team.start" "TIMEOUT" "Start deadline expired before creating pane for role '$role'" false
      exit 1
    fi

    local split_result pane_id
    split_result="$(herdr_pane_split "$layout_dir")"
    pane_id="$(echo "$split_result" | jq -r '.result.pane.pane_id // ""')"

    if [ -z "$pane_id" ] || [ "$pane_id" = "null" ]; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      herdr_manifest_unlock "$lock_file"
      envelope_fail "team.start" "PANEL_CREATE_FAILED" "Failed to split pane for role '$role'" false
      exit 1
    fi

    created_panes="${created_panes}${pane_id}\n"

    herdr_agent_ready_wait "$pane_id" "$deadline_epoch" || true

    if herdr_cli_deadline_expired "$deadline_epoch"; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      herdr_manifest_unlock "$lock_file"
      envelope_fail "team.start" "TIMEOUT" "Start deadline expired after pane create for role '$role'" false
      exit 1
    fi

    local agent_status
    agent_status="$(herdr_cli_safe_call herdr pane get "$pane_id" | jq -r '.result.pane.agent_status // "unknown"')"

    local agent_result
    if [ "$agent_status" = "unknown" ]; then
      agent_result="$(herdr_agent_start "$agent_name" "$member_kind" "$pane_id")"
    else
      agent_result="$(herdr_agent_rename "$pane_id" "$agent_name")"
    fi

    if ! herdr_cli_result_ok "$agent_result"; then
      if [ "$keep_on_failure" != "true" ]; then
        herdr_rollback_panes "$created_panes"
      fi
      herdr_manifest_unlock "$lock_file"
      envelope_fail "team.start" "AGENT_START_FAILED" "Failed to start agent for role '$role'" false
      exit 1
    fi

    created_agents="${created_agents}${agent_name}\n"

    herdr_agent_label "$pane_id" "$pane_display_name"

    if [ "$activation" = "immediate" ]; then
      local role_prompt
      role_prompt="$(echo "$prompt_snapshots" | jq -r --arg role "$role" '.[$role] // ""')"
      local prompt_text="$role_prompt"
      if [ -n "$kickoff_context" ] && [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
        prompt_text="${prompt_text}

## Kickoff Context

$(echo "$kickoff_context" | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")')"
      fi

      local remaining_timeout
      remaining_timeout="$(herdr_cli_timeout_remaining "$deadline_epoch")"

      local prompt_result prompt_status
      prompt_result="$(herdr_agent_prompt "$agent_name" "$prompt_text" "$remaining_timeout")"
      prompt_status="$(herdr_cli_outcome "$prompt_result")"

      if [ "$prompt_status" != "ok" ]; then
        if [ "$prompt_status" = "failed" ]; then
          if [ "$keep_on_failure" != "true" ]; then
            herdr_rollback_panes "$created_panes"
          fi
          herdr_manifest_unlock "$lock_file"
          envelope_fail "team.start" "PROMPT_FAILED" "Failed to send kickoff prompt to $role ($agent_name)" false
          exit 1
        fi

        local unknown_manifest
        unknown_manifest="$(jq -nc \
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
            status: "unknown_outcome",
            deferred: [],
            prompt_history: {}
          }')"
        herdr_manifest_write "$team_id" "$unknown_manifest"
        herdr_manifest_unlock "$lock_file"
        envelope_unknown_outcome "team.start" "{\"type\":\"team\",\"team_id\":\"$team_id\"}" "$(jq -nc --arg role "$role" '{failed_role: $role, team_id: "'"$team_id"'"}')"
        exit 0
      fi
    else
      deferred_roles="${deferred_roles}${role}\n"
    fi

    members_json="$(echo "$members_json" | jq -c --arg i "$i" --arg pane_id "$pane_id" '
      .[$i|tonumber] |= . + {pane_id: $pane_id}
    ')"
  done

  local deferred_json="[]"
  if [ -n "$deferred_roles" ]; then
    deferred_json="$(echo -e "$deferred_roles" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  fi

  local saved_config_json
  saved_config_json="$(echo "$config_json" | jq -c --argjson prompts "$prompt_snapshots" '{
    schema_version: .schema_version,
    _config_dir: ._config_dir,
    _config_path: ._config_path,
    members: [.members[] | {role: .role, kind: .kind, activation: .activation, prompt_file: .prompt_file}],
    prompt_snapshots: $prompts
  }')"

  local manifest_json
  manifest_json="$(jq -nc \
    --arg team_id "$team_id" \
    --arg workspace_id "$workspace_id" \
    --arg request_id "$request_id" \
    --argjson members "$members_json" \
    --argjson kickoff_context "$(echo "$kickoff_context" | jq -c '. // {}')" \
    --argjson deferred "$deferred_json" \
    --argjson config "$saved_config_json" \
    '{
      schema_version: 1,
      team_id: $team_id,
      workspace_id: $workspace_id,
      request_id: $request_id,
      members: $members,
      config: $config,
      kickoff_context: $kickoff_context,
      created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: "active",
      deferred: $deferred,
      prompt_history: {}
    }')"

  herdr_manifest_write "$team_id" "$manifest_json"
  herdr_manifest_unlock "$lock_file"

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
