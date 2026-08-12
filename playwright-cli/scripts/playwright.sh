#!/usr/bin/env bash
set -euo pipefail

# playwright.sh: the single public dispatcher for the Playwright CLI harness.
# Never evaluates strings as commands; builds argv arrays from validated input.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(dirname "$SCRIPT_DIR")"
COMMON_DIR="$SCRIPT_DIR/common"
ACTIONS_DIR="$SCRIPT_DIR/actions"
ACTIONS_JSON="${PW_ACTIONS_JSON:-$PW_ROOT/actions.json}"
PW_INPUT_TEMP=""
PW_SENSITIVE_TEMP=""

source "$COMMON_DIR/envelope.sh"
source "$COMMON_DIR/validate.sh"
source "$COMMON_DIR/runtime.sh"
source "$COMMON_DIR/state.sh"
source "$COMMON_DIR/artifact.sh"
source "$COMMON_DIR/dispatch.sh"

usage() {
  cat >&2 <<'EOF'
Usage: playwright.sh <action-name> [json-input-file]

Provide JSON input via a file argument or stdin.
EOF
  exit 2
}

pw_check_dependencies() {
  local missing=()
  local dep
  for dep in jq sha256sum flock sync setsid realpath date base64 ps; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    pw_envelope_fail "preflight" "MISSING_DEPENDENCY" "missing required commands: ${missing[*]}" false
    exit 1
  fi
}

pw_cleanup_runtime_temps() {
  pw_terminate_active_spawn
  case "${PW_INPUT_TEMP:-}" in
    /tmp/pwcli-input-*) rm -f -- "$PW_INPUT_TEMP" ;;
  esac
  case "${PW_SENSITIVE_TEMP:-}" in
    /tmp/pwcli-sensitive-*) rm -f -- "$PW_SENSITIVE_TEMP" ;;
  esac
  PW_INPUT_TEMP=""
  PW_SENSITIVE_TEMP=""
  pw_cleanup_spawn_files
}

pw_handle_runtime_signal() {
  local signal="$1" exit_code
  trap - HUP INT TERM
  pw_cleanup_runtime_temps
  case "$signal" in
    HUP) exit_code=129 ;;
    INT) exit_code=130 ;;
    TERM) exit_code=143 ;;
  esac
  exit "$exit_code"
}

pw_permission_level() {
  case "$1" in
    read) echo 0 ;;
    write) echo 1 ;;
    sensitive-write) echo 2 ;;
    *) echo 0 ;;
  esac
}

pw_set_runtime_context() {
  local session="$1"
  local session_version="null"
  if [ -n "$session" ] && [ -n "${PW_SESSIONS:-}" ]; then
    session_version="$(jq -c --arg name "$session" \
      '[.[] | select(.name == $name)] | if length > 0 then .[0].version else null end' \
      <<< "$PW_SESSIONS")"
  fi
  local allowlist
  allowlist="$(pw_runtime_allowlist)"
  PW_RUNTIME_ENV="$(jq -cn \
    --arg cli "${PW_CLI_PACKAGE_VERSION:-null}" \
    --argjson embedded "$(jq -c '.embedded_playwright_version' <<< "$allowlist")" \
    --argjson session_version "$session_version" \
    '{cli_package_version: $cli, embedded_playwright_version: $embedded, session_version: $session_version}')"
}

pw_emit_failure() {
  local phase="$1" code="$2" message="$3" session="$4" request_id="$5" action="$6" permission="$7"
  local stderr_excerpt="${8:-null}"
  local exit_code="${9:-null}"
  pw_envelope_fail "$phase" "$code" "$message" false "$exit_code" null "$stderr_excerpt" null "[]" "${PW_RUNTIME_ENV:-null}"
}

pw_emit_already_applied() {
  local data="$1"
  pw_envelope_already_applied "$data" "[]" "${PW_RUNTIME_ENV:-null}"
}
# Resolve session/request_id fields from validated input.
pw_input_session() {
  local input="$1"
  jq -r '.session // empty' <<< "$input"
}

pw_input_request_id() {
  local input="$1"
  jq -r '.request_id // empty' <<< "$input"
}

