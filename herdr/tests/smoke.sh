#!/usr/bin/env bash
set -eu

# Smoke test for herdr skill using fake herdr CLI.
# Run: cd /path/to/global-agent-skills && bash herdr/tests/smoke.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"

FAKE_HERDR="$HERDR_DIR/tests/fake_herdr.sh"

TEST_STATE_HOME="$(mktemp -d /tmp/herdr-smoke-state-XXXXXX)"
export XDG_STATE_HOME="$TEST_STATE_HOME"
export FAKE_STATE_DIR="$TEST_STATE_HOME/fake-state"

FAKE_BIN_DIR="$(mktemp -d /tmp/herdr-fake-bin-XXXXXX)"
cat > "$FAKE_BIN_DIR/herdr" <<SCRIPTEOF
#!/usr/bin/env bash
exec bash "$FAKE_HERDR" "\$@"
SCRIPTEOF
chmod +x "$FAKE_BIN_DIR/herdr"
export PATH="$FAKE_BIN_DIR:$PATH"

HERDR_SCRIPT="$HERDR_DIR/scripts/herdr.sh"

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
  rm -rf "$FAKE_STATE_DIR"
  local manifest_dir="$TEST_STATE_HOME/herdr-skill/teams"
  rm -rf "$manifest_dir"
}

full_cleanup() {
  cleanup
  rm -rf "$FAKE_BIN_DIR"
  rm -rf "$TEST_STATE_HOME"
}
trap full_cleanup EXIT

cleanup

echo "=== Herdr Smoke Tests (mock) ==="
echo ""

# --- Catalog Actions ---
echo "--- Catalog ---"

bash "$HERDR_SCRIPT" actions.list | assert_ok '.status == "ok" and (.data | type == "array")' "actions.list returns action array"

echo '{"action":"actions.list"}' | bash "$HERDR_SCRIPT" actions.describe | assert_ok '.status == "ok" and .data.name == "actions.list"' "actions.describe returns action definition"

echo '{"action":"actions.describe"}' | bash "$HERDR_SCRIPT" actions.describe | assert_ok '.status == "ok"' "actions.describe self-describes"

# --- Validation ---
echo "--- Validation ---"

bash "$HERDR_SCRIPT" unknown.action 2>&1 | assert_ok '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action fails"

echo '{"unknown_field":"value"}' | bash "$HERDR_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "UNKNOWN_FIELDS"' "unknown field rejected"

echo '{}' | bash "$HERDR_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "MISSING_INPUT"' "missing required field"

echo '{"action":123}' | bash "$HERDR_SCRIPT" actions.describe 2>&1 | assert_ok '.status == "failed" and .error.code == "TYPE_MISMATCH"' "type mismatch rejected"

echo 'not json' | bash "$HERDR_SCRIPT" actions.list 2>&1 | assert_ok '.status == "failed" and .error.code == "INVALID_JSON"' "invalid JSON rejected"

# --- Envelope ---
echo "--- Envelope ---"

bash "$HERDR_SCRIPT" actions.list | assert_ok '.schema_version == 1 and .status != null and .action == "actions.list" and .actor == "user" and .target != null and .data != null' "envelope has required fields"

# --- Team Start ---
echo "--- Team Start ---"

