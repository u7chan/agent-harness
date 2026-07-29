#!/usr/bin/env bash
set -euo pipefail

# Live smoke test for herdr skill using real Herdr CLI.
# Prerequisites:
#   - HERDR_ENV=1 must be set
#   - herdr must be in PATH
#   - Run from a Herdr workspace with an active agent pane
#
# Run: HERDR_ENV=1 bash herdr/tests/live-smoke.sh
#
# ⚠️ This test creates real panes and agents. Cleanup is automatic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"
Herdr_SCRIPT="$HERDR_DIR/scripts/herdr.sh"

if [ "${HERDR_ENV:-}" != "1" ]; then
  echo "SKIP: HERDR_ENV is not set to 1 (not in a Herdr environment)"
  exit 0
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "SKIP: herdr CLI not found"
  exit 0
fi

cleanup_manifests() {
  local manifest_dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams"
  rm -rf "$manifest_dir"
}

cleanup_manifests

PASS=0
FAIL=0

assert_ok() {
  local result
  result="$(cat)"
  local check="$1"
  local name="${2:-$check}"
  if echo "$result" | jq -e "$check" >/dev/null 2>&1; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  got: $(echo "$result" | jq -c '.')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Herdr Live Smoke Tests ==="
echo ""

# --- Preflight ---
echo "--- Preflight ---"

herdr pane current 2>/dev/null | assert_ok '.status == "ok"' "herdr is running and accessible"

# --- Catalog (always safe) ---
echo "--- Catalog ---"

bash "$Herdr_SCRIPT" actions.list | assert_ok '.status == "ok"' "actions.list"

echo '{"action":"team.start"}' | bash "$Herdr_SCRIPT" actions.describe | assert_ok '.status == "ok"' "actions.describe"

# --- Validation (no Herdr calls needed) ---
echo "--- Validation ---"

bash "$Herdr_SCRIPT" unknown.action 2>&1 | assert_ok '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action"
echo '{}' | bash "$Herdr_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed"' "missing input"

# --- Team Start (creates real panes) ---
echo "--- Team Start (live) ---"

TEAM_RESULT=$(echo '{"request_id":"live-smoke-001","grant":"write"}' | bash "$Herdr_SCRIPT" team.start)
echo "$TEAM_RESULT" | assert_ok '.status == "ok"' "team.start creates team"

TEAM_ID=$(echo "$TEAM_RESULT" | jq -r '.data.team_id // ""')
echo "Team ID: $TEAM_ID"

if [ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "null" ]; then
  # Idempotency
  echo '{"request_id":"live-smoke-001","grant":"write"}' | bash "$Herdr_SCRIPT" team.start | assert_ok '.status == "already_applied"' "team.start idempotent"

  # Team get
  echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$Herdr_SCRIPT" team.get | assert_ok '.status == "ok" and .data.members | length > 0' "team.get"

  # Member prompt (deferred activation test)
  echo "{\"request_id\":\"live-msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"review\",\"text\":\"Please review PR #1\",\"grant\":\"write\"}" | bash "$Herdr_SCRIPT" member.prompt | assert_ok '.status == "ok" or .status == "already_applied" or .status == "unknown_outcome"' "member.prompt review"

  # Member wait
  echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"review\",\"timeout\":5000}" | bash "$Herdr_SCRIPT" member.wait | assert_ok '.status == "waiting" or .status == "completed"' "member.wait"

  # Member read
  echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"review\",\"lines\":10}" | bash "$Herdr_SCRIPT" member.read | assert_ok '.status == "ok"' "member.read"

  # Team stop (closes all panes)
  echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" team.stop | assert_ok '.status == "ok"' "team.stop"

  # Stop idempotency
  echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" team.stop | assert_ok '.status == "already_applied"' "team.stop idempotent"
else
  echo "SKIP: team.start did not return a valid team_id"
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

cleanup_manifests

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
