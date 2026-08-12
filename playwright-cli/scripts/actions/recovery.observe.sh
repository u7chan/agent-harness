#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/runtime.sh"
source "$SCRIPT_DIR/../common/state.sh"

main() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    input='{}'
  fi

  local session
  session="$(jq -r '.session // ""' <<< "$input")"
  [ -n "$session" ] || {
    pw_envelope_fail "validation" "MISSING_REQUIRED_FIELD" "session is required" false
    exit 1
  }

  if ! pw_workspace_check; then
    pw_envelope_fail "preflight" "WORKSPACE_INVALID" "the working directory is not canonical" false
    exit 1
  fi

  if ! pw_acquire_lock "$session"; then
    pw_envelope_fail "lock" "LOCK_BUSY" "another process holds the session lock" false
    exit 1
  fi
  trap 'pw_release_lock' EXIT

  # Lenient reads: corrupt state is evidence, not an action failure.
  local owner ledger journals state_corrupt="false"
  owner="$(pw_owner_read "$session")"
  ledger="$(pw_ledger_read "$session")"
  local requests_dir
  requests_dir="$(pw_session_dir "$session")/requests"
  if ! pw_reject_symlinks "$requests_dir"; then
    state_corrupt="true"
  fi
  if [ "$state_corrupt" = "false" ] && [ -d "$requests_dir" ]; then
    local jf
    for jf in "$requests_dir"/*.json; do
      if { [ -e "$jf" ] || [ -L "$jf" ]; } && ! pw_reject_symlinks "$jf"; then
        state_corrupt="true"
        break
      fi
    done
  fi
  journals="$(pw_journals_read "$session")"
  if [ -n "$ledger" ] && ! jq empty <<< "$ledger" >/dev/null 2>&1; then
    state_corrupt="true"
  fi

  if [ -z "$owner" ]; then
    pw_envelope_fail "recovery" "SESSION_NOT_OWNED" "session '$session' has no ownership marker" false
    exit 1
  fi

  local owner_phase generation
  if jq empty <<< "$owner" >/dev/null 2>&1; then
    owner_phase="$(jq -r '.phase // "unknown"' <<< "$owner")"
    generation="$(jq -r '.current_generation // ""' <<< "$owner")"
  else
    state_corrupt="true"
    owner_phase="unknown"
    generation=""
  fi
  if [ "$owner_phase" != "opening" ] && [ "$owner_phase" != "quarantined" ] && [ "$owner_phase" != "unknown" ]; then
    pw_envelope_fail "recovery" "RECOVERY_NOT_REQUIRED" "session is not in a recoverable state (phase: $owner_phase)" false
    exit 1
  fi

  # Best-effort CLI observation: unresponsive is data, not an action failure.
  local cli_available="false" live_session="false" sessions="[]" sessions_snapshot="[]"
  if pw_resolve_cli && pw_read_versions; then
    cli_available="true"
    if pw_session_list; then
      sessions="$PW_SESSIONS"
      sessions_snapshot="$(jq -c '[.[] | {name, version, compatible}]' <<< "$sessions")"
      if pw_session_is_live "$session"; then
        live_session="true"
      fi
    fi
  fi

  local observation_id
  observation_id="$(pw_new_uuid)"

  local evidence
  evidence="$(jq -cn \
    --arg observation_id "$observation_id" \
    --arg observed_at "$(pw_now)" \
    --arg owner_phase "$owner_phase" \
    --arg generation "$generation" \
    --argjson live_session "$live_session" \
    --argjson sessions "$sessions_snapshot" \
    --argjson cli_available "$cli_available" \
    --argjson state_corrupt "$state_corrupt" \
    --argjson journals "$(jq -c '[.[] | {request_id, action, permission, state, resolution, generation}]' <<< "$journals" 2>/dev/null || echo '[]')" \
    '{
      observation_id: $observation_id,
      observed_at: $observed_at,
      owner_phase: $owner_phase,
      generation: $generation,
      live_session: $live_session,
      sessions: $sessions,
      cli_available: $cli_available,
      state_corrupt: $state_corrupt,
      journals: $journals
    }')"

  # Record the observation in the ledger (creating it when missing).
  if [ "$state_corrupt" = "false" ]; then
    local recovery_record latest_json ledger_gen
    recovery_record="$(jq -c '{observation_id, owner_phase, live_session, cli_available, state_corrupt, journals}' <<< "$evidence")"
    latest_json="$(jq -nc --arg v "$observation_id" '$v')"
    if [ -n "$ledger" ]; then
      ledger_gen="$(jq -r '.generation' <<< "$ledger")"
    else
      ledger_gen="$generation"
    fi
    pw_ledger_write "$session" "$(pw_build_ledger "$session" "$ledger_gen" "$latest_json" "$recovery_record")" || true
  fi

  pw_envelope_ok "$evidence" "[]" "null"
}

main "$@"
