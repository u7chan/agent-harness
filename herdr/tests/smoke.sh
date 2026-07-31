#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"
HERDR_SCRIPT="$HERDR_DIR/scripts/herdr.sh"
FAKE_HERDR="$HERDR_DIR/tests/fake_herdr.sh"

TEST_STATE_HOME="$(mktemp -d /tmp/herdr-smoke-state-XXXXXX)"
FAKE_BIN_DIR="$(mktemp -d /tmp/herdr-fake-bin-XXXXXX)"
export XDG_STATE_HOME="$TEST_STATE_HOME"
export FAKE_STATE_DIR="$TEST_STATE_HOME/fake-state"
export HERDR_ENV=1 HERDR_PANE_ID=pane-1 HERDR_TAB_ID=tab-1 HERDR_WORKSPACE_ID=ws-fake-001
export PATH="$FAKE_BIN_DIR:$PATH"
printf '%s\n' '#!/usr/bin/env bash' "exec bash \"$FAKE_HERDR\" \"\$@\"" > "$FAKE_BIN_DIR/herdr"
chmod +x "$FAKE_BIN_DIR/herdr"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$FAKE_BIN_DIR" "$TEST_STATE_HOME"
}
trap cleanup EXIT

cleanup_state() {
  rm -rf "$FAKE_STATE_DIR" "$TEST_STATE_HOME/herdr-skill/teams"
  mkdir -p "$FAKE_STATE_DIR"
  unset FAKE_SPLIT_MODE FAKE_LIST_MODE FAKE_LAYOUT_MODE FAKE_AGENT_START_MODE FAKE_CLOSE_MODE FAKE_AGENT_KIND FAKE_PANE_GET_BUSY_COUNT
  export FAKE_TERMINAL_COLS=240 FAKE_TERMINAL_ROWS=40
}

assert_ok() {
  local result="$1" check="$2" name="$3"
  if jq -e "$check" >/dev/null 2>&1 <<< "$result"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name"; echo "  got: $(printf '%s' "$result" | jq -c '.' 2>/dev/null || printf '%s' "$result")"; FAIL=$((FAIL + 1))
  fi
}

assert_equal() {
  local actual="$1" expected="$2" name="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected=$expected actual=$actual)"; FAIL=$((FAIL + 1))
  fi
}

TEST_ORIGIN_KIND="opencode"

run_herdr() {
  bash "$HERDR_SCRIPT" "$@" 2>&1 || true
}

mk_start_input() {
  local req_id="$1" cfg="$2" kind="${3:-$TEST_ORIGIN_KIND}"
  if [ -z "$kind" ]; then
    jq -nc --arg request_id "$req_id" --arg config_path "$cfg" --arg grant "write" \
      '{request_id:$request_id,config_path:$config_path,grant:$grant}'
  else
    jq -nc --arg request_id "$req_id" --arg config_path "$cfg" --arg origin_kind "$kind" --arg grant "write" \
      '{request_id:$request_id,config_path:$config_path,origin_kind:$origin_kind,grant:$grant}'
  fi
}

echo "=== Herdr Grid Smoke Tests ==="

echo "--- Pure Planner ---"
PLAN_INPUT='{"member_count":5,"max_cols":3,"target_cols":240,"target_rows":40}'
PLAN_ONE="$(printf '%s\n' "$PLAN_INPUT" | bash "$HERDR_DIR/scripts/common/layout_plan.sh")"
PLAN_TWO="$(printf '%s\n' "$PLAN_INPUT" | bash "$HERDR_DIR/scripts/common/layout_plan.sh")"
assert_equal "$PLAN_ONE" "$PLAN_TWO" "planner is byte deterministic"
assert_ok "$PLAN_ONE" '.status == "ok" and .resolved_cols == 3 and .resolved_rows == 2 and .geometry.orch_cols == 57 and .geometry.row_heights == [20,19] and .geometry.row_widths[1] == [91,90]' "five-member plan selects 3x2 Grid"
assert_ok "$PLAN_ONE" '([.splits[].target_ref] | index("orch") != null) and all(.splits[]; .direction == "right" or .direction == "down")' "planner emits logical split refs and directions"
assert_ok "$(printf '%s\n' '{"member_count":3,"max_cols":3,"target_cols":100,"target_rows":40}' | bash "$HERDR_DIR/scripts/common/layout_plan.sh")" '.status == "failed" and .error.code == "LAYOUT_NOT_FEASIBLE"' "planner rejects infeasible geometry"