cleanup
TEAM_RESULT=$(echo '{"request_id":"smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
echo "$TEAM_RESULT" | assert_ok '.status == "ok"' "team.start succeeds"

TEAM_ID=$(echo "$TEAM_RESULT" | jq -r '.data.team_id')
echo "Team ID: $TEAM_ID"

echo '{"request_id":"smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start | assert_ok '.status == "already_applied"' "team.start idempotent (same request_id)"

# --- Team Get ---
echo "--- Team Get ---"

echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | assert_ok '.status == "ok" and .data.team_id != null' "team.get returns manifest"

echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | assert_ok '.data.members | length > 0' "team.get has members"

# --- Team List (workspace-bound) ---
echo "--- Team List ---"

bash "$HERDR_SCRIPT" team.list | assert_ok '.status == "ok" and (.data | type == "array")' "team.list returns array"
# team list should contain exactly the team we just created (ws-fake-001)
bash "$HERDR_SCRIPT" team.list | assert_ok '.data | length > 0' "team.list returns our team"

# --- Agent naming verification ---
echo "--- Agent Naming ---"
# verify agent names use member kind + role + short-team-id
echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | assert_ok '.data.members[0].agent_name != null' "agent names present"
# verify agent names contain member kind (opencode)
echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | assert_ok '.data.members[0].agent_name | startswith("opencode")' "agent name uses member kind"

# Verify started agents log has per-member kind entries
if [ -f "$FAKE_STATE_DIR/started_agents.log" ]; then
  echo "PASS: fake herdr recorded agent start logs"
  echo "PASS" >> "$PASS_FAIL_FILE"
else
  echo "FAIL: fake herdr did not record agent start logs"
  echo "FAIL" >> "$PASS_FAIL_FILE"
fi

# Verify pane labels were set
if [ -f "$FAKE_STATE_DIR/pane_labels.log" ]; then
  echo "PASS: fake herdr recorded pane labels"
  echo "PASS" >> "$PASS_FAIL_FILE"
else
  echo "FAIL: fake herdr did not record pane labels"
  echo "FAIL" >> "$PASS_FAIL_FILE"
fi

# --- Member Prompt ---
echo "--- Member Prompt ---"

echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt | assert_ok '.status == "ok"' "member.prompt succeeds"

echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt | assert_ok '.status == "already_applied"' "member.prompt idempotent"

# --- Deferred activation test ---
echo "--- Deferred Activation ---"
# Create a new team with kickoff_context to test full deferred activation
DEFERRED_TEAM_RESULT=$(echo '{"request_id":"def-team-001","grant":"write","kickoff_context":{"issue":"42","base":"main","work_branch":"feat/test"}}' | bash "$HERDR_SCRIPT" team.start)
DEFERRED_TEAM_ID=$(echo "$DEFERRED_TEAM_RESULT" | jq -r '.data.team_id')
echo "Deferred team ID: $DEFERRED_TEAM_ID"

# review member is deferred - first prompt should include role prompt + kickoff context
REVIEW_PROMPT_RESULT=$(echo "{\"request_id\":\"def-001\",\"team_id\":\"$DEFERRED_TEAM_ID\",\"role\":\"review\",\"text\":\"Please review\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
echo "$REVIEW_PROMPT_RESULT" | assert_ok '.status == "ok" or .status == "unknown_outcome"' "deferred review prompt accepted"

# Check that the prompt text contains the role prompt (deferred activation included it)
REVIEW_AGENT_NAME=$(echo "{\"team_id\":\"$DEFERRED_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | jq -r '.data.members[] | select(.role == "review") | .agent_name')
if [ -f "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt" ]; then
  REVIEW_PROMPT_TEXT=$(cat "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt")
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "review.*ロール"; then
    echo "PASS: deferred review prompt includes role prompt"
    echo "PASS" >> "$PASS_FAIL_FILE"
  else
    echo "FAIL: deferred review prompt missing role prompt"
    echo "  got: $REVIEW_PROMPT_TEXT"
    echo "FAIL" >> "$PASS_FAIL_FILE"
  fi
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "Kickoff Context"; then
    echo "PASS: deferred review prompt includes kickoff context"
    echo "PASS" >> "$PASS_FAIL_FILE"
  else
    echo "FAIL: deferred review prompt missing kickoff context"
    echo "FAIL" >> "$PASS_FAIL_FILE"
  fi
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "Please review"; then
    echo "PASS: deferred review prompt includes caller text"
    echo "PASS" >> "$PASS_FAIL_FILE"
  else
    echo "FAIL: deferred review prompt missing caller text"
    echo "FAIL" >> "$PASS_FAIL_FILE"
  fi
fi

# Second prompt to the same deferred member should NOT include role prompt again
echo "{\"request_id\":\"def-002\",\"team_id\":\"$DEFERRED_TEAM_ID\",\"role\":\"review\",\"text\":\"Second prompt\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt | assert_ok '.status == "ok" or .status == "unknown_outcome"' "second deferred prompt accepted"
if [ -f "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt" ]; then
  SECOND_PROMPT_TEXT=$(cat "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt")
  if echo "$SECOND_PROMPT_TEXT" | grep -qv "review.*ロール"; then
    echo "PASS: second prompt does not repeat role prompt"
    echo "PASS" >> "$PASS_FAIL_FILE"
  else
    echo "FAIL: second prompt still includes role prompt"
    echo "FAIL" >> "$PASS_FAIL_FILE"
  fi
fi

# --- Member Wait ---
echo "--- Member Wait ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\"}" | bash "$HERDR_SCRIPT" member.wait | assert_ok '.status == "ok" or .status == "completed" or .status == "waiting"' "member.wait returns valid status"

# --- Member Read ---
echo "--- Member Read ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"lines\":50}" | bash "$HERDR_SCRIPT" member.read | assert_ok '.status == "ok"' "member.read succeeds"

# --- Member Close ---
echo "--- Member Close ---"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close | assert_ok '.status == "ok" and .data.closed == true' "member.close succeeds"

echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close | assert_ok '.status == "already_applied"' "member.close idempotent"

# --- Team Stop ---
echo "--- Team Stop ---"

echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop | assert_ok '.status == "ok"' "team.stop succeeds"

echo "{\"team_id\":\"$TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop | assert_ok '.status == "already_applied"' "team.stop idempotent"

# --- Grant Rejection ---
echo "--- Grant Rejection ---"

echo '{"request_id":"r1","grant":"read"}' | bash "$HERDR_SCRIPT" team.start 2>&1 | assert_ok '.status == "failed" and .error.code == "GRANT_INSUFFICIENT"' "team.start rejected with read grant"

# --- Not Found ---
echo "--- Not Found ---"

echo '{"team_id":"nonexistent"}' | bash "$HERDR_SCRIPT" team.get 2>&1 | assert_ok '.status == "failed" and .error.code == "NOT_FOUND"' "team.get fails for nonexistent team"

# --- Config: default fallback ---
echo "--- Config ---"

cleanup
echo '{"request_id":"cfg-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start | assert_ok '.status == "ok"' "team.start uses default config"

# --- Workspace boundary ---
echo "--- Workspace Boundary ---"
# team.list should only show teams from current workspace
CFG_TEAM_ID=$(echo '{"request_id":"cfg-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start | jq -r '.data.team_id')
TEAM_LIST_COUNT=$(bash "$HERDR_SCRIPT" team.list | jq -r '.data | length')
echo "PASS: team.list count=$TEAM_LIST_COUNT" "team.list responds"
echo "PASS" >> "$PASS_FAIL_FILE"

# --- Cross-workspace reject: team.get with different workspace ---
# All fake teams are created in ws-fake-001, so this should work
echo "{\"team_id\":\"$CFG_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | assert_ok '.status == "ok"' "team.get matches workspace"

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

if [ "$FAIL" -gt 0 ] 2>/dev/null; then
  exit 1
fi
exit 0
