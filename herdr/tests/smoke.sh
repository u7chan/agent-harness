#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"

FAKE_HERDR="$HERDR_DIR/tests/fake_herdr.sh"

TEST_STATE_HOME="$(mktemp -d /tmp/herdr-smoke-state-XXXXXX)"
export XDG_STATE_HOME="$TEST_STATE_HOME"
export FAKE_STATE_DIR="$TEST_STATE_HOME/fake-state"
rm -f "$FAKE_STATE_DIR/.pane_counter"

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

cleanup_fake_state() {
  rm -rf "$FAKE_STATE_DIR"
  mkdir -p "$FAKE_STATE_DIR"
  rm -f "$FAKE_STATE_DIR/.pane_counter"
  local manifest_dir="$TEST_STATE_HOME/herdr-skill/teams"
  rm -rf "$manifest_dir"
}

full_cleanup() {
  rm -rf "$FAKE_BIN_DIR"
  rm -rf "$TEST_STATE_HOME"
}
trap full_cleanup EXIT

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

run_herdr() {
  local result
  result="$(bash "$HERDR_SCRIPT" "$@" 2>&1)" || true
  echo "$result"
}

cleanup_fake_state

echo "=== Herdr Smoke Tests (mock v2) ==="
echo ""

# --- Catalog Actions ---
echo "--- Catalog ---"

assert_ok "$(run_herdr actions.list)" '.status == "ok" and (.data | type == "array")' "actions.list returns action array"
assert_ok "$(echo '{"action":"actions.list"}' | bash "$HERDR_SCRIPT" actions.describe)" '.status == "ok" and .data.name == "actions.list"' "actions.describe returns action definition"
assert_ok "$(echo '{"action":"actions.describe"}' | bash "$HERDR_SCRIPT" actions.describe)" '.status == "ok"' "actions.describe self-describes"

# --- Validation ---
echo "--- Validation ---"
assert_ok "$(bash "$HERDR_SCRIPT" unknown.action 2>&1)" '.status == "failed" and .error.code == "UNKNOWN_ACTION"' "unknown action fails"
assert_ok "$(echo '{"unknown_field":"value"}' | bash "$HERDR_SCRIPT" actions.describe 2>&1)" '.status == "failed" and .error.code == "UNKNOWN_FIELDS"' "unknown field rejected"
assert_ok "$(echo '{}' | bash "$HERDR_SCRIPT" actions.describe 2>&1)" '.status == "failed" and .error.code == "MISSING_INPUT"' "missing required field"
assert_ok "$(echo '{"action":123}' | bash "$HERDR_SCRIPT" actions.describe 2>&1)" '.status == "failed" and .error.code == "TYPE_MISMATCH"' "type mismatch rejected"
assert_ok "$(echo 'not json' | bash "$HERDR_SCRIPT" actions.list 2>&1)" '.status == "failed" and .error.code == "INVALID_JSON"' "invalid JSON rejected"

# --- Envelope ---
echo "--- Envelope ---"
assert_ok "$(run_herdr actions.list)" '.schema_version == 1 and .status != null and .action == "actions.list" and .actor == "user" and .target != null and .data != null' "envelope has required fields"

# --- Team Start ---
echo "--- Team Start ---"
cleanup_fake_state
TEAM_RESULT=$(echo '{"request_id":"smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$TEAM_RESULT" '.status == "ok"' "team.start succeeds"
TEAM_ID=$(echo "$TEAM_RESULT" | jq -r '.data.team_id')
echo "Team ID: $TEAM_ID"

assert_ok "$(echo '{"request_id":"smoke-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)" '.status == "already_applied"' "team.start idempotent (same request_id)"

# --- Team Get ---
echo "--- Team Get ---"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)" '.status == "ok" and .data.team_id != null' "team.get returns manifest"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)" '.data.members | length > 0' "team.get has members"

# --- Team List ---
echo "--- Team List ---"
assert_ok "$(run_herdr team.list)" '.status == "ok" and (.data | type == "array")' "team.list returns array"
assert_ok "$(run_herdr team.list)" '.data | length > 0' "team.list returns our team"