echo "--- Config and Normal Apply ---"
cleanup_state
TEAM_RESULT="$(mk_start_input smoke-grid-001 herdr/team.json | run_herdr team.start)"
assert_ok "$TEAM_RESULT" '.status == "ok" and .data.layout.status == "applied" and (.data.members | length) == 3' "team.start applies Grid before agents"
TEAM_ID="$(jq -r '.data.team_id // empty' <<< "$TEAM_RESULT")"
MANIFEST="$(printf '%s\n' "{\"team_id\":\"$TEAM_ID\"}" | run_herdr team.get)"
assert_ok "$MANIFEST" '.data.layout.steps | length == 3 and all(.[]; .status == "applied")' "manifest records every verified split"
assert_ok "$MANIFEST" '.data.layout.refs["orch"] == "pane-1" and ([.data.members[].pane_id] | unique | length) == 3' "logical refs bind to distinct member panes"
assert_ok "$(jq -sc '[.[] | .command] | {commands:.}' "$FAKE_STATE_DIR/commands.jsonl")" '.commands | index("agent.start") > index("pane.split")' "agent start occurs after split phase"
assert_ok "$(jq -s '[.[] | select(.command == "pane.split")]' "$FAKE_STATE_DIR/commands.jsonl")" 'all(.[]; (.args | index("--pane")) != null and (.args | index("--current")) != null and (.args[(.args | index("--current"))+1] == "false"))' "Grid split uses explicit pane IDs without current"

echo "--- Five Member Grid ---"
GRID_CONFIG_DIR="$TEST_STATE_HOME/grid-config"
mkdir -p "$GRID_CONFIG_DIR"
printf '%s\n' 'extra role' > "$GRID_CONFIG_DIR/extra.md"
printf '%s\n' '{"schema_version":2,"layout":{"max_cols":3},"members":[{"role":"impl"},{"role":"review"},{"role":"pr-fix"},{"role":"extra-a","prompt_file":"extra.md"},{"role":"extra-b","prompt_file":"extra.md"}]}' > "$GRID_CONFIG_DIR/team.json"
cleanup_state
FIVE_RESULT="$(mk_start_input smoke-grid-five "$GRID_CONFIG_DIR/team.json" | run_herdr team.start)"
assert_ok "$FIVE_RESULT" '.status == "ok" and .data.layout.resolved_cols == 3 and (.data.members | length) == 5' "five-member Grid starts successfully"
assert_equal "$(jq -s '[.[] | select(.command == "pane.split")] | length' "$FAKE_STATE_DIR/commands.jsonl")" "5" "five-member Grid uses five deterministic splits"

echo "--- v2 Config Rejection ---"
V1_CONFIG="$TEST_STATE_HOME/v1-team.json"
printf '%s\n' '{"schema_version":1,"members":[{"role":"impl"}]}' > "$V1_CONFIG"
cleanup_state
V1_RESULT="$(mk_start_input smoke-v1-reject "$V1_CONFIG" | run_herdr team.start)"
assert_ok "$V1_RESULT" '.status == "failed" and .error.code == "CONFIG_ERROR"' "schema_version 1 is rejected"
assert_equal "$(if [ -f "$FAKE_STATE_DIR/commands.jsonl" ]; then jq -s '[.[] | select(.command == "pane.split")] | length' "$FAKE_STATE_DIR/commands.jsonl"; else echo 0; fi)" "0" "invalid config does not split panes"

echo "--- Infeasible Layout ---"
cleanup_state
export FAKE_TERMINAL_COLS=100
INFEASIBLE="$(mk_start_input smoke-infeasible herdr/team.json | run_herdr team.start)"
assert_ok "$INFEASIBLE" '.status == "failed" and .error.code == "LAYOUT_NOT_FEASIBLE" and .data.plan.error.code == "LAYOUT_NOT_FEASIBLE"' "infeasible Grid returns structured failure"
assert_equal "$(if [ -f "$FAKE_STATE_DIR/commands.jsonl" ]; then jq -s '[.[] | select(.command == "pane.split")] | length' "$FAKE_STATE_DIR/commands.jsonl"; else echo 0; fi)" "0" "infeasible Grid never calls pane split"