# Spawn the CLI and classify the result for the current action.
pw_run_cli_action() {
  local action_def="$1" input="$2" session="$3" runtime_fields="$4"
  local argv timeout_seconds
  argv="$(pw_build_argv_json "$action_def" "$input" "$session" "$runtime_fields" "$PW_CLI_PATH")"
  timeout_seconds="${PWCLI_TIMEOUT_SECONDS:-$(jq -r '.timeout_seconds // 60' <<< "$action_def")}"
  timeout_seconds="$(( timeout_seconds ))"
  # Decode each JSON argv item independently. This preserves embedded
  # whitespace/newlines without ever evaluating a command string.
  local encoded
  local -a cli_argv=()
  while IFS= read -r encoded; do
    cli_argv+=("$(printf '%s' "$encoded" | base64 -d)")
  done < <(jq -r '.[] | @base64' <<< "$argv")
  pw_spawn_cli "$timeout_seconds" "${cli_argv[@]}"
  pw_collect_spawn_output
}

pw_terminal_journal() {
  local session="$1" journal="$2" status="$3"
  local state
  case "$status" in
    ok) state="ok" ;;
    failed) state="failed" ;;
    unknown_outcome) state="unknown" ;;
  esac
  pw_journal_write "$session" "$(pw_journal_set_state "$session" "$journal" "$state" "null" "null")"
  if [ "$state" = "unknown" ]; then
    local owner
    owner="$(pw_owner_read "$session")"
    if [ -n "$owner" ]; then
      local generation
      generation="$(jq -r '.current_generation' <<< "$owner")"
      pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "quarantined" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
    fi
  fi
}

# Envelope emission with exit code derived from the status.
pw_emit_envelope() {
  local envelope="$1"
  printf '%s\n' "$envelope"
  local status
  status="$(jq -r '.status' <<< "$envelope")"
  if [ "$status" = "ok" ] || [ "$status" = "already_applied" ]; then
    exit 0
  fi
  exit 1
}

pw_run_internal_action() {
  local action_name="$1" input="$2"
  local action_file="$ACTIONS_DIR/${action_name}.sh"
  if [ ! -f "$action_file" ]; then
    pw_emit_failure "dispatch" "NOT_IMPLEMENTED" "Action not yet implemented: $action_name" \
      "$(pw_input_session "$input")" "$(pw_input_request_id "$input")" "$action_name" "$(jq -r '.permission' <<< "$PW_ACTION_DEF")"
    exit 1
  fi
  chmod +x "$action_file"
  "$action_file" "$input"
  local rc=$?
  exit "$rc"
}