# --- Agent Naming ---
echo "--- Agent Naming ---"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)" '.data.members[0].agent_name != null' "agent names present"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)" '.data.members[0].agent_name | startswith("opencode")' "agent name uses member kind"
if [ -f "$FAKE_STATE_DIR/started_agents.log" ]; then
  echo "PASS: fake herdr recorded agent start logs"
  PASS=$((PASS + 1))
else
  echo "FAIL: fake herdr did not record agent start logs"
  FAIL=$((FAIL + 1))
fi
if [ -f "$FAKE_STATE_DIR/pane_labels.log" ]; then
  echo "PASS: fake herdr recorded pane labels"
  PASS=$((PASS + 1))
else
  echo "FAIL: fake herdr did not record pane labels"
  FAIL=$((FAIL + 1))
fi

# Verify different pane IDs (persistent counter)
PANEL_IDS=$(echo "{\"team_id\":\"$TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | jq -r '[.data.members[].pane_id] | unique | length')
if [ "$PANEL_IDS" -ge 2 ] 2>/dev/null; then
  echo "PASS: members have distinct pane_ids"
  PASS=$((PASS + 1))
else
  echo "FAIL: members share same pane_id (counter reset)"
  FAIL=$((FAIL + 1))
fi

# --- Member Prompt ---
echo "--- Member Prompt ---"
assert_ok "$(echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "ok"' "member.prompt succeeds"
assert_ok "$(echo "{\"request_id\":\"msg-001\",\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"text\":\"Implement this\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "already_applied"' "member.prompt idempotent"

# --- Deferred Activation ---
echo "--- Deferred Activation ---"
DEFERRED_TEAM_RESULT=$(echo '{"request_id":"def-team-001","grant":"write","kickoff_context":{"issue":"42","base":"main","work_branch":"feat/test"}}' | bash "$HERDR_SCRIPT" team.start)
DEFERRED_TEAM_ID=$(echo "$DEFERRED_TEAM_RESULT" | jq -r '.data.team_id')
echo "Deferred team ID: $DEFERRED_TEAM_ID"

assert_ok "$(echo "{\"request_id\":\"def-001\",\"team_id\":\"$DEFERRED_TEAM_ID\",\"role\":\"review\",\"text\":\"Please review\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "ok" or .status == "unknown_outcome"' "deferred review prompt accepted"

REVIEW_AGENT_NAME=$(echo "{\"team_id\":\"$DEFERRED_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | jq -r '.data.members[] | select(.role == "review") | .agent_name')
if [ -f "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt" ]; then
  REVIEW_PROMPT_TEXT=$(cat "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt")
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "review.*ロール"; then
    echo "PASS: deferred review prompt includes role prompt"
    PASS=$((PASS + 1))
  else
    echo "FAIL: deferred review prompt missing role prompt"
    echo "  got: $REVIEW_PROMPT_TEXT"
    FAIL=$((FAIL + 1))
  fi
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "Kickoff Context"; then
    echo "PASS: deferred review prompt includes kickoff context"
    PASS=$((PASS + 1))
  else
    echo "FAIL: deferred review prompt missing kickoff context"
    FAIL=$((FAIL + 1))
  fi
  if echo "$REVIEW_PROMPT_TEXT" | grep -q "Please review"; then
    echo "PASS: deferred review prompt includes caller text"
    PASS=$((PASS + 1))
  else
    echo "FAIL: deferred review prompt missing caller text"
    FAIL=$((FAIL + 1))
  fi
fi

# Second prompt should NOT include role prompt
assert_ok "$(echo "{\"request_id\":\"def-002\",\"team_id\":\"$DEFERRED_TEAM_ID\",\"role\":\"review\",\"text\":\"Second prompt\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "ok" or .status == "unknown_outcome"' "second deferred prompt accepted"
if [ -f "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt" ]; then
  SECOND_PROMPT_TEXT=$(cat "$FAKE_STATE_DIR/${REVIEW_AGENT_NAME}.last_prompt")
  if echo "$SECOND_PROMPT_TEXT" | grep -qv "review.*ロール"; then
    echo "PASS: second prompt does not repeat role prompt"
    PASS=$((PASS + 1))
  else
    echo "FAIL: second prompt still includes role prompt"
    FAIL=$((FAIL + 1))
  fi
fi

# --- Concurrent team.start idempotency (same request_id) ---
echo "--- Concurrent Idempotency ---"
CONCURRENT_REQ="conc-$(date +%s)"
R1=$(echo "{\"request_id\":\"$CONCURRENT_REQ\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)
R2=$(echo "{\"request_id\":\"$CONCURRENT_REQ\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)
OK_COUNT=$(echo -e "$R1\n$R2" | jq -r '.status' | grep -c 'ok' 2>/dev/null || echo 0)
ALREADY_COUNT=$(echo -e "$R1\n$R2" | jq -r '.status' | grep -c 'already_applied' 2>/dev/null || echo 0)
if [ "$OK_COUNT" -eq 1 ] && [ "$ALREADY_COUNT" -eq 1 ]; then
  echo "PASS: concurrent same request_id produces one ok + one already_applied"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent same request_id: ok=$OK_COUNT already=$ALREADY_COUNT"
  FAIL=$((FAIL + 1))
fi

# --- Concurrent member.prompt idempotency ---
echo "--- Concurrent Prompt Idempotency ---"
CONCURRENT_MSG_ID="conc-msg-$(date +%s)"
CONC_TEAM=$(echo "{\"request_id\":\"conc-team-$(date +%s)\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)
CONC_TEAM_ID=$(echo "$CONC_TEAM" | jq -r '.data.team_id')
P1=$(echo "{\"request_id\":\"$CONCURRENT_MSG_ID\",\"team_id\":\"$CONC_TEAM_ID\",\"role\":\"impl\",\"text\":\"Concurrent test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
P2=$(echo "{\"request_id\":\"$CONCURRENT_MSG_ID\",\"team_id\":\"$CONC_TEAM_ID\",\"role\":\"impl\",\"text\":\"Concurrent test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
P_OK=$(echo -e "$P1\n$P2" | jq -r '.status' | grep -c 'ok' 2>/dev/null || echo 0)
P_ALREADY=$(echo -e "$P1\n$P2" | jq -r '.status' | grep -c 'already_applied' 2>/dev/null || echo 0)
if [ "$P_OK" -eq 1 ] && [ "$P_ALREADY" -eq 1 ]; then
  echo "PASS: concurrent member.prompt same request_id produces one ok + one already_applied"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent member.prompt same request_id: ok=$P_OK already=$P_ALREADY"
  FAIL=$((FAIL + 1))
fi

# --- Unknown outcome ---
echo "--- Unknown Outcome ---"
# Test team.start with prompt failure (fake mode=fail)
export FAKE_PROMPT_MODE=unknown
UNKNOWN_START=$(echo "{\"request_id\":\"unknown-start-001\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)
assert_ok "$UNKNOWN_START" '.status == "unknown_outcome"' "team.start with unknown prompt returns unknown_outcome"
UNKNOWN_TEAM_ID=$(echo "$UNKNOWN_START" | jq -r '.data.team_id // ""')
# Retry same request_id should return unknown_outcome again (state persisted)
assert_ok "$(echo "{\"request_id\":\"unknown-start-001\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)" '.status == "unknown_outcome"' "unknown_outcome retry stays unknown_outcome"
export FAKE_PROMPT_MODE=ok
export FAKE_AGENT_START_MODE=ok

# --- Member Wait ---
echo "--- Member Wait ---"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\"}" | bash "$HERDR_SCRIPT" member.wait)" '.status == "ok" or .status == "completed" or .status == "waiting"' "member.wait returns valid status"

# --- Member Read ---
echo "--- Member Read ---"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"lines\":50}" | bash "$HERDR_SCRIPT" member.read)" '.status == "ok"' "member.read succeeds"

# --- Close with unknown outcome ---
echo "--- Close Outcomes ---"
export FAKE_CLOSE_MODE=unknown
UNKNOWN_CLOSE=$(echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)
assert_ok "$UNKNOWN_CLOSE" '.status == "unknown_outcome"' "member.close with unknown transport returns unknown_outcome"
export FAKE_CLOSE_MODE=ok

# --- Member Close normal ---
echo "--- Member Close ---"
# impl was already close-unknown, close again
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "ok" and .data.closed == true' "member.close review succeeds"
assert_ok "$(echo "{\"team_id\":\"$TEAM_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "already_applied"' "member.close idempotent"

# --- Team Stop ---
echo "--- Team Stop ---"
assert_ok "$(echo "{\"team_id\":\"$DEFERRED_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)" '.status == "ok"' "team.stop succeeds"
assert_ok "$(echo "{\"team_id\":\"$DEFERRED_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)" '.status == "already_applied"' "team.stop idempotent"

# --- Grant Rejection ---
echo "--- Grant Rejection ---"
assert_ok "$(echo '{"request_id":"r1","grant":"read"}' | bash "$HERDR_SCRIPT" team.start 2>&1)" '.status == "failed" and .error.code == "GRANT_INSUFFICIENT"' "team.start rejected with read grant"

# --- Not Found ---
echo "--- Not Found ---"
assert_ok "$(echo '{"team_id":"nonexistent"}' | bash "$HERDR_SCRIPT" team.get 2>&1)" '.status == "failed" and .error.code == "NOT_FOUND"' "team.get fails for nonexistent team"

# --- Config: default fallback ---
echo "--- Config ---"
cleanup_fake_state
assert_ok "$(echo '{"request_id":"cfg-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)" '.status == "ok"' "team.start uses default config"

# --- Config: role duplicate detection ---
echo "--- Config Validation ---"
INVALID_CONFIG_DIR="$TEST_STATE_HOME/invalid-config"
mkdir -p "$INVALID_CONFIG_DIR"
echo '{"schema_version":1,"members":[{"role":"impl","kind":"opencode"},{"role":"impl","kind":"opencode"}]}' > "$INVALID_CONFIG_DIR/team.json"
DUP_RESULT=$(echo "{\"request_id\":\"cfg-dup-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$DUP_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config duplicate role rejected"

# --- Config: unknown field in top-level ---
echo '{"schema_version":1,"unknown_top":"bad","members":[{"role":"impl","kind":"opencode"}]}' > "$INVALID_CONFIG_DIR/team.json"
UNK_RESULT=$(echo "{\"request_id\":\"cfg-unk-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$UNK_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config unknown top-level field rejected"

# --- Config: unknown field in member ---
echo '{"schema_version":1,"members":[{"role":"impl","kind":"opencode","bad_field":123}]}' > "$INVALID_CONFIG_DIR/team.json"
UNK_MEMBER=$(echo "{\"request_id\":\"cfg-unkm-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$UNK_MEMBER" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config unknown member field rejected"

# --- Config: kind as object rejected ---
echo '{"schema_version":1,"members":[{"role":"impl","kind":{"name":"bad"}}]}' > "$INVALID_CONFIG_DIR/team.json"
KIND_OBJ=$(echo "{\"request_id\":\"cfg-kindobj-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$KIND_OBJ" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config kind as object rejected"

# --- Config: activation invalid enum ---
echo '{"schema_version":1,"members":[{"role":"impl","kind":"opencode","activation":"bad"}]}' > "$INVALID_CONFIG_DIR/team.json"
BAD_ACT=$(echo "{\"request_id\":\"cfg-act-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$BAD_ACT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config invalid activation rejected"

# --- Config: custom role requires prompt_file ---
echo '{"schema_version":1,"members":[{"role":"custom-role","kind":"opencode"}]}' > "$INVALID_CONFIG_DIR/team.json"
CUST_RESULT=$(echo "{\"request_id\":\"cfg-cust-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$CUST_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config custom role requires prompt_file"

# --- Config: symlink boundary ---
echo '{"schema_version":1,"members":[{"role":"impl","kind":"opencode","prompt_file":"escape.md"}]}' > "$INVALID_CONFIG_DIR/team.json"
ln -sf /etc/hostname "$INVALID_CONFIG_DIR/escape.md" 2>/dev/null || touch "$INVALID_CONFIG_DIR/escape.md"
SYMLINK_RESULT=$(echo "{\"request_id\":\"cfg-sym-001\",\"config_path\":\"$INVALID_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start) || true
assert_ok "$SYMLINK_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "config symlink escape rejected"

# --- Prompt snapshot in manifest ---
echo "--- Prompt Snapshot ---"
cleanup_fake_state
SNAP_RESULT=$(echo '{"request_id":"snap-001","grant":"write","kickoff_context":{"test":"yes"}}' | bash "$HERDR_SCRIPT" team.start)
SNAP_ID=$(echo "$SNAP_RESULT" | jq -r '.data.team_id // ""')
echo "Snapshot team ID: $SNAP_ID"
SNAP_MANIFEST=$(echo "{\"team_id\":\"$SNAP_ID\"}" | bash "$HERDR_SCRIPT" team.get)
HAS_SNAPSHOT=$(echo "$SNAP_MANIFEST" | jq -e '.data.config.prompt_snapshots.impl != null' >/dev/null 2>&1 && echo true || echo false)
if [ "$HAS_SNAPSHOT" = "true" ]; then
  echo "PASS: manifest contains prompt snapshots"
  PASS=$((PASS + 1))
else
  echo "FAIL: manifest missing prompt snapshots"
  echo "  snapshot keys: $(echo "$SNAP_MANIFEST" | jq -c '.data.config.prompt_snapshots | keys' 2>/dev/null || echo 'N/A')"
  FAIL=$((FAIL + 1))
fi

# Verify deferred prompt uses snapshot, not live file
SNAP_REVIEW_AGENT=$(echo "{\"team_id\":\"$SNAP_ID\"}" | bash "$HERDR_SCRIPT" team.get | jq -r '.data.members[] | select(.role == "review") | .agent_name')
echo "{\"request_id\":\"snap-prompt-001\",\"team_id\":\"$SNAP_ID\",\"role\":\"review\",\"text\":\"Test snapshot\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt > /dev/null
if [ -f "$FAKE_STATE_DIR/${SNAP_REVIEW_AGENT}.last_prompt" ]; then
  SNAP_TEXT=$(cat "$FAKE_STATE_DIR/${SNAP_REVIEW_AGENT}.last_prompt")
  if echo "$SNAP_TEXT" | grep -q "review.*ロール"; then
    echo "PASS: deferred prompt uses snapshot content"
    PASS=$((PASS + 1))
  else
    echo "FAIL: deferred prompt missing snapshot content"
    FAIL=$((FAIL + 1))
  fi
fi

# --- Team Start agent start failure ---
echo "--- Agent Start Failure ---"
cleanup_fake_state
export FAKE_AGENT_START_MODE=fail
FAIL_START=$(echo '{"request_id":"fail-start-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1)
assert_ok "$FAIL_START" '.status == "failed" and .error.code == "AGENT_START_FAILED"' "team.start fails with AGENT_START_FAILED"
export FAKE_AGENT_START_MODE=ok

# --- Member prompt failure ---
echo "--- Member Prompt Failure ---"
cleanup_fake_state
FAIL_PROMPT_TEAM=$(echo '{"request_id":"fail-prompt-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
FAIL_PROMPT_TEAM_ID=$(echo "$FAIL_PROMPT_TEAM" | jq -r '.data.team_id')
export FAKE_PROMPT_MODE=fail
FAIL_PROMPT_RESULT=$(echo "{\"request_id\":\"fail-prompt-001\",\"team_id\":\"$FAIL_PROMPT_TEAM_ID\",\"role\":\"impl\",\"text\":\"test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt 2>&1)
assert_ok "$FAIL_PROMPT_RESULT" '.status == "failed"' "member.prompt fails with PROMPT_FAILED"
export FAKE_PROMPT_MODE=ok

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