echo "--- Unknown Recovery and Safe Stop ---"
cleanup_state
export FAKE_SPLIT_MODE=unknown
RECOVERED="$(mk_start_input smoke-recover herdr/team.json | run_herdr team.start)"
assert_ok "$RECOVERED" '.status == "ok" and .data.layout.status == "applied"' "missing split response is recovered from read-only snapshots"
RECOVERED_ID="$(jq -r '.data.team_id' <<< "$RECOVERED")"
RECOVERED_MANIFEST="$(printf '%s\n' "{\"team_id\":\"$RECOVERED_ID\"}" | run_herdr team.get)"
assert_ok "$RECOVERED_MANIFEST" 'all(.data.layout.steps[]; .recovered_from_unknown == true)' "recovered steps are recorded"

cleanup_state
export FAKE_SPLIT_MODE=no-op-unknown
STOPPED="$(mk_start_input smoke-safe-stop herdr/team.json | run_herdr team.start)"
assert_ok "$STOPPED" '.status == "unknown_outcome" and .data.cleanup_complete == false' "ambiguous split stops safely"
STOPPED_ID="$(jq -r '.data.team_id' <<< "$STOPPED")"
assert_equal "$(if [ -f "$FAKE_STATE_DIR/commands.jsonl" ]; then jq -s '[.[] | select(.command == "agent.start")] | length' "$FAKE_STATE_DIR/commands.jsonl"; else echo 0; fi)" "0" "unknown outcome does not start agents"
assert_equal "$(if [ -f "$FAKE_STATE_DIR/close_invocations.log" ]; then wc -l < "$FAKE_STATE_DIR/close_invocations.log"; else echo 0; fi)" "0" "unknown outcome does not auto-close panes"
assert_ok "$(printf '%s\n' "{\"team_id\":\"$STOPPED_ID\"}" | run_herdr team.get)" '.data.status == "unknown_outcome" and .data.layout.cleanup_complete == false and .data.layout.steps[0].status == "in_flight"' "unknown manifest is retained with in-flight step"

cleanup_state
export FAKE_SPLIT_MODE=extra
CONFLICT="$(mk_start_input smoke-conflict-extra herdr/team.json | run_herdr team.start)"
assert_ok "$CONFLICT" '.status == "unknown_outcome" and .data.cleanup_complete == false' "multiple new panes are not auto-recovered"

cleanup_state
export FAKE_SPLIT_MODE=other-change
CONFLICT_OTHER="$(mk_start_input smoke-conflict-other herdr/team.json | run_herdr team.start)"
assert_ok "$CONFLICT_OTHER" '.status == "unknown_outcome" and .data.cleanup_complete == false' "unrelated pane change is not auto-recovered"

cleanup_state
export FAKE_SPLIT_MODE=topo-change
TOPO_CHANGE="$(mk_start_input smoke-topo-change herdr/team.json | run_herdr team.start)"
assert_ok "$TOPO_CHANGE" '.status == "unknown_outcome"' "topology change on non-target pane is detected"

echo "--- Known Failure Rollback ---"
cleanup_state
export FAKE_AGENT_START_MODE=fail
ROLLBACK="$(mk_start_input smoke-rollback herdr/team.json | run_herdr team.start)"
assert_ok "$ROLLBACK" '.status == "failed" and .error.code == "AGENT_START_FAILED" and .data.cleanup_complete == true' "known agent failure rolls back created panes"
assert_equal "$(if [ -f "$FAKE_STATE_DIR/close_invocations.log" ]; then wc -l < "$FAKE_STATE_DIR/close_invocations.log"; else echo 0; fi)" "3" "rollback closes only created member panes"

echo "--- Capability and Catalog Regression ---"
cleanup_state
assert_ok "$(run_herdr actions.list)" '.status == "ok" and (.data | type == "array")' "actions.list remains available"
unset HERDR_ENV
assert_ok "$(printf '%s\n' '{"request_id":"smoke-no-env","config_path":"herdr/team.json","origin_kind":"opencode","grant":"write"}' | run_herdr team.start)" '.status == "failed" and .error.code == "HERDR_CAPABILITY_MISSING"' "team.start requires Herdr environment identity"
export HERDR_ENV=1

