#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"
HERDR_SCRIPT="$HERDR_DIR/scripts/herdr.sh"
source "$HERDR_DIR/scripts/common/temp.sh"
set +e
set +o pipefail
set -u

if [ "${HERDR_ENV:-}" != "1" ] || [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_TAB_ID:-}" ] || [ -z "${HERDR_WORKSPACE_ID:-}" ]; then
  echo "SKIP: HERDR_ENV is not set to 1 (not in a Herdr environment)"
  exit 0
fi
if ! command -v herdr >/dev/null 2>&1; then
  echo "SKIP: herdr CLI not found"
  exit 0
fi

LIVE_TEMP_ROOT="${HERDR_TEMP_DIR:-/tmp}"
mkdir -p "$LIVE_TEMP_ROOT"
LIVE_TEMP_ROOT="$(realpath -e -- "$LIVE_TEMP_ROOT")"
LIVE_STATE_HOME="$(herdr_temp_create_owned_dir "$LIVE_TEMP_ROOT" "herdr-live-state-")"
export XDG_STATE_HOME="$LIVE_STATE_HOME"

PASS=0
FAIL=0
LIVE_TEAM_ID=""
CLEANUP_FAILED=0
LIVE_SMOKE_PROCESS_ID="$BASHPID"

pane_ids() {
  local raw
  raw="$(herdr pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null)" || return 1
  jq -e -c 'select(.result.panes | type == "array") | [.result.panes[].pane_id] | unique' 2>/dev/null <<< "$raw"
}

if ! INITIAL_PANE_IDS="$(pane_ids)"; then
  echo "FAIL: cannot capture initial pane inventory; refusing to create live resources" >&2
  herdr_temp_remove_owned_dir "$LIVE_TEMP_ROOT" "$LIVE_STATE_HOME" "herdr-live-state-" || true
  exit 1
fi

assert_ok() {
  local result="$1"
  local check="$2"
  local name="${3:-$check}"
  if jq -e "$check" >/dev/null 2>&1 <<< "$result"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  got: $(jq -c '.' 2>/dev/null <<< "$result" || echo "$result")"
    FAIL=$((FAIL + 1))
  fi
}