# Main CLI-action flow: lock, state, gates, preflight, journal, spawn, terminal.
pw_run_cli_action_flow() {
  local action_def="$1" input="$2" action_name="$3" permission="$4" is_write="$5"
  local session request_id
  session="$(pw_input_session "$input")"
  request_id="$(pw_input_request_id "$input")"
  local adapter_kind precondition_codes failure_semantics
  adapter_kind="$(jq -r '.output_adapter.kind' <<< "$action_def")"
  precondition_codes="$(jq -c '.precondition_error_codes // []' <<< "$action_def")"
  failure_semantics="$(jq -r '.failure_semantics // "uncertain"' <<< "$action_def")"

  local session_required
  session_required="$(jq -r '.session' <<< "$action_def")"

  if [ "$session_required" = "forbidden" ]; then
    # sessionless: browser.list
    pw_preflight || {
      pw_emit_failure "preflight" "$PW_PREFLIGHT_CODE" "$PW_PREFLIGHT_MESSAGE" "null" "$request_id" "$action_name" "$permission"
      exit 1
    }
    pw_set_runtime_context ""
    pw_run_cli_action "$action_def" "$input" "" '{}'
    pw_classify_result "$is_write" "$adapter_kind" "$precondition_codes" "$failure_semantics" ""
    if [ "$PW_RESULT_STATUS" = "ok" ]; then
      pw_emit_envelope "$(pw_envelope_ok "$PW_RESULT_DATA" "$PW_RESULT_ARTIFACTS" "${PW_RUNTIME_ENV:-null}")"
      exit 0
    fi
    pw_emit_failure "$PW_RESULT_PHASE" "$PW_RESULT_CODE" "$PW_RESULT_MESSAGE" "null" "$request_id" "$action_name" "$permission" "null" "$PW_SPAWN_RC"
    exit 1
  fi

  # ---- session-required actions ----
  if ! pw_acquire_lock "$session"; then
    pw_emit_failure "lock" "LOCK_BUSY" "another process holds the session lock" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  fi
  trap 'pw_release_lock; pw_cleanup_runtime_temps' EXIT

  if ! pw_state_validate "$session"; then
    local code message
    code="$(jq -r '.code' <<< "$PW_STATE_ERROR")"
    message="$(jq -r '.message' <<< "$PW_STATE_ERROR")"
    pw_emit_failure "recovery" "$code" "$message" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  fi
  if ! pw_startup_recovery "$session"; then
    local code message
    code="$(jq -r '.code' <<< "$PW_STATE_ERROR")"
    message="$(jq -r '.message' <<< "$PW_STATE_ERROR")"
    pw_emit_failure "recovery" "$code" "$message" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  fi

  local owner owner_phase
  owner="$(pw_owner_read "$session")"
  owner_phase=""
  if [ -n "$owner" ]; then
    owner_phase="$(jq -r '.phase' <<< "$owner")"
  fi

  # Ownerless sessions are rejected for every action except browser.open,
  # which may create ownership on a fresh name.
  if [ -z "$owner" ] && [ "$action_name" != "browser.open" ]; then
    pw_emit_failure "preflight" "SESSION_NOT_OWNED" "session '$session' has no harness ownership marker" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  fi

  # journal gate for write actions (before the quarantine gate so that a
  # replayed unknown request answers REQUEST_OUTCOME_UNKNOWN, not a generic
  # quarantine error)
  local digest=""
  if [ "$is_write" = "true" ]; then
    digest="$(pw_input_digest "$action_name" "$input")"
    pw_journal_gate "$session" "$request_id" "$action_name" "$permission" "$digest"
    case "$PW_JOURNAL_GATE_RESULT" in
      already)
        pw_set_runtime_context ""
        pw_emit_envelope "$(pw_envelope_already_applied "$PW_JOURNAL_GATE_DATA" "[]" "${PW_RUNTIME_ENV:-null}")"
        ;;
      conflict)
        pw_emit_failure "dispatch" "$PW_JOURNAL_GATE_ERROR" "request id '$request_id' was already used with a different binding" "$session" "$request_id" "$action_name" "$permission"
        exit 1
        ;;
      unknown)
        pw_emit_failure "recovery" "$PW_JOURNAL_GATE_ERROR" "the outcome of this request is unknown; recovery.observe is required" "$session" "$request_id" "$action_name" "$permission"
        exit 1
        ;;
      retired)
        pw_emit_failure "dispatch" "$PW_JOURNAL_GATE_ERROR" "this request id is retired; use a new request id" "$session" "$request_id" "$action_name" "$permission"
        exit 1
        ;;
      corrupt)
        pw_emit_failure "recovery" "$PW_JOURNAL_GATE_ERROR" "request journal path contains symlinks" "$session" "$request_id" "$action_name" "$permission"
        exit 1
        ;;
      ok)
        :
        ;;
    esac
  fi

  # unknown-outcome gate: writes and most reads stop; recovery read allowed
  if [ "$owner_phase" = "quarantined" ] && [ "$action_name" != "page.snapshot" ]; then
    pw_emit_failure "recovery" "SESSION_QUARANTINED" "session is quarantined; only recovery.observe and page.snapshot are allowed" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  fi

  # preflight (runtime allowlist + session list)
  pw_preflight || {
    pw_emit_failure "preflight" "$PW_PREFLIGHT_CODE" "$PW_PREFLIGHT_MESSAGE" "$session" "$request_id" "$action_name" "$permission"
    exit 1
  }
  pw_set_runtime_context "$session"

  # live/compatible gates
  local live=0
  if pw_session_is_live "$session"; then
    live=1
  fi
  case "$action_name" in
    browser.open)
      if [ "$live" = "1" ]; then
        if [ -z "$owner" ]; then
          pw_emit_failure "preflight" "SESSION_NOT_OWNED" "a live session named '$session' exists but is not harness-owned" "$session" "$request_id" "$action_name" "$permission"
          exit 1
        fi
        pw_emit_failure "preflight" "SESSION_ALREADY_LIVE" "a live session named '$session' already exists" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
      if [ "$owner_phase" = "active" ]; then
        pw_emit_failure "preflight" "SESSION_NOT_LIVE" "owned session '$session' is not live; close it before reopening" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
      ;;
    browser.close)
      if [ "$live" = "0" ]; then
        if [ "$owner_phase" = "closed" ] || [ "$owner_phase" = "active" ]; then
          if [ "$is_write" = "true" ]; then
            local close_journal
            close_journal="$(pw_build_journal "$session" "$request_id" "$(jq -r '.current_generation' <<< "$owner")" "$action_name" "$permission" "$(pw_input_digest "$action_name" "$input")" "ok")"
            pw_journal_write "$session" "$close_journal" || true
            pw_owner_write "$session" "$(pw_build_owner "$session" "$(jq -r '.current_generation' <<< "$owner")" "closed" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")" || true
          fi
          pw_set_runtime_context "$session"
          pw_emit_envelope "$(pw_envelope_already_applied "$(jq -nc --arg s "$session" '{reason: "session_already_closed", session: $s}')")"
          exit 0
        fi
        pw_emit_failure "preflight" "SESSION_NOT_LIVE" "session '$session' is not live" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
      ;;
    *)
      if [ "$live" = "0" ]; then
        pw_emit_failure "preflight" "SESSION_NOT_LIVE" "session '$session' is not live" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
      if ! pw_session_compatible "$session"; then
        pw_emit_failure "preflight" "SESSION_INCOMPATIBLE" "live session '$session' is not compatible with the allowlisted runtime" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
      ;;
  esac

  # fresh target verification: ref observation_id must match the latest ledger observation
  local ledger
  ledger="$(pw_ledger_read "$session")"
  if [ -n "$ledger" ]; then
    local ref_observation_id
    ref_observation_id="$(jq -r '.target.observation_id // empty' <<< "$input")"
    if [ -n "$ref_observation_id" ]; then
      local latest_obs
      latest_obs="$(jq -r '.latest_observation_id // ""' <<< "$ledger")"
      if [ "$ref_observation_id" != "$latest_obs" ]; then
        pw_emit_failure "preflight" "STALE_REFERENCE" "target observation_id does not match the latest recorded observation; take a new snapshot first" "$session" "$request_id" "$action_name" "$permission"
        exit 1
      fi
    fi
  fi

  # journal lifecycle and spawn
  local generation=""
  if [ "$action_name" = "browser.open" ]; then
    generation="$(pw_new_uuid)"
  else
    generation="$(jq -r '.current_generation' <<< "$owner")"
  fi

  local journal=""
  if [ "$is_write" = "true" ]; then
    journal="$(pw_build_journal "$session" "$request_id" "$generation" "$action_name" "$permission" "$digest" "prepared")"
    if ! pw_journal_write "$session" "$journal"; then
      pw_emit_failure "dispatch" "STATE_WRITE_FAILED" "failed to persist the prepared journal" "$session" "$request_id" "$action_name" "$permission"
      exit 1
    fi
  fi

  local runtime_fields="{}"
  local screenshot_path=""
  if [ "$adapter_kind" = "screenshot" ]; then
    if ! screenshot_path="$(pw_new_artifact_path "$session" "$request_id" "screenshot" "png")"; then
      if [ "$is_write" = "true" ]; then
        pw_terminal_journal "$session" "$journal" "failed"
      fi
      pw_emit_failure "dispatch" "ARTIFACT_PATH_REJECTED" "artifact path contains symlinks" "$session" "$request_id" "$action_name" "$permission"
      exit 1
    fi
    runtime_fields="$(jq -cn --arg p "$screenshot_path" '{output_path: $p}')"
  fi

  if [ "$action_name" = "browser.open" ]; then
    # durable owner reservation BEFORE dispatch: a failure here never spawns
    if ! pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "opening" "$PWD" "$(pw_default_runtime_id)" "$request_id")"; then
      pw_terminal_journal "$session" "$journal" "failed"
      pw_emit_failure "dispatch" "OWNER_RESERVATION_FAILED" "failed to persist the opening owner reservation" "$session" "$request_id" "$action_name" "$permission"
      exit 1
    fi
  fi

  if [ "$is_write" = "true" ]; then
    if ! pw_journal_write "$session" "$(pw_journal_set_state "$session" "$journal" "dispatched" "null" "null")"; then
      pw_terminal_journal "$session" "$journal" "failed"
      if [ "$action_name" = "browser.open" ]; then
        pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "closed" "$PWD" "$(pw_default_runtime_id)" "$request_id")" || true
      fi
      pw_emit_failure "dispatch" "STATE_WRITE_FAILED" "failed to persist the dispatched journal" "$session" "$request_id" "$action_name" "$permission"
      exit 1
    fi
  fi

  pw_run_cli_action "$action_def" "$input" "$session" "$runtime_fields"
  local sensitive_file stderr_excerpt
  sensitive_file="$(mktemp /tmp/pwcli-sensitive-XXXXXX)"
  PW_SENSITIVE_TEMP="$sensitive_file"
  pw_sensitive_values_file "$action_def" "$input" "$sensitive_file"
  stderr_excerpt="$(pw_stderr_excerpt "$PW_SPAWN_STDERR" "$sensitive_file")"
  rm -f -- "$sensitive_file"
  PW_SENSITIVE_TEMP=""
  pw_classify_result "$is_write" "$adapter_kind" "$precondition_codes" "$failure_semantics" "$session"

  # terminal handling per action
  local terminal_status="$PW_RESULT_STATUS"
  if [ "$adapter_kind" = "close" ] && [ "$PW_RESULT_CODE" = "CLOSE_NOT_OPEN" ] && [ "$PW_SPAWN_RC" = "0" ]; then
    if [ "$owner_phase" = "closed" ]; then
      terminal_status="ok"
      if [ "$is_write" = "true" ]; then
        pw_terminal_journal "$session" "$journal" "ok"
      fi
      pw_emit_envelope "$(pw_envelope_already_applied "$(jq -nc --arg s "$session" '{reason: "session_already_closed", session: $s}')")"
      exit 0
    fi
    pw_emit_failure "execution" "SESSION_NOT_OWNED" "close reported not-open for an unowned session" "$session" "$request_id" "$action_name" "$permission" "$stderr_excerpt" "$PW_SPAWN_RC"
    exit 1
  fi

  if [ "$adapter_kind" = "screenshot" ]; then
    # The CLI-returned path is contractually ignored for filesystem access:
    # only the runtime-generated path is ever stat'd, hashed, or removed,
    # and it must be a non-symlink regular file inside the canonical
    # artifact root.
    if [ "$terminal_status" = "ok" ]; then
      if ! pw_artifact_path_symlink_free "$screenshot_path"; then
        terminal_status="unknown_outcome"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="ARTIFACT_PATH_MISMATCH"
        PW_RESULT_MESSAGE="screenshot artifact is not a canonical non-symlink regular file in the artifact root"
        pw_artifact_remove "$screenshot_path"
      elif [ ! -f "$screenshot_path" ]; then
        terminal_status="unknown_outcome"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="ARTIFACT_MISSING"
        PW_RESULT_MESSAGE="playwright-cli reported success but no screenshot artifact exists"
        pw_artifact_remove "$screenshot_path"
      elif ! chmod 0600 -- "$screenshot_path" || [ "$(stat -c '%a' "$screenshot_path" 2>/dev/null || true)" != "600" ]; then
        terminal_status="unknown_outcome"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="ARTIFACT_MODE_INVALID"
        PW_RESULT_MESSAGE="screenshot artifact mode could not be restricted to 0600"
        pw_artifact_remove "$screenshot_path"
      else
        local size_limit size_bytes
        size_limit="$(jq -r '.limits.screenshot_bytes' "$ACTIONS_JSON")"
        size_bytes="$(stat -c%s "$screenshot_path")"
        if [ "$size_bytes" -gt "$size_limit" ]; then
          terminal_status="unknown_outcome"
          PW_RESULT_PHASE="verification"
          PW_RESULT_CODE="ARTIFACT_TOO_LARGE"
          PW_RESULT_MESSAGE="screenshot artifact exceeds the size limit"
          pw_artifact_remove "$screenshot_path"
        else
          local meta
          meta="$(pw_artifact_metadata "$screenshot_path" "screenshot" "image/png" "true")"
          pw_result_add_artifact "$meta"
          PW_RESULT_DATA="$(jq -nc --arg ref "$(jq -r '.id' <<< "$meta")" '{artifact_ref: $ref}')"
        fi
      fi
    else
      pw_artifact_remove "$screenshot_path"
    fi
  fi

  if [ "$terminal_status" = "ok" ] && [ "$adapter_kind" = "snapshot" ]; then
    local out_size inline_limit snapshot_limit meta
    out_size="$(stat -c%s "$PW_SPAWN_STDOUT")"
    inline_limit="$(jq -r '.limits.inline_bytes' "$ACTIONS_JSON")"
    snapshot_limit="$(jq -r '.limits.snapshot_bytes' "$ACTIONS_JSON")"
    if [ "$out_size" -gt "$inline_limit" ]; then
      if [ "$out_size" -gt "$snapshot_limit" ]; then
        terminal_status="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="ARTIFACT_TOO_LARGE"
        PW_RESULT_MESSAGE="snapshot output exceeds the snapshot size limit"
      else
        if ! meta="$(pw_artifact_store "$session" "read" "snapshot" "json" "application/json" "true" < "$PW_SPAWN_STDOUT")"; then
          terminal_status="unknown_outcome"
          PW_RESULT_PHASE="verification"
          PW_RESULT_CODE="ARTIFACT_PATH_REJECTED"
          PW_RESULT_MESSAGE="artifact path contains symlinks"
        else
          pw_result_add_artifact "$meta"
          PW_RESULT_DATA="$(jq -nc --arg ref "$(jq -r '.id' <<< "$meta")" '{artifact_ref: $ref}')"
        fi
      fi
    fi
  fi

  # Every successful snapshot establishes a new ref-observation epoch. Return
  # the same UUID that is durably recorded in the session ledger.
  if [ "$terminal_status" = "ok" ] && [ "$action_name" = "page.snapshot" ]; then
    local observation_id recovery_record
    observation_id="$(pw_new_uuid)"
    recovery_record="null"
    if [ -n "$ledger" ]; then
      recovery_record="$(jq -c '.recovery // null' <<< "$ledger")"
    fi
    if pw_ledger_write "$session" "$(pw_build_ledger "$session" "$generation" "\"$observation_id\"" "$recovery_record")"; then
      PW_RESULT_DATA="$(jq -c --arg observation_id "$observation_id" '
        if type == "object" then . + {observation_id: $observation_id}
        else {result: ., observation_id: $observation_id}
        end
      ' <<< "$PW_RESULT_DATA")"
    else
      terminal_status="failed"
      PW_RESULT_PHASE="verification"
      PW_RESULT_CODE="STATE_WRITE_FAILED"
      PW_RESULT_MESSAGE="failed to record the snapshot observation"
    fi
  fi

  # terminal journal + owner transitions
  if [ "$is_write" = "true" ]; then
    pw_terminal_journal "$session" "$journal" "$terminal_status"
    if [ "$action_name" = "browser.open" ]; then
      if [ "$terminal_status" = "ok" ]; then
        pw_ledger_write "$session" "$(pw_build_ledger "$session" "$generation")"
        pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "active" "$PWD" "$(pw_default_runtime_id)" "$request_id")"
      elif [ "$terminal_status" = "failed" ]; then
        pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "closed" "$PWD" "$(pw_default_runtime_id)" "$request_id")"
      fi
    elif [ "$action_name" = "browser.close" ] && [ "$terminal_status" = "ok" ]; then
      pw_owner_write "$session" "$(pw_build_owner "$session" "$generation" "closed" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"
    fi
  fi

  case "$terminal_status" in
    ok)
      pw_emit_envelope "$(pw_envelope_ok "$PW_RESULT_DATA" "$PW_RESULT_ARTIFACTS" "${PW_RUNTIME_ENV:-null}")"
      ;;
    unknown_outcome)
      pw_emit_envelope "$(pw_envelope_unknown_outcome "$PW_RESULT_PHASE" "$PW_RESULT_CODE" "$PW_RESULT_MESSAGE" "$PW_SPAWN_RC" "$PW_RESULT_SIGNAL" "$stderr_excerpt" "$PW_RESULT_DATA" "$PW_RESULT_ARTIFACTS" "${PW_RUNTIME_ENV:-null}")"
      ;;
    failed)
      pw_emit_envelope "$(pw_envelope_fail "$PW_RESULT_PHASE" "$PW_RESULT_CODE" "$PW_RESULT_MESSAGE" "$PW_RESULT_RETRYABLE" "$PW_SPAWN_RC" "$PW_RESULT_SIGNAL" "$stderr_excerpt" "$PW_RESULT_DATA" "$PW_RESULT_ARTIFACTS" "${PW_RUNTIME_ENV:-null}")"
      ;;
  esac
}