echo "--- Single and Dual Member Grids ---"
ONE_MEMBER_CONFIG="$(mktemp /tmp/herdr-one-member-XXXXXX.json)"
printf '%s\n' '{"schema_version":2,"layout":{"max_cols":3},"members":[{"role":"impl"}]}' > "$ONE_MEMBER_CONFIG"
cleanup_state
ONE_RESULT="$(mk_start_input smoke-grid-one "$ONE_MEMBER_CONFIG" | run_herdr team.start)"
assert_ok "$ONE_RESULT" '.status == "ok" and .data.layout.status == "applied" and (.data.members | length) == 1' "single-member Grid starts successfully"
assert_equal "$(jq -s '[.[] | select(.command == "pane.split")] | length' "$FAKE_STATE_DIR/commands.jsonl")" "1" "single-member uses one split (orch only)"
assert_ok "$(printf '%s\n' "{\"team_id\":\"$(jq -r '.data.team_id' <<< "$ONE_RESULT")\"}" | run_herdr team.get)" '([.data.members[] | .status] | all(. == "active" or . == "pane-created"))' "single-member binds and activates"
rm -f "$ONE_MEMBER_CONFIG"

TWO_MEMBER_CONFIG="$(mktemp /tmp/herdr-two-member-XXXXXX.json)"
printf '%s\n' '{"schema_version":2,"layout":{"max_cols":2},"members":[{"role":"impl"},{"role":"review"}]}' > "$TWO_MEMBER_CONFIG"
cleanup_state
TWO_RESULT="$(mk_start_input smoke-grid-two "$TWO_MEMBER_CONFIG" | run_herdr team.start)"
assert_ok "$TWO_RESULT" '.status == "ok" and .data.layout.status == "applied" and (.data.members | length) == 2' "dual-member Grid starts successfully"
assert_equal "$(jq -s '[.[] | select(.command == "pane.split")] | length' "$FAKE_STATE_DIR/commands.jsonl")" "2" "dual-member uses two splits (orch + one column)"
rm -f "$TWO_MEMBER_CONFIG"

echo "--- Origin Kind Auto-Detection ---"
cleanup_state
NO_ORIGIN_INPUT="$(mk_start_input smoke-autodetect herdr/team.json "")"
AUTODETECT="$(run_herdr team.start <<< "$NO_ORIGIN_INPUT")"
assert_ok "$AUTODETECT" '.status == "ok" and .data.layout.status == "applied"' "origin_kind auto-detected from root pane agent_kind"

cleanup_state
echo "--- Detection Logic Unit Test ---"
export FAKE_AGENT_KIND=""
source "$HERDR_DIR/scripts/common/herdr_cli.sh"
DETECT_RESULT="$(herdr_cli_detect_agent_kind pane-1)"
assert_equal "$DETECT_RESULT" "" "detect returns empty when pane has no agent_kind"
unset FAKE_AGENT_KIND

echo "--- Missing Origin Kind (No Env) ---"
cleanup_state
NO_ORIGIN="$(printf '%s\n' '{"request_id":"smoke-no-origin","config_path":"herdr/team.json","grant":"write"}' | run_herdr team.start)"
assert_ok "$NO_ORIGIN" '.status == "ok" and .data.layout.status == "applied"' "missing origin_kind works via auto-detection"

echo "--- LAYOUT_NOT_FEASIBLE Duplicate Retry ---"
cleanup_state
export FAKE_TERMINAL_COLS=100
RETRY1="$(mk_start_input smoke-dupe-infeasible herdr/team.json | run_herdr team.start)"
assert_ok "$RETRY1" '.status == "failed" and .error.code == "LAYOUT_NOT_FEASIBLE"' "first infeasible fails cleanly"
RETRY2="$(mk_start_input smoke-dupe-infeasible herdr/team.json | run_herdr team.start)"
assert_ok "$RETRY2" '.status == "already_applied"' "infeasible duplicate returns already_applied"

echo "--- Manifest Persist Failure ---"
cleanup_state
PLAN="$(printf '%s\n' '{"member_count":3,"max_cols":3,"target_cols":240,"target_rows":40}' | bash "$HERDR_DIR/scripts/common/layout_plan.sh")"
APPLY_INPUT="$(jq -nc --arg team_id "nonexistent-team-99999" --argjson plan "$(jq -c '.' <<< "$PLAN")" \
    --arg root_pane_id "pane-1" --arg workspace_id "ws-fake-001" --argjson timeout_ms 30000 \
    '{team_id:$team_id,plan:$plan,root_pane_id:$root_pane_id,workspace_id:$workspace_id,timeout_ms:$timeout_ms}')"
APPLY_RESULT="$(printf '%s\n' "$APPLY_INPUT" | bash "$HERDR_DIR/scripts/common/layout_apply.sh")"
assert_ok "$APPLY_RESULT" '.status == "failed" and .code == "MANIFEST_PERSIST_FAILED"' "missing manifest triggers MANIFEST_PERSIST_FAILED"

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
