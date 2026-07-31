#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"
source "$SCRIPT_DIR/../common/config.sh"
source "$SCRIPT_DIR/../common/herdr_cli.sh"
source "$SCRIPT_DIR/../common/layout_plan.sh"
source "$SCRIPT_DIR/../common/layout_apply.sh"

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
  local deadline_ms="$1" pane_id="$2" agent_name="$3" member_kind="$4"
  local empty_retries=0
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
      agent_pane_busy|busy|starting|initializing) sleep 0.1; continue ;;
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
      empty_retries=$((empty_retries + 1))
      [ "$empty_retries" -le 5 ] || break
      sleep "$(awk -v n="$empty_retries" 'BEGIN { printf "%.1f", 0.1 * 2 ^ (n - 1) }')"
      continue
    fi
    empty_retries=0
    error_code="$(herdr_cli_error_code "$result" | tr '[:upper:]' '[:lower:]')"
    case "$error_code" in
      *agent*pane*busy*|*pane*busy*) sleep 0.1; continue ;;
    esac
    printf '%s\n' "$result"
    return 0
  done
  echo '{}'
}

herdr_team_update_layout() {
  local manifest="$1" apply_result="$2"
  jq -c --argjson apply "$apply_result" '
    .layout.status = (if $apply.status == "ok" then "applied" elif $apply.status == "failed" then "failed" else "unknown_outcome" end)
    | .layout.refs = ($apply.refs // .layout.refs // {})
    | .layout.steps = ($apply.steps // .layout.steps // [])
    | .layout.created_panes = ($apply.created_panes // .layout.created_panes // [])
    | .layout.cleanup_complete = (if $apply.status == "unknown" then false else null end)
    | .layout.failure_reason = (if ($apply.code // "") == "" then .layout.failure_reason else $apply.code end)
    | .members = [.members[] as $member |
        ($apply.refs // {}) as $refs
        | if ($refs[($member.logical_ref // "")] // "") != "" then
            $member | .pane_id = $refs[$member.logical_ref] | .status = "pane-created"
          else $member end]
  ' <<< "$manifest"
}

herdr_team_rollback_created_panes() {
  local team_id="$1" manifest="$2"
  local pane_ids count index close_result close_outcome status
  pane_ids="$(jq -c '[.layout.created_panes[]?] | reverse | reduce .[] as $pane ([]; if index($pane) then . else . + [$pane] end)' <<< "$manifest")"
  count="$(jq -r 'length' <<< "$pane_ids")"
  local cleanup_complete=true
  for ((index = 0; index < count; index++)); do
    local pane_id
    pane_id="$(jq -r --argjson i "$index" '.[$i]' <<< "$pane_ids")"
    close_result="$(herdr_cli_safe_call_timeout 2000 herdr pane close "$pane_id")"
    close_outcome="$(herdr_cli_outcome "$close_result")"
    case "$close_outcome" in
      ok) status="closed" ;;
      failed) status="close-failed"; cleanup_complete=false ;;
      *) status="close-unknown"; cleanup_complete=false ;;
    esac
    manifest="$(jq -c --arg pane_id "$pane_id" --arg status "$status" \
      '.layout.cleanup_steps = ((.layout.cleanup_steps // []) + [{pane_id:$pane_id,status:$status}])' <<< "$manifest")"
  done
  if [ "$cleanup_complete" = true ]; then
    manifest="$(jq -c '.status = "rollback-complete" | .start_outcome = "failed" | .layout.cleanup_complete = true' <<< "$manifest")"
  else
    manifest="$(jq -c '.status = "rollback-incomplete" | .start_outcome = "failed" | .layout.cleanup_complete = false' <<< "$manifest")"
  fi
  printf '%s\n' "$manifest"
}

herdr_team_known_failure() {
  local team_id="$1" manifest="$2" keep_on_failure="$3" code="$4" message="$5" role="${6:-}"
  local cleanup_complete=false
  manifest="$(jq -c --arg code "$code" '.status = "start-failed" | .start_outcome = "failed" | .layout.failure_reason = $code' <<< "$manifest")"
  if [ "$keep_on_failure" = "true" ]; then
    herdr_manifest_write "$team_id" "$manifest"
  else
    manifest="$(herdr_team_rollback_created_panes "$team_id" "$manifest")"
    if [ "$(jq -r '.status' <<< "$manifest")" = "rollback-complete" ]; then
      cleanup_complete=true
      herdr_manifest_delete "$team_id"
    else
      herdr_manifest_write "$team_id" "$manifest"
    fi
  fi
  local data
  data="$(jq -nc --arg team_id "$team_id" --arg role "$role" --arg code "$code" \
    --argjson cleanup_complete "$cleanup_complete" \
    --argjson members "$(jq -c '[.members[] | {role,pane_id,status}]' <<< "$manifest")" \
    '{team_id:$team_id,failed_role:(if $role == "" then null else $role end),failure_code:$code,cleanup_complete:$cleanup_complete,members:$members}')"
  herdr_team_release_lock
  envelope_fail "team.start" "$code" "$message" false \
    "$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')" "$data"
  return 1
}

herdr_team_unknown() {
  local team_id="$1" manifest="$2" role="${3:-}" phase="${4:-unknown}"
  manifest="$(jq -c --arg role "$role" --arg phase "$phase" \
    '.status = "unknown_outcome" | .start_outcome = "unknown" | .unknown_phase = $phase | .unknown_role = (if $role == "" then null else $role end) | .layout.cleanup_complete = false' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"
  local data
  data="$(jq -nc --arg team_id "$team_id" --arg role "$role" --arg phase "$phase" \
    --argjson members "$(jq -c '[.members[] | {role,pane_id,status}]' <<< "$manifest")" \
    '{team_id:$team_id,role:(if $role == "" then null else $role end),phase:$phase,cleanup_complete:false,members:$members}')"
  herdr_team_release_lock
  envelope_unknown_outcome "team.start" \
    "$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')" "$data"
}

herdr_team_plan_failure() {
  local team_id="$1" manifest="$2" plan="$3"
  manifest="$(jq -c --argjson plan "$plan" \
    '.status = "start-failed" | .start_outcome = "failed" | .layout.status = "failed" | .layout.plan = $plan | .layout.failure_reason = "LAYOUT_NOT_FEASIBLE" | .layout.cleanup_complete = true' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"
  local data
  data="$(jq -nc --arg team_id "$team_id" --argjson plan "$plan" '{team_id:$team_id,cleanup_complete:true,plan:$plan}')"
  herdr_team_release_lock
  envelope_fail "team.start" "LAYOUT_NOT_FEASIBLE" "Grid layout is not feasible for the current pane geometry" false \
    "$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')" "$data"
  return 1
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
    envelope_fail "team.start" "LOCK_FAILED" "Could not acquire lock for request_id: $request_id" true
    return 1
  fi

  local root_pane_id="${HERDR_PANE_ID:-}" workspace_id="${HERDR_WORKSPACE_ID:-}" tab_id="${HERDR_TAB_ID:-}"
  if [ "${HERDR_ENV:-0}" != "1" ] || [ -z "$root_pane_id" ] || [ -z "$workspace_id" ] || [ -z "$tab_id" ]; then
    herdr_team_release_lock
    envelope_fail "team.start" "HERDR_CAPABILITY_MISSING" "HERDR_ENV and HERDR_PANE_ID/HERDR_TAB_ID/HERDR_WORKSPACE_ID are required" false
    return 1
  fi

  local existing_duplicate
  existing_duplicate="$(herdr_manifest_find_by_request_id "$request_id" "$workspace_id")"
  if [ -n "$existing_duplicate" ]; then
    local duplicate dup_status dup_data
    duplicate="$(herdr_manifest_read "$existing_duplicate")"
    dup_status="$(jq -r '.status // "active"' <<< "$duplicate")"
    dup_data="$(jq -c '{team_id,start_outcome:(.start_outcome // null),members:[.members[] | {role,kind,activation,agent_name,pane_id,status}],layout:(.layout // null)}' <<< "$duplicate")"
    herdr_team_release_lock
    case "$dup_status" in
      active|stopped|start-failed) envelope_already_applied "team.start" "$(jq -nc --arg team_id "$existing_duplicate" '{type:"team",team_id:$team_id}')" "$dup_data" ;;
      *) envelope_unknown_outcome "team.start" "$(jq -nc --arg team_id "$existing_duplicate" '{type:"team",team_id:$team_id}')" "$dup_data" ;;
    esac
    return 0
  fi

  if ! herdr_cli_require_capabilities "$deadline_ms"; then
    herdr_team_release_lock
    envelope_fail "team.start" "HERDR_CAPABILITY_MISSING" "Herdr 0.7.5+ with pane layout/split capabilities is required" false
    return 1
  fi

  if [ -z "$origin_kind" ] || [[ ! "$origin_kind" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    herdr_team_release_lock
    envelope_fail "team.start" "INVALID_ORIGIN_KIND" "origin_kind is required and must be a valid agent kind name" false
    return 1
  fi
  local kind="$origin_kind"
  local config_json
  if ! config_json="$(herdr_config_resolve "$config_path" "$kind" 2>/dev/null)" || ! herdr_config_validate_members "$config_json" 2>/dev/null; then
    herdr_team_release_lock
    envelope_fail "team.start" "CONFIG_ERROR" "Config resolution or schema validation failed" false
    return 1
  fi
  local prompt_snapshots
  if ! prompt_snapshots="$(herdr_config_snapshot_prompts "$config_json" 2>/dev/null)"; then
    herdr_team_release_lock
    envelope_fail "team.start" "CONFIG_ERROR" "Could not snapshot all role prompts" false
    return 1
  fi

  local snapshot snapshot_status root_pane
  snapshot="$(herdr_layout_snapshot "$deadline_ms" "$workspace_id" "$root_pane_id")"
  snapshot_status="$(jq -r '.status' <<< "$snapshot")"
  if [ "$snapshot_status" != "ok" ]; then
    herdr_team_release_lock
    if [ "$snapshot_status" = "unknown" ]; then
      envelope_unknown_outcome "team.start" '{"type":"team"}' '{"phase":"layout.snapshot"}'
    else
      envelope_fail "team.start" "HERDR_ERROR" "Cannot determine current pane layout" false
    fi
    return 1
  fi
  root_pane="$(jq -c --arg pane_id "$root_pane_id" '.panes[] | select(.pane_id == $pane_id)' <<< "$snapshot")"
  if [ -z "$root_pane" ]; then
    herdr_team_release_lock
    envelope_fail "team.start" "HERDR_ERROR" "Current Herdr pane is not present in pane layout" false
    return 1
  fi

  local member_count max_cols target_cols target_rows target_x target_y plan team_id team_short_id members_json deferred_json saved_config_json manifest
  member_count="$(jq -r '.members | length' <<< "$config_json")"
  max_cols="$(jq -r '.layout.max_cols' <<< "$config_json")"
  target_cols="$(jq -r '.cols' <<< "$root_pane")"
  target_rows="$(jq -r '.rows' <<< "$root_pane")"
  target_x="$(jq -r '.x // 0' <<< "$root_pane")"
  target_y="$(jq -r '.y // 0' <<< "$root_pane")"
  plan="$(herdr_layout_plan_generate "$(jq -nc --argjson member_count "$member_count" --argjson max_cols "$max_cols" --argjson target_cols "$target_cols" --argjson target_rows "$target_rows" --argjson target_x "$target_x" --argjson target_y "$target_y" '{member_count:$member_count,max_cols:$max_cols,target_cols:$target_cols,target_rows:$target_rows,target_x:$target_x,target_y:$target_y}')")"

  team_id="$(herdr_team_generate_id)"
  team_short_id="${team_id: -8}"
  # Bind members to deterministic logical refs without using pane IDs.
  members_json="$(jq -c --arg kind "$kind" --arg team_sid "$team_short_id" '
    [.members[] | {role,kind:(.kind // $kind),activation:(.activation // (if .role == "impl" then "immediate" else "deferred" end)),prompt_file:(.prompt_file // null),agent_name:((.kind // $kind) + "-" + .role + "-" + $team_sid),pane_display_name:(.role + " [" + (.kind // $kind) + "]"),pane_id:null,status:"pending"}]
    | to_entries
    | map(.value + {logical_ref:("member-" + (.key|tostring))})
  ' <<< "$config_json")"
  deferred_json="$(jq -c '[.[] | select(.activation == "deferred") | .role]' <<< "$members_json")"
  saved_config_json="$(jq -c --argjson prompts "$prompt_snapshots" '{schema_version,_config_dir,_config_path,layout,members:[.members[] | {role,kind,activation,prompt_file}],prompt_snapshots:$prompts}' <<< "$config_json")"
  manifest="$(jq -nc --arg team_id "$team_id" --arg workspace_id "$workspace_id" --arg tab_id "$tab_id" --arg request_id "$request_id" \
    --argjson members "$members_json" --argjson kickoff_context "$kickoff_context" --argjson deferred "$deferred_json" \
    --argjson config "$saved_config_json" --argjson plan "$plan" --arg root_pane_id "$root_pane_id" \
    '{schema_version:2,team_id:$team_id,workspace_id:$workspace_id,tab_id:$tab_id,request_id:$request_id,members:$members,config:$config,kickoff_context:$kickoff_context,created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),status:"starting",start_outcome:"in_flight",deferred:$deferred,prompt_history:{},layout:{status:(if $plan.status == "ok" then "planned" else "failed" end),plan:$plan,refs:{orch:$root_pane_id},steps:[],created_panes:[],failure_reason:(if $plan.status == "ok" then null else "LAYOUT_NOT_FEASIBLE" end),cleanup_complete:(if $plan.status == "ok" then null else true end)}}')"

  if [ "$(jq -r '.status' <<< "$plan")" != "ok" ]; then
    herdr_team_plan_failure "$team_id" "$manifest" "$plan"
    return $?
  fi
  herdr_manifest_write "$team_id" "$manifest"

  local apply_result apply_status
  apply_result="$(herdr_layout_apply "$plan" "$root_pane_id" "$workspace_id" "$deadline_ms" "$team_id")"
  manifest="$(herdr_team_update_layout "$manifest" "$apply_result")"
  apply_status="$(jq -r '.status' <<< "$apply_result")"
  if [ "$apply_status" = "failed" ]; then
    herdr_manifest_write "$team_id" "$manifest"
    herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" "$(jq -r '.code // "PANE_CREATE_FAILED"' <<< "$apply_result")" "Grid pane split failed" ""
    return $?
  fi
  if [ "$apply_status" = "unknown" ]; then
    herdr_team_unknown "$team_id" "$manifest" "" "layout.apply"
    return 0
  fi
  herdr_manifest_write "$team_id" "$manifest"

  local count i
  count="$(jq -r '.members | length' <<< "$manifest")"
  for ((i = 0; i < count; i++)); do
    local role agent_name pane_display_name activation member_kind pane_id
    role="$(jq -r ".members[$i].role" <<< "$manifest")"
    agent_name="$(jq -r ".members[$i].agent_name" <<< "$manifest")"
    pane_display_name="$(jq -r ".members[$i].pane_display_name" <<< "$manifest")"
    activation="$(jq -r ".members[$i].activation" <<< "$manifest")"
    member_kind="$(jq -r ".members[$i].kind" <<< "$manifest")"
    pane_id="$(jq -r ".members[$i].pane_id // empty" <<< "$manifest")"
    if [ -z "$pane_id" ]; then
      herdr_team_unknown "$team_id" "$manifest" "$role" "member.bind"
      return 0
    fi
    if herdr_cli_deadline_expired "$deadline_ms"; then
      herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" TIMEOUT "Start deadline expired before agent start" "$role"
      return $?
    fi
    manifest="$(jq -c --argjson i "$i" '.members[$i].status = "agent-starting"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"
    local agent_result agent_outcome
    agent_result="$(herdr_agent_prepare_before_deadline "$deadline_ms" "$pane_id" "$agent_name" "$member_kind")"
    agent_outcome="$(herdr_cli_outcome "$agent_result")"
    if [ "$agent_outcome" = "failed" ]; then
      herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" AGENT_START_FAILED "Failed to start or rename agent for role '$role'" "$role"
      return $?
    fi
    if [ "$agent_outcome" = "unknown" ]; then
      manifest="$(jq -c --argjson i "$i" '.members[$i].status = "agent-unknown"' <<< "$manifest")"
      herdr_team_unknown "$team_id" "$manifest" "$role" "agent.start"
      return 0
    fi
    herdr_cli_safe_call_timeout "$(herdr_cli_timeout_remaining "$deadline_ms")" herdr pane rename "$pane_id" "$pane_display_name" >/dev/null || true
    manifest="$(jq -c --argjson i "$i" '.members[$i].status = "active"' <<< "$manifest")"
    herdr_manifest_write "$team_id" "$manifest"

    if [ "$activation" = "immediate" ]; then
      local role_prompt prompt_text
      role_prompt="$(jq -r --arg role "$role" '.[$role] // ""' <<< "$prompt_snapshots")"
      prompt_text="$role_prompt"
      if [ "$kickoff_context" != "{}" ] && [ "$kickoff_context" != "null" ]; then
        prompt_text="${prompt_text}

## Kickoff Context

$(jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")' <<< "$kickoff_context")"
      fi
      manifest="$(jq -c --arg role "$role" '.start_prompt = {role:$role,status:"in_flight"}' <<< "$manifest")"
      herdr_manifest_write "$team_id" "$manifest"
      local remaining kickoff_timeout prompt_result prompt_outcome
      remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
      if [ "$remaining" -le 0 ]; then
        prompt_result='{}'
      else
        kickoff_timeout="$remaining"
        [ "$kickoff_timeout" -ge 10000 ] || kickoff_timeout=10000
        prompt_result="$(herdr_cli_safe_call_timeout "$kickoff_timeout" herdr agent prompt "$agent_name" "$prompt_text" --wait --timeout "$kickoff_timeout")"
      fi
      prompt_outcome="$(herdr_cli_outcome "$prompt_result")"
      if [ "$prompt_outcome" = "failed" ]; then
        local prompt_error
        prompt_error="$(herdr_cli_error_code "$prompt_result" | tr '[:upper:]' '[:lower:]')"
        if [[ "$prompt_error" == *timeout* ]] || [[ "$prompt_error" == *timed*out* ]] || [[ "$prompt_error" == *deadline* ]]; then
          manifest="$(jq -c '.start_prompt.status = "unknown"' <<< "$manifest")"
          herdr_manifest_write "$team_id" "$manifest"
        else
          manifest="$(jq -c '.start_prompt.status = "failed"' <<< "$manifest")"
          herdr_manifest_write "$team_id" "$manifest"
          herdr_team_known_failure "$team_id" "$manifest" "$keep_on_failure" PROMPT_FAILED "Failed to send kickoff prompt to role '$role'" "$role"
          return $?
        fi
      elif [ "$prompt_outcome" = "unknown" ]; then
        manifest="$(jq -c '.start_prompt.status = "unknown"' <<< "$manifest")"
        herdr_manifest_write "$team_id" "$manifest"
      else
        manifest="$(jq -c '.start_prompt.status = "succeeded"' <<< "$manifest")"
        herdr_manifest_write "$team_id" "$manifest"
      fi
    fi
  done

  manifest="$(jq -c '.status = "active" | .start_outcome = "succeeded" | .layout.status = "applied"' <<< "$manifest")"
  herdr_manifest_write "$team_id" "$manifest"
  local summary
  summary="$(jq -c --arg manifest_path "$(herdr_manifest_path "$team_id")" '{team_id,members:[.members[] | {role,kind,activation,agent_name,pane_id,status}],manifest_path,start_prompt_status:(.start_prompt.status // null),layout:{status:.layout.status,resolved_cols:.layout.plan.resolved_cols,resolved_rows:.layout.plan.resolved_rows}}' <<< "$manifest")"
  herdr_team_release_lock
  envelope_ok "team.start" "$(jq -nc --arg team_id "$team_id" '{type:"team",team_id:$team_id}')" "$summary"
}

main "$@"
