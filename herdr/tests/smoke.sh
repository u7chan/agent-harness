#!/usr/bin/env bash
set -eu

# Smoke test for herdr skill using fake herdr CLI.
# Run: cd /path/to/global-agent-skills && bash herdr/tests/smoke.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"

FAKE_HERDR="$HERDR_DIR/tests/fake_herdr.sh"

# Create a wrapper herdr script in a temp dir and prepend to PATH
FAKE_BIN_DIR="$(mktemp -d /tmp/herdr-fake-bin-XXXXXX)"
cat > "$FAKE_BIN_DIR/herdr" <<SCRIPTEOF
#!/usr/bin/env bash
exec bash "$FAKE_HERDR" "\$@"
SCRIPTEOF
chmod +x "$FAKE_BIN_DIR/herdr"
export PATH="$FAKE_BIN_DIR:$PATH"

Herdr_SCRIPT="$HERDR_DIR/scripts/herdr.sh"

PASS=0
FAIL=0

test_name=""
assert_ok() {
  local result
  result="$(cat)"
  local check="$1"
  test_name="${2:-$check}"
  if echo "$result" | jq -e "$check" >/dev/null 2>&1; then
    echo "PASS: $test_name"
    echo "PASS" >> "$PASS_FAIL_FILE"
  else
    echo "FAIL: $test_name"
    echo "  got: $(echo "$result" | jq -c '.' 2>/dev/null || echo "$result")"
    echo "FAIL" >> "$PASS_FAIL_FILE"
  fi
}

PASS_FAIL_FILE="$(mktemp /tmp/herdr-smoke-results-XXXXXX)"
: > "$PASS_FAIL_FILE"

cleanup() {
  rm -rf /tmp/herdr-fake-state
  local manifest_dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams"
  rm -rf "$manifest_dir"
}

full_cleanup() {
  cleanup
  rm -rf "$FAKE_BIN_DIR"
}

cleanup

echo "=== Herdr Smoke Tests (mock) ==="
echo ""

# --- Catalog Actions ---
echo "--- Catalog ---"

bash "$Herdr_SCRIPT" actions.list | assert_ok '.status == "ok" and (.data | type == "array")' "actions.list returns action array"

echo '{"action":"actions.list"}' | bash "$Herdr_SCRIPT" actions.describe | assert_ok '.status == "ok" and .data.name == "actions.list"' "actions.describe returns action definition"

echo '{"action":"actions.describe"}' | bash "$Herdr_SCRIPT" actions.describe | assert_ok '.status == "ok"' "actions.describe self-describes"

# --- Validation ---
echo "--- Validation ---"

bash "$Herdr_SCRIPT" unknown.action 2>&1 | assert_ok '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action fails"

echo '{"unknown_field":"value"}' | bash "$Herdr_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "UNKNOWN_FIELDS"' "unknown field rejected"

echo '{}' | bash "$Herdr_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "MISSING_INPUT"' "missing required field"

echo '{"action":123}' | bash "$Herdr_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "TYPE_MISMATCH"' "type mismatch rejected"

echo 'not json' | bash "$Herdr_SCRIPT" actions.list 2>&1 | assert_ok '.status == "failed" and .error.code == "INVALID_JSON"' "invalid JSON rejected"

# --- Envelope ---
echo "--- Envelope ---"

bash "$Herdr_SCRIPT" actions.list | assert_ok '.schema_version == 1 and .status != null and .action == "actions.list" and .actor == "user" and .target != null and .data != null' "envelope has required fields"

# --- Team Start ---
echo "--- Team Start ---"

TEAM_RESULT=$(echo '{"request_id":"smoke-001","grant":"write"}' | bash "$Herdr_SCRIPT" team.start)
echo "$TEAM_RESULT" | assert_ok '.status == "ok"' "team.start succeeds"

TEAM_ID=$(echo "$TEAM_RESULT" | jq -r '.data.team_id')
echo "Team ID: $TEAM_ID"

echo '{"request_id":"smoke-001","grant":"write"}' | bash "$Herdr_SCRIPT" team.start | assert_ok '.status == "already_applied"' "team.start idempotent (same request_id)"

# --- Team Get ---
echo "--- Team Get ---"

echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$Herdr_SCRIPT" team.get | assert_ok '.status == "ok" and .data.team_id != null' "team.get returns manifest"

echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$Herdr_SCRIPT" team.get | assert_ok '.data.members | length > 0' "team.get has members"

# --- Team List ---
echo "--- Team List ---"

bash "$Herdr_SCRIPT" team.list | assert_ok '.status == "ok" and (.data | type == "array")' "team.list returns array"

# --- Member Prompt ---
echo "--- Member Prompt ---"

echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$Herdr_SCRIPT" member.prompt | assert_ok '.status == "ok"' "member.prompt succeeds"

echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$Herdr_SCRIPT" member.prompt | assert_ok '.status == "already_applied"' "member.prompt idempotent"

# --- Member Wait ---
echo "--- Member Wait ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\"}" | bash "$Herdr_SCRIPT" member.wait | assert_ok '.status == "ok" or .status == "completed" or .status == "waiting"' "member.wait returns valid status"

# --- Member Read ---
echo "--- Member Read ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"lines\":50}" | bash "$Herdr_SCRIPT" member.read | assert_ok '.status == "ok"' "member.read succeeds"

# --- Member Close ---
echo "--- Member Close ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" member.close | assert_ok '.status == "ok" and .data.closed == true' "member.close succeeds"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" member.close | assert_ok '.status == "already_applied"' "member.close idempotent"

# --- Team Stop ---
echo "--- Team Stop ---"

echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" team.stop | assert_ok '.status == "ok"' "team.stop succeeds"

echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$Herdr_SCRIPT" team.stop | assert_ok '.status == "already_applied"' "team.stop idempotent"

# --- Grant Rejection ---
echo "--- Grant Rejection ---"

echo '{"request_id":"r1","grant":"read"}' | bash "$Herdr_SCRIPT" team.start 2>&1 | assert_ok '.status == "failed" and .error.code == "GRANT_INSUFFICIENT"' "team.start rejected with read grant"

# --- Not Found ---
echo "--- Not Found ---"

echo '{"team_id":"nonexistent"}' | bash "$Herdr_SCRIPT" team.get 2>&1 | assert_ok '.status == "failed" and .error.code == "NOT_FOUND"' "team.get fails for nonexistent team"

# --- Config: default fallback ---
echo "--- Config ---"

# Verify default config is used when no config files exist
echo '{"request_id":"cfg-001","grant":"write"}' | bash "$Herdr_SCRIPT" team.start | assert_ok '.status == "ok"' "team.start uses default config"

echo ""
echo "=== Results ==="
PASS=$(grep -c "^PASS$" "$PASS_FAIL_FILE" 2>/dev/null || true)
FAIL=$(grep -c "^FAIL$" "$PASS_FAIL_FILE" 2>/dev/null || true)
PASS="${PASS//[^0-9]/}"
FAIL="${FAIL//[^0-9]/}"
[ -z "$PASS" ] && PASS=0
[ -z "$FAIL" ] && FAIL=0
echo "Passed: $PASS"
echo "Failed: $FAIL"
rm -f "$PASS_FAIL_FILE"

full_cleanup

if [ "$FAIL" -gt 0 ] 2>/dev/null; then
  exit 1
fi
exit 0
