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

  local session subject_request_id observation_id resolution resolver_request_id
  session="$(jq -r '.session // ""' <<< "$input")"
  subject_request_id="$(jq -r '.subject_request_id // ""' <<< "$input")"
  observation_id="$(jq -r '.observation_id // ""' <<< "$input")"
  resolution="$(jq -r '.resolution // ""' <<< "$input")"
  resolver_request_id="$(jq -r '.request_id // ""' <<< "$input")"

  if ! pw_workspace_check; then
    pw_envelope_fail "preflight" "WORKSPACE_INVALID" "the working directory is not canonical" false
    exit 1
  fi

  if ! pw_acquire_lock "$session"; then
    pw_envelope_fail "lock" "LOCK_BUSY" "another process holds the session lock" false
    exit 1
  fi
  trap 'pw_release_lock' EXIT

  if ! pw_state_validate "$session"; then
    local code message
    code="$(jq -r '.code' <<< "$PW_STATE_ERROR")"
    message="$(jq -r '.message' <<< "$PW_STATE_ERROR")"
    pw_envelope_fail "recovery" "$code" "$message" false
    exit 1
  fi
  if ! pw_startup_recovery "$session"; then
    local code message
    code="$(jq -r '.code' <<< "$PW_STATE_ERROR")"
    message="$(jq -r '.message' <<< "$PW_STATE_ERROR")"
    pw_envelope_fail "recovery" "$code" "$message" false
    exit 1
  fi

  local owner ledger
  owner="$(pw_owner_read "$session")"
  ledger="$(pw_ledger_read "$session")"
  if [ -z "$owner" ]; then
    pw_envelope_fail "recovery" "SESSION_NOT_OWNED" "session '$session' has no ownership marker" false
    exit 1
  fi

  # Idempotent replay: a subject already resolved with the same resolution is
  # answered before any owner-phase gate (the owner may already be active).
  local subject
  subject="$(jq -c --arg id "$subject_request_id" '[.[] | select(.request_id == $id)] | if length > 0 then .[0] else null end' <<< "$(pw_journals_read "$session")")"
  if [ "$subject" != "null" ] && [ "$(jq -r '.state' <<< "$subject")" = "resolved" ]; then
    if [ "$(jq -r '.resolution' <<< "$subject")" = "$resolution" ]; then
      pw_envelope_already_applied "$(jq -cn --arg id "$subject_request_id" --arg r "$resolution" '{subject_request_id: $id, resolution: $r, reason: "subject_already_resolved"}')"
      exit 0
    fi
    pw_envelope_fail "recovery" "SUBJECT_ALREADY_RESOLVED" "subject request was already resolved with a different resolution" false
    exit 1
  fi

  if [ "$(jq -r '.phase' <<< "$owner")" != "quarantined" ]; then
    pw_envelope_fail "recovery" "RECOVERY_NOT_REQUIRED" "session is not quarantined" false
    exit 1
  fi
  if [ -z "$ledger" ]; then
    pw_envelope_fail "recovery" "STALE_EVIDENCE" "no recovery observation is recorded" false
    exit 1
  fi
  if [ "$(jq -r '.latest_observation_id // ""' <<< "$ledger")" != "$observation_id" ]; then
    pw_envelope_fail "recovery" "STALE_EVIDENCE" "observation_id is not the latest recorded observation" false
    exit 1
  fi

  if [ "$subject" = "null" ]; then
    pw_envelope_fail "recovery" "SUBJECT_REQUEST_NOT_FOUND" "no journal exists for subject_request_id" false
    exit 1
  fi

  local owner_generation subject_generation
  owner_generation="$(jq -r '.current_generation' <<< "$owner")"
  subject_generation="$(jq -r '.generation' <<< "$subject")"
  if [ "$subject_generation" != "$owner_generation" ]; then
    pw_envelope_fail "recovery" "SUBJECT_NOT_RECOVERABLE" "subject journal belongs to a different generation" false
    exit 1
  fi

  local subject_state subject_resolution
  subject_state="$(jq -r '.state' <<< "$subject")"
  subject_resolution="$(jq -r '.resolution // "null"' <<< "$subject")"
  if [ "$subject_state" != "unknown" ]; then
    pw_envelope_fail "recovery" "SUBJECT_NOT_RECOVERABLE" "subject journal is not in an unknown state" false
    exit 1
  fi

  # Resolver request journal gate: prevent duplicate resolution under the same request_id.
  if [ -n "$resolver_request_id" ]; then
    local resolver_digest
    resolver_digest="$(pw_input_digest "recovery.resolve" "$input")"
    local resolver_journals
    resolver_journals="$(pw_journals_read "$session")"
    local resolver_match
    resolver_match="$(jq -c --arg id "$resolver_request_id" '[.[] | select(.request_id == $id)] | if length > 0 then .[0] else null end' <<< "$resolver_journals")"
    if [ "$resolver_match" != "null" ]; then
      local resolver_match_state resolver_match_digest
      resolver_match_state="$(jq -r '.state' <<< "$resolver_match")"
      resolver_match_digest="$(jq -r '.digest' <<< "$resolver_match")"
      if [ "$resolver_match_digest" = "$resolver_digest" ]; then
        if [ "$resolver_match_state" = "ok" ]; then
          pw_envelope_already_applied "$(jq -cn --arg id "$resolver_request_id" '{resolver_request_id: $id, reason: "resolver_already_applied"}')"
          exit 0
        fi
      else
        pw_envelope_fail "recovery" "REQUEST_ID_CONFLICT" "resolver request_id was already used with a different binding" false
        exit 1
      fi
    fi
    local resolver_generation
    resolver_generation="$(jq -r '.current_generation' <<< "$owner")"
    local resolver_journal
    resolver_journal="$(pw_build_journal "$session" "$resolver_request_id" "$resolver_generation" "recovery.resolve" "write" "$resolver_digest" "prepared")"
    pw_journal_write "$session" "$resolver_journal"
  fi

  # Resolve the subject journal.
  pw_journal_write "$session" "$(pw_journal_set_state "$session" "$subject" "resolved" "$resolution" "null")"

  # Finalize the resolver journal.
  if [ -n "$resolver_request_id" ]; then
    pw_journal_write "$session" "$(pw_journal_set_state "$session" "$resolver_journal" "ok" "null" "null")"
  fi

  # Owner transition bound to the resolution and the latest evidence.
  local new_phase="quarantined"
  case "$resolution" in
    applied)
      new_phase="closed"
      if pw_resolve_cli && pw_read_versions && pw_session_list; then
        if pw_session_is_live "$session" && pw_session_compatible "$session"; then
          new_phase="active"
        fi
      fi
      ;;
    not_applied)
      new_phase="closed"
      ;;
    indeterminate)
      new_phase="quarantined"
      ;;
  esac
  if [ "$new_phase" = "active" ]; then
    pw_ledger_write "$session" "$(pw_build_ledger "$session" "$owner_generation" "\"$observation_id\"" "$(jq -c '.recovery // null' <<< "$ledger")")"
  fi
  pw_owner_write "$session" "$(pw_build_owner "$session" "$owner_generation" "$new_phase" "$PWD" "$(pw_default_runtime_id)" "$(jq -r '.created_request_id' <<< "$owner")")"

  pw_envelope_ok "$(jq -cn \
    --arg id "$subject_request_id" \
    --arg r "$resolution" \
    --arg phase "$new_phase" \
    '{subject_request_id: $id, resolution: $r, owner_phase: $phase}')" "[]" "null"
}

main "$@"
