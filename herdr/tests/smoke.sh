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

assert_single_json() {
  local result="$1"
  local name="$2"
  if jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<< "$result"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    echo "  got: $result"
    FAIL=$((FAIL + 1))
  fi
}

test_now_ms() {
  local epoch_ns
  epoch_ns="$(date +%s%N)"
  echo $((10#$epoch_ns / 1000000))
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
CONCURRENT_PANES_BEFORE=$(cat "$FAKE_STATE_DIR/.pane_counter")
R1_FILE="$TEST_STATE_HOME/concurrent-start-1.json"
R2_FILE="$TEST_STATE_HOME/concurrent-start-2.json"
export FAKE_SPLIT_SLEEP=0.2
(echo "{\"request_id\":\"$CONCURRENT_REQ\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start > "$R1_FILE") & R1_PID=$!
(echo "{\"request_id\":\"$CONCURRENT_REQ\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start > "$R2_FILE") & R2_PID=$!
wait "$R1_PID" || true
wait "$R2_PID" || true
unset FAKE_SPLIT_SLEEP
CONCURRENT_PANES_AFTER=$(cat "$FAKE_STATE_DIR/.pane_counter")
R1="$(<"$R1_FILE")"
R2="$(<"$R2_FILE")"
OK_COUNT=$(jq -s '[.[] | select(.status == "ok")] | length' "$R1_FILE" "$R2_FILE")
ALREADY_COUNT=$(jq -s '[.[] | select(.status == "already_applied")] | length' "$R1_FILE" "$R2_FILE")
if [ "$OK_COUNT" -eq 1 ] && [ "$ALREADY_COUNT" -eq 1 ]; then
  echo "PASS: concurrent same request_id produces one ok + one already_applied"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent same request_id: ok=$OK_COUNT already=$ALREADY_COUNT"
  FAIL=$((FAIL + 1))
fi
if [ $((CONCURRENT_PANES_AFTER - CONCURRENT_PANES_BEFORE)) -eq 3 ]; then
  echo "PASS: concurrent team.start creates one team's three panes"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent team.start created $((CONCURRENT_PANES_AFTER - CONCURRENT_PANES_BEFORE)) panes"
  FAIL=$((FAIL + 1))
fi

# --- Concurrent member.prompt idempotency ---
echo "--- Concurrent Prompt Idempotency ---"
CONCURRENT_MSG_ID="conc-msg-$(date +%s)"
CONC_TEAM=$(echo "{\"request_id\":\"conc-team-$(date +%s)\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start)
CONC_TEAM_ID=$(echo "$CONC_TEAM" | jq -r '.data.team_id')
P1_FILE="$TEST_STATE_HOME/concurrent-prompt-1.json"
P2_FILE="$TEST_STATE_HOME/concurrent-prompt-2.json"
PROMPT_COUNT_BEFORE=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
export FAKE_PROMPT_SLEEP=0.2
(echo "{\"request_id\":\"$CONCURRENT_MSG_ID\",\"team_id\":\"$CONC_TEAM_ID\",\"role\":\"impl\",\"text\":\"Concurrent test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt > "$P1_FILE") & P1_PID=$!
(echo "{\"request_id\":\"$CONCURRENT_MSG_ID\",\"team_id\":\"$CONC_TEAM_ID\",\"role\":\"impl\",\"text\":\"Concurrent test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt > "$P2_FILE") & P2_PID=$!
wait "$P1_PID" || true
wait "$P2_PID" || true
unset FAKE_PROMPT_SLEEP
P1="$(<"$P1_FILE")"
P2="$(<"$P2_FILE")"
P_OK=$(jq -s '[.[] | select(.status == "ok")] | length' "$P1_FILE" "$P2_FILE")
P_ALREADY=$(jq -s '[.[] | select(.status == "already_applied")] | length' "$P1_FILE" "$P2_FILE")
PROMPT_COUNT_AFTER=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
if [ "$P_OK" -eq 1 ] && [ "$P_ALREADY" -eq 1 ]; then
  echo "PASS: concurrent member.prompt same request_id produces one ok + one already_applied"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent member.prompt same request_id: ok=$P_OK already=$P_ALREADY"
  FAIL=$((FAIL + 1))
fi
if [ $((PROMPT_COUNT_AFTER - PROMPT_COUNT_BEFORE)) -eq 1 ]; then
  echo "PASS: concurrent member.prompt invokes external prompt exactly once"
  PASS=$((PASS + 1))
else
  echo "FAIL: concurrent member.prompt external invocation count changed by $((PROMPT_COUNT_AFTER - PROMPT_COUNT_BEFORE))"
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
FAIL_START=$(echo '{"request_id":"fail-start-001","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$FAIL_START" '.status == "failed" and .error.code == "AGENT_START_FAILED"' "team.start fails with AGENT_START_FAILED"
export FAKE_AGENT_START_MODE=ok

# --- Member prompt failure ---
echo "--- Member Prompt Failure ---"
cleanup_fake_state
FAIL_PROMPT_TEAM=$(echo '{"request_id":"fail-prompt-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
FAIL_PROMPT_TEAM_ID=$(echo "$FAIL_PROMPT_TEAM" | jq -r '.data.team_id')
export FAKE_PROMPT_MODE=fail
FAIL_PROMPT_RESULT=$(echo "{\"request_id\":\"fail-prompt-001\",\"team_id\":\"$FAIL_PROMPT_TEAM_ID\",\"role\":\"impl\",\"text\":\"test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt 2>&1 || true)
assert_ok "$FAIL_PROMPT_RESULT" '.status == "failed"' "member.prompt fails with PROMPT_FAILED"
export FAKE_PROMPT_MODE=ok

# --- Temp ownership and cleanup safety ---
echo "--- Temp Cleanup Safety ---"
TEMP_COMMON="$HERDR_DIR/scripts/common/temp.sh"
EXTERNAL_TEMP_ROOT="$TEST_STATE_HOME/external-temp"
mkdir -p "$EXTERNAL_TEMP_ROOT"
touch "$EXTERNAL_TEMP_ROOT/sentinel"
TEMP_RESULT=$(HERDR_TEMP_DIR="$EXTERNAL_TEMP_ROOT" bash "$HERDR_SCRIPT" actions.list)
assert_ok "$TEMP_RESULT" '.status == "ok"' "dispatcher works with external temp root"
if [ -f "$EXTERNAL_TEMP_ROOT/sentinel" ] && [ "$(find "$EXTERNAL_TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'herdr-skill-*' | wc -l)" -eq 0 ]; then
  echo "PASS: external temp sentinel preserved and invocation child cleaned"
  PASS=$((PASS + 1))
else
  echo "FAIL: external temp root was modified unsafely"
  FAIL=$((FAIL + 1))
fi

OWNED_TEMP=$(bash -c 'source "$1"; herdr_temp_create_owned_dir "$2" "herdr-live-state-"' _ "$TEMP_COMMON" "$EXTERNAL_TEMP_ROOT")
bash -c 'source "$1"; herdr_temp_remove_owned_dir "$2" "$3" "herdr-live-state-"' _ "$TEMP_COMMON" "$EXTERNAL_TEMP_ROOT" "$OWNED_TEMP"
if [ ! -e "$OWNED_TEMP" ]; then
  echo "PASS: self-created owned temp directory is removed"
  PASS=$((PASS + 1))
else
  echo "FAIL: self-created owned temp directory remains"
  FAIL=$((FAIL + 1))
fi

UNOWNED_TEMP="$EXTERNAL_TEMP_ROOT/herdr-live-state-ABC123"
mkdir -p "$UNOWNED_TEMP"
touch "$UNOWNED_TEMP/sentinel"
if bash -c 'source "$1"; herdr_temp_remove_owned_dir "$2" "$3" "herdr-live-state-"' _ "$TEMP_COMMON" "$EXTERNAL_TEMP_ROOT" "$UNOWNED_TEMP" 2>/dev/null; then
  echo "FAIL: cleanup accepted an unowned directory"
  FAIL=$((FAIL + 1))
elif [ -f "$UNOWNED_TEMP/sentinel" ]; then
  echo "PASS: cleanup ownership guard preserves unowned directory"
  PASS=$((PASS + 1))
else
  echo "FAIL: cleanup ownership guard removed unowned sentinel"
  FAIL=$((FAIL + 1))
fi

# --- Identifier, config, workspace, and timeout validation regressions ---
echo "--- Strict Validation Regressions ---"
assert_ok "$(echo '{"team_id":"../../escape"}' | bash "$HERDR_SCRIPT" team.get 2>&1 || true)" '.status == "failed" and .error.code == "INVALID_IDENTIFIER"' "team_id path traversal rejected"
assert_ok "$(echo '{"request_id":"../escape","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "INVALID_IDENTIFIER"' "request_id path traversal rejected"
assert_ok "$(echo '{"request_id":"float-timeout","timeout":5000.5,"grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "INVALID_TIMEOUT"' "fractional timeout returns structured failure"

STRICT_CONFIG_DIR="$TEST_STATE_HOME/strict-config"
mkdir -p "$STRICT_CONFIG_DIR"
printf '%s\n' '{"schema_version":"1","members":[{"role":"impl"}]}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-schema\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "string schema_version rejected"
printf '%s\n' '{"schema_version":1,"members":{}}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-members-object\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "object members rejected"
printf '%s\n' '{"schema_version":1,"members":[]}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-empty-members\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "empty members rejected without fallback"
printf '%s\n' '{"schema_version":1,"members":[{"role":"impl","kind":false}]}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-kind-bool\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "boolean member fields rejected"
printf '%s\n' '{"schema_version":1,"members":[{"role":"bad\nrole","kind":"opencode","prompt_file":"prompt.md"}]}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-newline-role\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "newline in role rejected"
printf '%s\n' '{"schema_version":1,"members":[{"role":"bad\u0000role","kind":"opencode","prompt_file":"prompt.md"}]}' > "$STRICT_CONFIG_DIR/team.json"
assert_ok "$(echo "{\"request_id\":\"strict-nul-role\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)" '.status == "failed" and .error.code == "CONFIG_ERROR"' "NUL in role rejected"
printf '%s\n' '{"schema_version":1,"members":[{"role":"bad\"role","kind":"opencode","prompt_file":"prompt.md"}]}' > "$STRICT_CONFIG_DIR/team.json"
printf '%s\n' 'custom prompt' > "$STRICT_CONFIG_DIR/prompt.md"
QUOTE_RESULT=$(echo "{\"request_id\":\"strict-quote-role\",\"config_path\":\"$STRICT_CONFIG_DIR/team.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$QUOTE_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "quoted custom role rejected before envelope construction"
assert_single_json "$QUOTE_RESULT" "quoted custom role returns one JSON envelope"
MISSING_CONFIG_RESULT=$(echo "{\"request_id\":\"missing-config\",\"config_path\":\"$STRICT_CONFIG_DIR/missing.json\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$MISSING_CONFIG_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "missing explicit config returns CONFIG_ERROR"
if bash -c 'source "$1"; herdr_manifest_lock missing-config 0.2 cleanup-check; herdr_manifest_unlock "$HERDR_MANIFEST_LOCK_FILE" cleanup-check' _ "$HERDR_DIR/scripts/common/manifest.sh"; then
  echo "PASS: config failure releases request lock"
  PASS=$((PASS + 1))
else
  echo "FAIL: config failure left request lock"
  FAIL=$((FAIL + 1))
fi

cleanup_fake_state
export FAKE_WORKSPACE_ID=ws-one
WS1=$(echo '{"request_id":"cross-workspace-request","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
export FAKE_WORKSPACE_ID=ws-two
WS2=$(echo '{"request_id":"cross-workspace-request","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$WS2" '.status == "ok"' "same request_id in another workspace is not deduplicated"
if [ "$(jq -r '.data.team_id' <<< "$WS1")" != "$(jq -r '.data.team_id' <<< "$WS2")" ]; then
  echo "PASS: cross-workspace request creates distinct teams"
  PASS=$((PASS + 1))
else
  echo "FAIL: cross-workspace request reused team"
  FAIL=$((FAIL + 1))
fi
export FAKE_WORKSPACE_ID=ws-fake-001

# --- Lock elapsed time and millisecond conversion ---
echo "--- Lock Timing ---"
cleanup_fake_state
MANIFEST_COMMON="$HERDR_DIR/scripts/common/manifest.sh"
LOCK_SIGNAL="$TEST_STATE_HOME/lock-holder-ready"
bash -c 'source "$1"; herdr_manifest_lock timing-lock 1 timing-owner-one; touch "$2"; sleep 4' _ "$MANIFEST_COMMON" "$LOCK_SIGNAL" & LOCK_HOLDER_PID=$!
while [ ! -f "$LOCK_SIGNAL" ]; do sleep 0.05; done
LOCK_START=$(test_now_ms)
LOCK_RC=0
bash -c 'source "$1"; herdr_manifest_lock timing-lock 2 timing-owner-two; echo "$HERDR_MANIFEST_LOCK_FILE"' _ "$MANIFEST_COMMON" >/dev/null 2>&1 || LOCK_RC=$?
LOCK_END=$(test_now_ms)
wait "$LOCK_HOLDER_PID" || true
LOCK_ELAPSED=$((LOCK_END - LOCK_START))
if [ "$LOCK_RC" -ne 0 ] && [ "$LOCK_ELAPSED" -ge 1800 ] && [ "$LOCK_ELAPSED" -le 3200 ]; then
  echo "PASS: lock timeout 2 seconds elapses accurately (${LOCK_ELAPSED}ms)"
  PASS=$((PASS + 1))
else
  echo "FAIL: lock timeout elapsed=${LOCK_ELAPSED}ms rc=$LOCK_RC"
  FAIL=$((FAIL + 1))
fi
CLI_NOW=$(bash -c 'source "$1"; herdr_cli_now_ms' _ "$HERDR_DIR/scripts/common/herdr_cli.sh")
if [[ "$CLI_NOW" =~ ^[0-9]{13}$ ]]; then
  echo "PASS: nanosecond date output is converted to 13-digit milliseconds"
  PASS=$((PASS + 1))
else
  echo "FAIL: millisecond conversion returned '$CLI_NOW'"
  FAIL=$((FAIL + 1))
fi

# --- Deadline wrapping for every blocking team.start CLI ---
echo "--- Blocking CLI Deadlines ---"
for BLOCK_KIND in split pane_get agent_start prompt; do
  cleanup_fake_state
  unset FAKE_SPLIT_SLEEP FAKE_PANE_GET_SLEEP FAKE_AGENT_START_SLEEP FAKE_PROMPT_SLEEP
  case "$BLOCK_KIND" in
    split) export FAKE_SPLIT_SLEEP=7 ;;
    pane_get) export FAKE_PANE_GET_SLEEP=7 ;;
    agent_start) export FAKE_AGENT_START_SLEEP=7 ;;
    prompt) export FAKE_PROMPT_SLEEP=7 ;;
  esac
  BLOCK_START=$(test_now_ms)
  BLOCK_RESULT=$(echo "{\"request_id\":\"block-$BLOCK_KIND\",\"timeout\":5000,\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
  BLOCK_END=$(test_now_ms)
  BLOCK_ELAPSED=$((BLOCK_END - BLOCK_START))
  if [ "$BLOCK_ELAPSED" -ge 4300 ] && [ "$BLOCK_ELAPSED" -le 6500 ]; then
    echo "PASS: $BLOCK_KIND obeys overall deadline (${BLOCK_ELAPSED}ms)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $BLOCK_KIND deadline elapsed=${BLOCK_ELAPSED}ms"
    FAIL=$((FAIL + 1))
  fi
  assert_single_json "$BLOCK_RESULT" "$BLOCK_KIND deadline returns one JSON envelope"
done
unset FAKE_SPLIT_SLEEP FAKE_PANE_GET_SLEEP FAKE_AGENT_START_SLEEP FAKE_PROMPT_SLEEP

# --- Ready retry, rollback output, and unknown start persistence ---
echo "--- Start Outcome Regressions ---"
cleanup_fake_state
export FAKE_PANE_CURRENT_MODE=fail
CURRENT_FAILURE=$(echo '{"request_id":"current-failure","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$CURRENT_FAILURE" '.status == "failed" and .error.code == "HERDR_ERROR"' "pane.current explicit failure is structured"
assert_single_json "$CURRENT_FAILURE" "pane.current failure returns one JSON envelope"
unset FAKE_PANE_CURRENT_MODE

cleanup_fake_state
export FAKE_SPLIT_MODE=fail
SPLIT_FAILURE=$(echo '{"request_id":"split-failure","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$SPLIT_FAILURE" '.status == "failed" and .error.code == "PANE_CREATE_FAILED" and .data.cleanup_complete == true' "pane.split explicit failure is structured"
assert_single_json "$SPLIT_FAILURE" "pane.split failure returns one JSON envelope"
unset FAKE_SPLIT_MODE

cleanup_fake_state
export FAKE_AGENT_START_MODE=busy-once
BUSY_RESULT=$(echo '{"request_id":"busy-retry","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$BUSY_RESULT" '.status == "ok"' "agent_pane_busy is retried before deadline"
export FAKE_AGENT_START_MODE=ok

cleanup_fake_state
export FAKE_PROMPT_MODE=fail
KICKOFF_FAILURE=$(echo '{"request_id":"kickoff-failure","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$KICKOFF_FAILURE" '.status == "failed" and .error.code == "PROMPT_FAILED" and .data.cleanup_complete == true' "kickoff explicit failure rolls back"
assert_single_json "$KICKOFF_FAILURE" "kickoff failure returns one JSON envelope"
export FAKE_PROMPT_MODE=ok

cleanup_fake_state
export FAKE_AGENT_START_MODE=fail
ROLLBACK_RESULT=$(echo '{"request_id":"rollback-single-json","grant":"write"}' | bash "$HERDR_SCRIPT" team.start 2>&1 || true)
assert_ok "$ROLLBACK_RESULT" '.status == "failed" and .error.code == "AGENT_START_FAILED" and .data.cleanup_complete == true' "known start failure rolls back panes"
assert_single_json "$ROLLBACK_RESULT" "rollback close output is suppressed to one JSON envelope"
export FAKE_AGENT_START_MODE=ok

cleanup_fake_state
export FAKE_PROMPT_MODE=unknown
START_UNKNOWN=$(echo '{"request_id":"unknown-pane-persist","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
START_UNKNOWN_ID=$(jq -r '.data.team_id' <<< "$START_UNKNOWN")
START_UNKNOWN_MANIFEST=$(echo "{\"team_id\":\"$START_UNKNOWN_ID\"}" | bash "$HERDR_SCRIPT" team.get)
assert_ok "$START_UNKNOWN_MANIFEST" '.data.members[0].pane_id != null and .data.members[0].status == "active"' "unknown kickoff persists known pane_id"
assert_ok "$(echo '{"request_id":"unknown-pane-persist","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)" '.status == "unknown_outcome"' "unknown start duplicate is not retried"
export FAKE_PROMPT_MODE=ok
assert_ok "$(echo "{\"team_id\":\"$START_UNKNOWN_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)" '.status == "ok"' "unknown start can be cleaned by persisted pane ids"

# --- Deferred prompt delivery state machine ---
echo "--- Prompt State Machine ---"
cleanup_fake_state
STATE_TEAM=$(echo '{"request_id":"state-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
STATE_TEAM_ID=$(jq -r '.data.team_id' <<< "$STATE_TEAM")
export FAKE_PROMPT_MODE=fail
PROMPT_FAILED=$(echo "{\"request_id\":\"retry-failed\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"review\",\"text\":\"retry me\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt 2>&1 || true)
assert_ok "$PROMPT_FAILED" '.status == "failed" and .data.delivery_status == "failed"' "known prompt failure is recorded as failed"
FAILED_MANIFEST=$(echo "{\"team_id\":\"$STATE_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)
assert_ok "$FAILED_MANIFEST" '.data.prompt_history.review["retry-failed"].status == "failed" and (.data.deferred | index("review") != null)' "known failure retains deferred activation"
export FAKE_PROMPT_MODE=ok
assert_ok "$(echo "{\"request_id\":\"retry-failed\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"review\",\"text\":\"retry me\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)" '.status == "ok" and .data.prompt_sent == true' "failed prompt can retry with same request_id"

export FAKE_PROMPT_MODE=unknown
UNKNOWN_COUNT_BEFORE=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
PROMPT_UNKNOWN=$(echo "{\"request_id\":\"retry-unknown\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"pr-fix\",\"text\":\"unknown me\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
UNKNOWN_COUNT_AFTER_FIRST=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
PROMPT_UNKNOWN_RETRY=$(echo "{\"request_id\":\"retry-unknown\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"pr-fix\",\"text\":\"unknown me\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
PROMPT_UNKNOWN_NEW=$(echo "{\"request_id\":\"retry-unknown-new\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"pr-fix\",\"text\":\"unknown new\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
UNKNOWN_COUNT_FINAL=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
assert_ok "$PROMPT_UNKNOWN" '.status == "unknown_outcome" and .data.delivery_status == "unknown"' "unknown prompt is recorded as unknown"
assert_ok "$PROMPT_UNKNOWN_RETRY" '.status == "unknown_outcome" and .data.delivery_status == "unknown"' "unknown duplicate is not reported as applied"
assert_ok "$PROMPT_UNKNOWN_NEW" '.status == "unknown_outcome" and .data.activation_unknown == true' "new request is blocked while deferred activation is unknown"
if [ "$UNKNOWN_COUNT_AFTER_FIRST" -eq $((UNKNOWN_COUNT_BEFORE + 1)) ] && [ "$UNKNOWN_COUNT_FINAL" -eq "$UNKNOWN_COUNT_AFTER_FIRST" ]; then
  echo "PASS: unknown prompt attempts are never automatically resent"
  PASS=$((PASS + 1))
else
  echo "FAIL: unknown prompt invocation counts before=$UNKNOWN_COUNT_BEFORE first=$UNKNOWN_COUNT_AFTER_FIRST final=$UNKNOWN_COUNT_FINAL"
  FAIL=$((FAIL + 1))
fi
export FAKE_PROMPT_MODE=ok

# Simulate a crash after in_flight persistence and ensure duplicate does not send.
STATE_MANIFEST_PATH="$TEST_STATE_HOME/herdr-skill/teams/${STATE_TEAM_ID}.json"
jq -c '.prompt_history.impl["crash-window"] = {status:"in_flight",was_deferred:false}' "$STATE_MANIFEST_PATH" > "$STATE_MANIFEST_PATH.crash"
mv "$STATE_MANIFEST_PATH.crash" "$STATE_MANIFEST_PATH"
CRASH_COUNT_BEFORE=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
CRASH_RESULT=$(echo "{\"request_id\":\"crash-window\",\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"impl\",\"text\":\"must not send\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
CRASH_COUNT_AFTER=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
assert_ok "$CRASH_RESULT" '.status == "unknown_outcome" and .data.delivery_status == "in_flight"' "in_flight crash window returns unknown_outcome"
if [ "$CRASH_COUNT_BEFORE" -eq "$CRASH_COUNT_AFTER" ]; then
  echo "PASS: in_flight crash window suppresses duplicate external send"
  PASS=$((PASS + 1))
else
  echo "FAIL: crash-window retry sent external prompt"
  FAIL=$((FAIL + 1))
fi

# --- Wait/read real-envelope classification ---
echo "--- Wait and Read Envelope Classification ---"
for WAIT_MODE in ok timeout fail empty malformed; do
  export FAKE_WAIT_MODE="$WAIT_MODE"
  WAIT_RESULT=$(echo "{\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait 2>&1 || true)
  case "$WAIT_MODE" in
    ok) WAIT_CHECK='.status == "ok" and .data.agent_status == "completed"' ;;
    timeout) WAIT_CHECK='.status == "waiting"' ;;
    fail) WAIT_CHECK='.status == "failed" and .error.code == "WAIT_FAILED"' ;;
    *) WAIT_CHECK='.status == "unknown_outcome" and .data.agent_status == "unknown"' ;;
  esac
  assert_ok "$WAIT_RESULT" "$WAIT_CHECK" "member.wait classifies $WAIT_MODE envelope"
  assert_single_json "$WAIT_RESULT" "member.wait $WAIT_MODE returns one JSON envelope"
done
unset FAKE_WAIT_MODE

export FAKE_READ_MODE=fail
assert_ok "$(echo "{\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"impl\"}" | bash "$HERDR_SCRIPT" member.read 2>&1 || true)" '.status == "failed" and .error.code == "READ_FAILED"' "member.read explicit failure is not ok"
export FAKE_READ_MODE=unknown
assert_ok "$(echo "{\"team_id\":\"$STATE_TEAM_ID\",\"role\":\"impl\"}" | bash "$HERDR_SCRIPT" member.read 2>&1 || true)" '.status == "unknown_outcome"' "member.read transport failure is unknown"
unset FAKE_READ_MODE

# --- Partial close retry and final manifest cleanup ---
echo "--- Close Retry Regressions ---"
cleanup_fake_state
MEMBER_RETRY_TEAM=$(echo '{"request_id":"member-close-retry-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
MEMBER_RETRY_ID=$(jq -r '.data.team_id' <<< "$MEMBER_RETRY_TEAM")
export FAKE_CLOSE_MODE=fail
MEMBER_CLOSE_FAILED=$(echo "{\"team_id\":\"$MEMBER_RETRY_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close 2>&1 || true)
assert_ok "$MEMBER_CLOSE_FAILED" '.status == "failed" and .data.outcome == "failed"' "member.close records explicit failure"
export FAKE_CLOSE_MODE=ok
assert_ok "$(echo "{\"team_id\":\"$MEMBER_RETRY_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "ok" and .data.closed == true' "member.close retries explicit failure"
export FAKE_CLOSE_MODE=unknown
MEMBER_CLOSE_UNKNOWN=$(echo "{\"team_id\":\"$MEMBER_RETRY_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)
assert_ok "$MEMBER_CLOSE_UNKNOWN" '.status == "unknown_outcome" and .data.outcome == "unknown"' "member.close records unknown outcome"
export FAKE_CLOSE_MODE=ok
assert_ok "$(echo "{\"team_id\":\"$MEMBER_RETRY_ID\",\"role\":\"review\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)" '.status == "ok" and .data.closed == true' "member.close retries unknown outcome"
echo "{\"team_id\":\"$MEMBER_RETRY_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop >/dev/null
unset FAKE_CLOSE_MODE

cleanup_fake_state
CLOSE_TEAM=$(echo '{"request_id":"close-mixed-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
CLOSE_TEAM_ID=$(jq -r '.data.team_id' <<< "$CLOSE_TEAM")
export FAKE_CLOSE_MODE=mixed
MIXED_STOP=$(echo "{\"team_id\":\"$CLOSE_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop 2>&1 || true)
assert_ok "$MIXED_STOP" '.status == "unknown_outcome" and (.data.stopped_members | index("impl") != null) and (.data.failed_members | length == 1) and (.data.unknown_members | length == 1)' "team.stop distinguishes closed, failed, and unknown members"
PANE1_CLOSE_COUNT_BEFORE=$(grep -c '^fake-pane-1$' "$FAKE_STATE_DIR/close_invocations.log" || true)
export FAKE_CLOSE_MODE=ok
RETRY_STOP=$(echo "{\"team_id\":\"$CLOSE_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)
PANE1_CLOSE_COUNT_AFTER=$(grep -c '^fake-pane-1$' "$FAKE_STATE_DIR/close_invocations.log" || true)
assert_ok "$RETRY_STOP" '.status == "ok"' "team.stop retries failed and unknown members"
if [ "$PANE1_CLOSE_COUNT_BEFORE" -eq 1 ] && [ "$PANE1_CLOSE_COUNT_AFTER" -eq 1 ]; then
  echo "PASS: confirmed closed member is not closed again"
  PASS=$((PASS + 1))
else
  echo "FAIL: confirmed closed member was retried"
  FAIL=$((FAIL + 1))
fi
unset FAKE_CLOSE_MODE

cleanup_fake_state
ALL_CLOSED_TEAM=$(echo '{"request_id":"all-closed-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
ALL_CLOSED_ID=$(jq -r '.data.team_id' <<< "$ALL_CLOSED_TEAM")
for CLOSE_ROLE in impl review pr-fix; do
  echo "{\"team_id\":\"$ALL_CLOSED_ID\",\"role\":\"$CLOSE_ROLE\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close >/dev/null
done
ALL_CLOSED_STOP=$(echo "{\"team_id\":\"$ALL_CLOSED_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop)
assert_ok "$ALL_CLOSED_STOP" '.status == "already_applied" and .data.manifest_removed == true' "team.stop removes manifest after all member.close calls"
if [ ! -f "$TEST_STATE_HOME/herdr-skill/teams/${ALL_CLOSED_ID}.json" ]; then
  echo "PASS: all-closed team manifest is gone"
  PASS=$((PASS + 1))
else
  echo "FAIL: all-closed team manifest remains"
  FAIL=$((FAIL + 1))
fi

# --- Regression Tests (PR #44) ---
echo "--- Regression: Fix 1 - Prompt timeout persists unknown_outcome ---"
cleanup_fake_state
TIMEOUT_TEAM=$(echo '{"request_id":"timeout-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
TIMEOUT_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$TIMEOUT_TEAM")
echo "timeout team: $TIMEOUT_TEAM_ID"

export FAKE_PROMPT_MODE=timeout
TIMEOUT_COUNT_BEFORE=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
TIMEOUT_PROMPT=$(echo "{\"request_id\":\"timeout-001\",\"team_id\":\"$TIMEOUT_TEAM_ID\",\"role\":\"impl\",\"text\":\"timeout test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
assert_ok "$TIMEOUT_PROMPT" '.status == "unknown_outcome" and .data.delivery_status == "unknown"' "prompt timeout returns unknown_outcome, not failed"
TIMEOUT_COUNT_AFTER=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
if [ "$TIMEOUT_COUNT_AFTER" -eq $((TIMEOUT_COUNT_BEFORE + 1)) ]; then
  echo "PASS: timeout prompt invokes external send once"
  PASS=$((PASS + 1))
else
  echo "FAIL: timeout prompt invocation count before=$TIMEOUT_COUNT_BEFORE after=$TIMEOUT_COUNT_AFTER"
  FAIL=$((FAIL + 1))
fi
TIMEOUT_COUNT_BEFORE2=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
TIMEOUT_RETRY=$(echo "{\"request_id\":\"timeout-001\",\"team_id\":\"$TIMEOUT_TEAM_ID\",\"role\":\"impl\",\"text\":\"timeout test\",\"grant\":\"write\"}" | bash "$HERDR_SCRIPT" member.prompt)
TIMEOUT_COUNT_AFTER2=$(wc -l < "$FAKE_STATE_DIR/prompt_invocations.log")
assert_ok "$TIMEOUT_RETRY" '.status == "unknown_outcome" and .data.delivery_status == "unknown"' "prompt timeout retry returns unknown_outcome, not re-sent"
if [ "$TIMEOUT_COUNT_AFTER2" -eq "$TIMEOUT_COUNT_BEFORE2" ]; then
  echo "PASS: timeout retry does not re-send external prompt"
  PASS=$((PASS + 1))
else
  echo "FAIL: timeout retry re-sent external prompt"
  FAIL=$((FAIL + 1))
fi
export FAKE_PROMPT_MODE=ok

echo "--- Regression: Fix 1b - kickoff prompt timeout persists unknown, no rollback ---"
cleanup_fake_state
export FAKE_PROMPT_MODE=timeout
KICKOFF_TIMEOUT=$(echo '{"request_id":"kickoff-timeout","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$KICKOFF_TIMEOUT" '.status == "unknown_outcome" and .data.phase == "kickoff.prompt"' "kickoff prompt timeout returns unknown_outcome, not failed"
KICKOFF_TIMEOUT_ID=$(jq -r '.data.team_id // ""' <<< "$KICKOFF_TIMEOUT")
KICKOFF_MANIFEST=$(echo "{\"team_id\":\"$KICKOFF_TIMEOUT_ID\"}" | bash "$HERDR_SCRIPT" team.get)
assert_ok "$KICKOFF_MANIFEST" '.status == "ok" and .data.members[0].status == "active"' "unknown kickoff persists panes (no dangerous rollback)"
KICKOFF_RETRY=$(echo '{"request_id":"kickoff-timeout","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
assert_ok "$KICKOFF_RETRY" '.status == "unknown_outcome"' "unknown kickoff retry blocked, not replayed"
export FAKE_PROMPT_MODE=ok

echo "--- Regression: Fix 2 - close unknown then pane_not_found converges to closed ---"
cleanup_fake_state
PANENF_TEAM=$(echo '{"request_id":"panenf-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
PANENF_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$PANENF_TEAM")
export FAKE_CLOSE_MODE=unknown
PANENF_UNKNOWN=$(echo "{\"team_id\":\"$PANENF_TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)
assert_ok "$PANENF_UNKNOWN" '.status == "unknown_outcome"' "first close returns unknown_outcome"
export FAKE_CLOSE_MODE=not_found
PANENF_RETRY=$(echo "{\"team_id\":\"$PANENF_TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)
assert_ok "$PANENF_RETRY" '.status == "ok" and .data.closed == true and .data.outcome == "ok"' "close retry with pane_not_found converges to closed with outcome normalized to ok"
PANENF_MANIFEST=$(echo "{\"team_id\":\"$PANENF_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get)
assert_ok "$PANENF_MANIFEST" '.data.members[] | select(.role == "impl") | .status == "closed"' "manifest shows member as closed after not_found convergence"
unset FAKE_CLOSE_MODE

echo "--- Regression: Fix 2b - team.stop pane_not_found convergence ---"
cleanup_fake_state
TSNF_TEAM=$(echo '{"request_id":"tsnf-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
TSNF_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$TSNF_TEAM")
TSNF_PANE=$(echo "{\"team_id\":\"$TSNF_TEAM_ID\"}" | bash "$HERDR_SCRIPT" team.get | jq -r '.data.members[0].pane_id // ""')
MANIFEST_PATH="$TEST_STATE_HOME/herdr-skill/teams/${TSNF_TEAM_ID}.json"
jq -c --arg role impl '.members = [.members[] | if .role == $role then .status = "close-unknown" else . end]' "$MANIFEST_PATH" > "$MANIFEST_PATH.fix" && mv "$MANIFEST_PATH.fix" "$MANIFEST_PATH"
export FAKE_CLOSE_MODE=not_found
TSNF_STOP=$(echo "{\"team_id\":\"$TSNF_TEAM_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop 2>&1 || true)
assert_ok "$TSNF_STOP" '.status == "ok"' "team.stop with pane_not_found converges to ok"
unset FAKE_CLOSE_MODE

echo "--- Regression: Fix 3 - member.wait unknown status returns unknown_outcome ---"
cleanup_fake_state
WAITSTAT_TEAM=$(echo '{"request_id":"waitstat-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
WAITSTAT_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$WAITSTAT_TEAM")
export FAKE_WAIT_MODE=unknown_status
WAITSTAT_UNKNOWN=$(echo "{\"team_id\":\"$WAITSTAT_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait)
assert_ok "$WAITSTAT_UNKNOWN" '.status == "unknown_outcome" and .data.agent_status == "unknown"' "unknown_status envelope returns unknown_outcome, not completed"
assert_single_json "$WAITSTAT_UNKNOWN" "unknown_status wait returns one JSON envelope"
export FAKE_WAIT_MODE=missing_status
WAITSTAT_MISSING=$(echo "{\"team_id\":\"$WAITSTAT_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait)
assert_ok "$WAITSTAT_MISSING" '.status == "unknown_outcome" and .data.agent_status == "unknown"' "missing_status envelope returns unknown_outcome, not completed"
assert_single_json "$WAITSTAT_MISSING" "missing_status wait returns one JSON envelope"
unset FAKE_WAIT_MODE

echo "--- Regression: Fix 3b - empty string status no longer classified as completed ---"
cleanup_fake_state
EMPTYSTAT_TEAM=$(echo '{"request_id":"emptystat-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
EMPTYSTAT_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$EMPTYSTAT_TEAM")
export FAKE_WAIT_MODE=missing_status
EMPTYSTAT_RESULT=$(echo "{\"team_id\":\"$EMPTYSTAT_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait)
assert_ok "$EMPTYSTAT_RESULT" '.status == "unknown_outcome"' "missing status is not classified as completed"
unset FAKE_WAIT_MODE

echo "--- Regression: Fix 1c - result.type fallback removed (codex-review-2) ---"
cleanup_fake_state
TYPEOK_TEAM=$(echo '{"request_id":"typeok-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
TYPEOK_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$TYPEOK_TEAM")
export FAKE_WAIT_MODE=type_ok
TYPEOK_RESULT=$(echo "{\"team_id\":\"$TYPEOK_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait)
assert_ok "$TYPEOK_RESULT" '.status == "unknown_outcome" and .data.agent_status == "unknown"' "result.type=ok without agent.status is unknown_outcome"
assert_single_json "$TYPEOK_RESULT" "result.type=ok returns one JSON envelope"
export FAKE_WAIT_MODE=type_completed
TYPECOMP_RESULT=$(echo "{\"team_id\":\"$TYPEOK_TEAM_ID\",\"role\":\"impl\",\"timeout\":1000}" | bash "$HERDR_SCRIPT" member.wait)
assert_ok "$TYPECOMP_RESULT" '.status == "unknown_outcome" and .data.agent_status == "unknown"' "result.type=completed without result.status is unknown_outcome"
assert_single_json "$TYPECOMP_RESULT" "result.type=completed returns one JSON envelope"
unset FAKE_WAIT_MODE

echo "--- Regression: Fix 2c - pane_not_found outcome normalization consistency ---"
cleanup_fake_state
PANECONSIST_TEAM=$(echo '{"request_id":"paneconsist-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
PANECONSIST_TEAM_ID=$(jq -r '.data.team_id // ""' <<< "$PANECONSIST_TEAM")
export FAKE_CLOSE_MODE=unknown
echo "{\"team_id\":\"$PANECONSIST_TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close >/dev/null
export FAKE_CLOSE_MODE=not_found
PANECONSIST_RETRY=$(echo "{\"team_id\":\"$PANECONSIST_TEAM_ID\",\"role\":\"impl\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" member.close)
assert_ok "$PANECONSIST_RETRY" '.status == "ok" and .data.closed == true and .data.outcome == "ok"' "member.close outcome normalized to ok when closed==true"
unset FAKE_CLOSE_MODE
# Verify team.stop also produces consistent outcome for pane_not_found
PANECONSIST_TEAM2=$(echo '{"request_id":"paneconsist2-team","grant":"write"}' | bash "$HERDR_SCRIPT" team.start)
PANECONSIST_TEAM2_ID=$(jq -r '.data.team_id // ""' <<< "$PANECONSIST_TEAM2")
MANIFEST_PATH2="$TEST_STATE_HOME/herdr-skill/teams/${PANECONSIST_TEAM2_ID}.json"
jq -c '.members[0].status = "close-unknown"' "$MANIFEST_PATH2" > "$MANIFEST_PATH2.fix" && mv "$MANIFEST_PATH2.fix" "$MANIFEST_PATH2"
export FAKE_CLOSE_MODE=not_found
PANECONSIST_STOP=$(echo "{\"team_id\":\"$PANECONSIST_TEAM2_ID\",\"grant\":\"sensitive-write\"}" | bash "$HERDR_SCRIPT" team.stop 2>&1 || true)
assert_ok "$PANECONSIST_STOP" '.status == "ok" and (.data.stopped_members | index("impl") != null)' "team.stop result outcome normalized for pane_not_found"
unset FAKE_CLOSE_MODE

# --- Regression: Prompt safe-stop contracts (Issue #46) ---
echo "--- Prompt Safe-Stop Contracts ---"
ORCHESTRATOR_MD="$HERDR_DIR/prompts/orchestrator.md"
SKILL_MD="$HERDR_DIR/SKILL.md"

# orchestrator.md: status branching table exists
if grep -q '| `"ok"`' "$ORCHESTRATOR_MD" && \
   grep -q '| `"already_applied"`' "$ORCHESTRATOR_MD" && \
   grep -q '| `"failed"`' "$ORCHESTRATOR_MD" && \
   grep -q '| `"unknown_outcome"`' "$ORCHESTRATOR_MD"; then
  echo "PASS: orchestrator.md has all four status branches"
  PASS=$((PASS + 1))
else
  echo "FAIL: orchestrator.md missing one or more status branches"
  FAIL=$((FAIL + 1))
fi

# orchestrator.md: failed/unknown_outcome prohibits parent-agent implementation fallback
if grep -q '親エージェント直接実装フォールバック禁止' "$ORCHESTRATOR_MD"; then
  echo "PASS: orchestrator.md prohibits parent-agent direct-implementation fallback"
  PASS=$((PASS + 1))
else
  echo "FAIL: orchestrator.md missing parent-agent fallback prohibition"
  FAIL=$((FAIL + 1))
fi

# orchestrator.md: prohibits auto-execution of team.stop/member.close on failure/unknown
if grep -q 'team.stop.*member.close.*自動実行してはならない' "$ORCHESTRATOR_MD" && \
   grep -q 'sensitive-write.*自己判断で付与しない' "$ORCHESTRATOR_MD"; then
  echo "PASS: orchestrator.md prohibits auto cleanup and sensitive-write self-grant on failure"
  PASS=$((PASS + 1))
else
  echo "FAIL: orchestrator.md missing cleanup prohibition or sensitive-write self-grant prohibition"
  FAIL=$((FAIL + 1))
fi

# orchestrator.md: prohibits diagnosing unconfirmed failure causes
if grep -q '未確認の失敗原因を断定してはならない' "$ORCHESTRATOR_MD"; then
  echo "PASS: orchestrator.md prohibits diagnosing unconfirmed failure causes"
  PASS=$((PASS + 1))
else
  echo "FAIL: orchestrator.md missing unconfirmed cause diagnosis prohibition"
  FAIL=$((FAIL + 1))
fi

# orchestrator.md: requires reporting team_id, phase, role, member status on failure
if grep -q 'team_id.*phase.*role.*member.*status' "$ORCHESTRATOR_MD" || \
   grep -q '以下の情報をユーザーに報告する.*team_id.*phase.*role.*status' "$ORCHESTRATOR_MD"; then
  echo "PASS: orchestrator.md requires reporting team_id, phase, role, member status"
  PASS=$((PASS + 1))
else
  echo "FAIL: orchestrator.md missing reporting contract for team_id/phase/role/status"
  FAIL=$((FAIL + 1))
fi

# SKILL.md: has Safe-stop section
if grep -q 'Safe-stop on team.start' "$SKILL_MD"; then
  echo "PASS: SKILL.md has Safe-stop on team.start section"
  PASS=$((PASS + 1))
else
  echo "FAIL: SKILL.md missing Safe-stop on team.start section"
  FAIL=$((FAIL + 1))
fi

# SKILL.md: same cleanup prohibition
if grep -q 'team.stop.*member.close.*自動実行してはならない' "$SKILL_MD" && \
   grep -q 'sensitive-write.*自己判断で付与しない' "$SKILL_MD"; then
  echo "PASS: SKILL.md prohibits auto cleanup and sensitive-write self-grant"
  PASS=$((PASS + 1))
else
  echo "FAIL: SKILL.md missing cleanup prohibition"
  FAIL=$((FAIL + 1))
fi

# SKILL.md: prohibits diagnosing unconfirmed failure causes
if grep -q '未確認の失敗原因を断定してはならない' "$SKILL_MD"; then
  echo "PASS: SKILL.md prohibits diagnosing unconfirmed failure causes"
  PASS=$((PASS + 1))
else
  echo "FAIL: SKILL.md missing unconfirmed cause diagnosis prohibition"
  FAIL=$((FAIL + 1))
fi

# SKILL.md: requires reporting contract
if grep -q 'team_id.*phase.*role.*member.*status' "$SKILL_MD" || \
   grep -q '以下の情報をユーザーに報告する.*team_id.*phase.*role.*status' "$SKILL_MD"; then
  echo "PASS: SKILL.md requires reporting team_id, phase, role, member status"
  PASS=$((PASS + 1))
else
  echo "FAIL: SKILL.md missing reporting contract"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