main() {
  [ "$#" -ge 1 ] || usage
  pw_check_dependencies
  pw_workspace_check || {
    pw_envelope_fail "preflight" "WORKSPACE_INVALID" "the working directory is not canonical" false
    exit 1
  }
  local action_name="$1"
  shift

  trap 'pw_cleanup_runtime_temps' EXIT
  trap 'pw_handle_runtime_signal HUP' HUP
  trap 'pw_handle_runtime_signal INT' INT
  trap 'pw_handle_runtime_signal TERM' TERM
  local input_file=""
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    if [ -f "$1" ]; then
      input_file="$1"
    else
      input_file="$(mktemp /tmp/pwcli-input-XXXXXX)"
      PW_INPUT_TEMP="$input_file"
      printf '%s\n' "$1" > "$input_file"
    fi
  elif [ ! -t 0 ]; then
    input_file="$(mktemp /tmp/pwcli-input-XXXXXX)"
    PW_INPUT_TEMP="$input_file"
    cat > "$input_file"
  else
    usage
  fi
  if ! jq empty "$input_file" >/dev/null 2>&1; then
    pw_envelope_fail "validation" "INVALID_JSON" "Input is not valid JSON" false
    exit 1
  fi

  local action_def
  action_def="$(jq -c --arg name "$action_name" '.actions[] | select(.name == $name)' "$ACTIONS_JSON" 2>/dev/null || true)"
  if [ -z "$action_def" ]; then
    pw_envelope_fail "validation" "UNKNOWN_ACTION" "Unknown action: $action_name" false
    exit 1
  fi
  PW_ACTION_DEF="$action_def"

  # input validation against the synthesized schema
  local input
  input="$(cat "$input_file")"
  local full_schema error
  full_schema="$(pw_full_input_schema "$action_def")"
  if ! error="$(pw_validate_input "$full_schema" "$input")"; then
    local code path
    code="$(jq -r '.code' <<< "$error")"
    path="$(jq -r '.path' <<< "$error")"
    pw_envelope_fail "validation" "$code" "input validation failed at $path" false
    exit 1
  fi

  # permission/grant boundary
  local permission grant
  permission="$(jq -r '.permission' <<< "$action_def")"
  grant="$(jq -r '.grant // empty' <<< "$action_def")"
  local input_grant
  input_grant="$(jq -r '.grant // "read"' <<< "$input")"
  if [ "$grant" = "write" ] && [ "$(pw_permission_level "$input_grant")" -lt 1 ]; then
    pw_envelope_fail "validation" "GRANT_INSUFFICIENT" "Action requires write grant but got '$input_grant'" false
    exit 1
  fi

  # envelope context
  local session request_id
  session="$(pw_input_session "$input")"
  [ -n "$session" ] || session=""
  request_id="$(pw_input_request_id "$input")"
  [ -n "$request_id" ] || request_id=""
  pw_envelope_set_context "$action_name" "$permission" \
    "$(jq -nc --arg s "$session" 'if $s == "" then null else $s end')" \
    "$(jq -nc --arg r "$request_id" 'if $r == "" then null else $r end')" \
    "null"
  PW_RUNTIME_ENV="null"

  local handler is_write
  handler="$(jq -r '.handler' <<< "$action_def")"
  is_write="false"
  [ "$permission" = "read" ] || is_write="true"

  if [ "$handler" = "internal" ]; then
    pw_run_internal_action "$action_name" "$input"
  else
    pw_run_cli_action_flow "$action_def" "$input" "$action_name" "$permission" "$is_write"
  fi
}

main "$@"
