#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"
HERDR_SCRIPT="$HERDR_DIR/scripts/herdr.sh"

if [ "${HERDR_ENV:-}" != "1" ]; then
  echo "SKIP: HERDR_ENV is not set to 1 (not in a Herdr environment)"
  exit 0
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "SKIP: herdr CLI not found"
  exit 0
fi

LIVE_STATE_HOME="$(mktemp -d /tmp/herdr-live-state-XXXXXX)"
export XDG_STATE_HOME="$LIVE_STATE_HOME"

PASS=0
FAIL=0
LIVE_TEAM_ID=""

assert_ok() {
  local result="$1"
  local check="$2"
  local name="${3:-$check}"
  if echo "$result" | jq -e "$check" >/dev/null 2>&1; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  got: $(echo "$result" | jq -c '.' 2>/dev/null || echo "$result")"
    FAIL=$((FAIL + 1))
  fi
}

cleanup_team() {
  if [ -n "$LIVE_TEAM_ID" ] && [ "$LIVE_TEAM_ID" != "null" ]; then
    echo "[cleanup] Stopping team $LIVE_TEAM_ID..."
    echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop 2>/dev/null || true
  fi
}

final_cleanup() {
  cleanup_team
  rm -rf "$LIVE_STATE_HOME"
}
trap final_cleanup EXIT

echo "=== Herdr Live Smoke Tests ==="
echo ""

# --- Preflight ---
echo "--- Preflight ---"
HERDR_PANE_CURRENT=$(herdr pane current 2>/dev/null || echo '{}')
if echo "$HERDR_PANE_CURRENT" | jq -e '.result.pane.pane_id != null' >/dev/null 2>&1; then
  echo "PASS: herdr is running and accessible"
  PASS=$((PASS + 1))
else
  echo "FAIL: herdr pane current did not return a valid pane"
  echo "  got: $(echo "$HERDR_PANE_CURRENT" | jq -c '.' 2>/dev/null || echo "$HERDR_PANE_CURRENT")"
  FAIL=$((FAIL + 1))
fi

# --- Catalog ---
echo "--- Catalog ---"
assert_ok "$(bash "$HERDR_SCRIPT" actions.list)" '.status == "ok"' "actions.list"
assert_ok "$(echo '{"action":"team.start"}' | bash "$HERDR_SCRIPT" actions.describe)" '.status == "ok"' "actions.describe"

# --- Validation ---
echo "--- Validation ---"
UNKNOWN_OUTPUT=$(bash "$HERDR_SCRIPT" unknown.action 2>&1) || UNKNOWN_OUTPUT=""
assert_ok "$UNKNOWN_OUTPUT" '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action"
assert_ok "$(echo '{}' | bash "$HERDR_SCRIPT" actions.describe 2>&1)" '.status == "failed"' "missing input"

# --- Team Start ---
echo "--- Team Start (live) ---"
TEAM_RESULT=$(echo '{"request_id":"live-smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$TEAM_RESULT" '.status == "ok"' "team.start creates team"
LIVE_TEAM_ID=$(echo "$TEAM_RESULT" | jq -r '.data.team_id // ""')
echo "Team ID: $LIVE_TEAM_ID"

if [ -n "$LIVE_TEAM_ID" ] && [ "$LIVE_TEAM_ID" != "null" ]; then
  assert_ok "$(echo '{"request_id":"live-smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)" '.status == "already_applied"' "team.start idempotent"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)" '.status == "ok" and .data.members | length > 0' "team.get"
  assert_ok "$(bash "$HERDR_SCRIPT" team.list)" '.status == "ok"' "team.list"
  assert_ok "$(echo "{\"request_id\":\"live-msg-001\",\"team_id\":\"$LIVE_TEAM_ID\",\"role\":\"review\",\"text\":\"Please review PR #1\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "ok" or .status == "already_applied" or .status == "unknown_outcome"' "member.prompt review"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"role\":\"review\",\"timeout\":5000}" | bash "$HERDR_SCRIPT" member.wait)" '.status == "waiting" or .status == "completed"' "member.wait"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"role\":\"review\",\"lines\":10}" | bash "$HERDR_SCRIPT" member.read)" '.status == "ok"' "member.read"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "ok"' "member.close review"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "already_applied"' "member.close idempotent"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)" '.status == "ok"' "team.stop"
  assert_ok "$(echo "{\"team_id\":\"$LIVE_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)" '.status == "already_applied"' "team.stop idempotent"
else
  echo "SKIP: team.start did not return a valid team_id"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