manifest_team_ids() {
  local manifest_dir="$LIVE_STATE_HOME/herdr-skill/teams"
  local ids='[]' file
  if [ -d "$manifest_dir" ]; then
    for file in "$manifest_dir"/*.json; do
      [ -f "$file" ] || continue
      ids="$(jq -c --arg id "$(jq -r '.team_id // empty' "$file")" 'if $id == "" then . else . + [$id] end' <<< "$ids")"
    done
  fi
  jq -c 'unique' <<< "$ids"
}

manifest_pane_ids() {
  local manifest_dir="$LIVE_STATE_HOME/herdr-skill/teams"
  local ids='[]' file
  if [ -d "$manifest_dir" ]; then
    for file in "$manifest_dir"/*.json; do
      [ -f "$file" ] || continue
      ids="$(jq -c --argjson found "$(jq -c '[.members[]?.pane_id | select(. != null and . != "")]' "$file")" '. + $found' <<< "$ids")"
    done
  fi
  jq -c 'unique' <<< "$ids"
}

owned_pane_ids() {
  manifest_pane_ids
}

safe_remove_live_state() {
  herdr_temp_remove_owned_dir "$LIVE_TEMP_ROOT" "$LIVE_STATE_HOME" "herdr-live-state-"
}

final_cleanup() {
  local original_rc=$?
  [ "$BASH_SUBSHELL" -eq 0 ] || return 0
  [ "$BASHPID" = "$LIVE_SMOKE_PROCESS_ID" ] || return 0
  trap - EXIT
  local team_ids team_id stop_result candidate_panes pane_id close_result final_panes remaining
  team_ids="$(manifest_team_ids)"
  if [ -n "$LIVE_TEAM_ID" ] && [ "$LIVE_TEAM_ID" != "null" ]; then
    team_ids="$(jq -c --arg id "$LIVE_TEAM_ID" '. + [$id] | unique' <<< "$team_ids")"
  fi

  while IFS= read -r team_id; do
    [ -n "$team_id" ] || continue
    stop_result="$(printf '{"team_id":"%s","grant":"sensitive-write"}\n' "$team_id" | bash "$HERDR_SCRIPT" team.stop 2>/dev/null || true)"
    if ! jq -e '.status == "ok" or .status == "already_applied"' >/dev/null 2>&1 <<< "$stop_result"; then
      CLEANUP_FAILED=1
    fi
  done < <(jq -r '.[]' <<< "$team_ids")

  if ! candidate_panes="$(owned_pane_ids)"; then
    echo "[cleanup] FAIL: cannot capture pane inventory" >&2
    CLEANUP_FAILED=1
    candidate_panes="$(manifest_pane_ids 2>/dev/null || echo '[]')"
  fi
  while IFS= read -r pane_id; do
    [ -n "$pane_id" ] || continue
    close_result="$(herdr pane close "$pane_id" 2>/dev/null || true)"
    if ! jq -e '.result != null and .error == null' >/dev/null 2>&1 <<< "$close_result"; then
      CLEANUP_FAILED=1
    fi
  done < <(jq -r '.[]' <<< "$candidate_panes")

  if final_panes="$(pane_ids)"; then
    remaining="$(jq -nc --argjson candidates "$candidate_panes" --argjson final "$final_panes" '$candidates - ($candidates - $final)')"
  else
    remaining="$candidate_panes"
    echo "[cleanup] FAIL: cannot verify final pane inventory" >&2
    CLEANUP_FAILED=1
  fi
  if [ "$(jq -r 'length' <<< "$remaining")" -ne 0 ]; then
    echo "[cleanup] FAIL: panes remain or cannot be verified: $remaining" >&2
    CLEANUP_FAILED=1
  fi

  if [ "$CLEANUP_FAILED" -eq 0 ]; then
    if ! safe_remove_live_state; then
      echo "[cleanup] FAIL: ownership/path validation rejected state removal" >&2
      CLEANUP_FAILED=1
    fi
  else
    echo "[cleanup] State retained for retry: $LIVE_STATE_HOME" >&2
  fi

  if [ "$CLEANUP_FAILED" -ne 0 ] || [ "$original_rc" -ne 0 ]; then
    exit 1
  fi
  exit 0
}
trap final_cleanup EXIT

echo "=== Herdr Live Smoke Tests ==="

PANE_CURRENT="$(herdr pane current 2>/dev/null || echo '{}')"
assert_ok "$PANE_CURRENT" '.result.pane.pane_id != null' "herdr preflight"
assert_ok "$(bash "$HERDR_SCRIPT" actions.list)" '.status == "ok"' "actions.list"

UNKNOWN_OUTPUT="$(bash "$HERDR_SCRIPT" unknown.action 2>&1 || true)"
assert_ok "$UNKNOWN_OUTPUT" '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action"

TEAM_RESULT="$(printf '%s\n' '{"request_id":"live-smoke-001","config_path":"herdr/team.json","origin_kind":"opencode","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)"
assert_ok "$TEAM_RESULT" '.status == "ok"' "team.start creates team"
LIVE_TEAM_ID="$(jq -r '.data.team_id // empty' 2>/dev/null <<< "$TEAM_RESULT")"
if [ -z "$LIVE_TEAM_ID" ]; then
  LIVE_TEAM_ID="$(manifest_team_ids | jq -r 'first // empty')"
fi

if [ -n "$LIVE_TEAM_ID" ]; then
  MANIFEST_RESULT="$(printf '{"team_id":"%s"}\n' "$LIVE_TEAM_ID" | bash "$HERDR_SCRIPT" team.get)"
  assert_ok "$MANIFEST_RESULT" '.status == "ok" and (.data.members | length > 0)' "team.get"
  MANIFEST_PANES="$(jq -c '[.data.members[].pane_id | select(. != null)]' <<< "$MANIFEST_RESULT")"
  CURRENT_PANE_IDS="$(pane_ids)"
  if [ $? -ne 0 ]; then
    CURRENT_PANE_IDS='[]'
    FAIL=$((FAIL + 1))
  fi
  NEW_PANES="$(jq -nc --argjson before "$INITIAL_PANE_IDS" --argjson after "$CURRENT_PANE_IDS" '$after - $before')"
  if [ "$(jq -nc --argjson expected "$MANIFEST_PANES" --argjson actual "$NEW_PANES" '$actual - $expected | length')" -eq 0 ]; then
    echo "PASS: every new pane is tracked by manifest"
    PASS=$((PASS + 1))
  else
    echo "FAIL: untracked panes detected"
    FAIL=$((FAIL + 1))
  fi

  PROMPT_RESULT="$(printf '{"request_id":"live-msg-001","team_id":"%s","role":"review","text":"LIVE_DEFERRED_SENTINEL","grant":"write"}\n' "$LIVE_TEAM_ID" | bash "$HERDR_SCRIPT" member.prompt 2>&1 || true)"
  assert_ok "$PROMPT_RESULT" '.status == "ok" or .status == "unknown_outcome"' "member.prompt deferred"
  WAIT_RESULT="$(printf '{"team_id":"%s","role":"review","timeout":5000}\n' "$LIVE_TEAM_ID" | bash "$HERDR_SCRIPT" member.wait 2>&1 || true)"
  assert_ok "$WAIT_RESULT" '.status == "ok" or .status == "waiting"' "member.wait"
  READ_RESULT="$(printf '{"team_id":"%s","role":"review","lines":10}\n' "$LIVE_TEAM_ID" | bash "$HERDR_SCRIPT" member.read 2>&1 || true)"
  assert_ok "$READ_RESULT" '.status == "ok" and (.data.output | contains("LIVE_DEFERRED_SENTINEL"))' "member.read includes deferred prompt sentinel"
fi

echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
