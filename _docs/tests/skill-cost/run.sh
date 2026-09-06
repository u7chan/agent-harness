#!/usr/bin/env bash
# Fixture-based tests for the offline skill-cost analyzer (_docs/scripts/skill-cost.py).
# Fixtures are fully synthetic; no real session fragments are committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../scripts/skill-cost.py"
FIXTURES="$SCRIPT_DIR/fixtures"
ORCH="$FIXTURES/session-orchestrator.jsonl"
CHILD="$FIXTURES/session-child.jsonl"
TEST_TMP="$(mktemp -d /tmp/skill-cost-tests-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

OUT="$TEST_TMP/out.json"
pass_count=0

expect_ok() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "FAIL: $name" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_fails() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $name was accepted" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

assert_eq() {
  local name="$1"
  local filter="$2"
  local expected="$3"
  local actual
  actual="$(jq -r "$filter" "$OUT")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $name expected [$expected] got [$actual]" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

python3 -c 'import sys, py_compile; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$SCRIPT" "$TEST_TMP/skill-cost.pyc"
pass_count=$((pass_count + 1))

python3 "$SCRIPT" --json "$ORCH" "$CHILD" > "$OUT"

assert_eq "status is ok" ".status" "ok"
assert_eq "schema version" ".schema_version" "1"
assert_eq "session count" ".sessions | length" "2"

# Session A (orchestrator-like): tokens, compaction, gh dispatches, refetch, errors.
assert_eq "A session id" ".sessions[0].session_id" "11111111-1111-1111-1111-111111111111"
assert_eq "A session version" ".sessions[0].session_version" "3"
assert_eq "A elapsed seconds" ".sessions[0].elapsed_seconds" "5.2"
assert_eq "A thinking levels" '.sessions[0].thinking_levels | join(",")' "max"
assert_eq "A models observed count" ".sessions[0].models_observed | length" "2"
assert_eq "A models observed first" ".sessions[0].models_observed[0]" "acme/fixture-large"
assert_eq "A usage input" ".sessions[0].usage.input" "350"
assert_eq "A usage output" ".sessions[0].usage.output" "75"
assert_eq "A usage cache read" ".sessions[0].usage.cache_read" "116"
assert_eq "A usage cache write" ".sessions[0].usage.cache_write" "10"
assert_eq "A usage reasoning" ".sessions[0].usage.reasoning" "7"
assert_eq "A usage total" ".sessions[0].usage.total" "558"
assert_eq "A usage cost" '(.sessions[0].usage.cost * 10000 | round)' "41"
assert_eq "A per-model large messages" '.sessions[0].usage_by_model["acme/fixture-large"].assistant_messages' "2"
assert_eq "A per-model large input" '.sessions[0].usage_by_model["acme/fixture-large"].usage.input' "220"
assert_eq "A per-model small messages" '.sessions[0].usage_by_model["acme/fixture-small"].assistant_messages' "2"
assert_eq "A per-model small input" '.sessions[0].usage_by_model["acme/fixture-small"].usage.input' "130"
assert_eq "A compaction calls" ".sessions[0].compaction.calls" "1"
assert_eq "A compaction tokens before" ".sessions[0].compaction.tokens_before" "60000"
assert_eq "A tokens incl compaction input" ".sessions[0].tokens_including_compaction.input" "1350"
assert_eq "A tokens incl compaction output" ".sessions[0].tokens_including_compaction.output" "175"
assert_eq "A tokens incl compaction cache read" ".sessions[0].tokens_including_compaction.cache_read" "116"
assert_eq "A tokens incl compaction reasoning" ".sessions[0].tokens_including_compaction.reasoning" "57"
assert_eq "A tokens incl compaction total" ".sessions[0].tokens_including_compaction.total" "1708"
assert_eq "A tokens incl compaction cost" '(.sessions[0].tokens_including_compaction.cost * 10000 | round)' "141"
assert_eq "A tool call total" ".sessions[0].tool_calls.total" "5"
assert_eq "A tool call bash" ".sessions[0].tool_calls.by_name.bash" "3"
assert_eq "A tool call read" ".sessions[0].tool_calls.by_name.read" "1"
assert_eq "A tool call fetch" ".sessions[0].tool_calls.by_name.fetch_content" "1"
assert_eq "A gh dispatches" ".sessions[0].gh_cli.dispatches" "2"
assert_eq "A gh dispatches by action" '.sessions[0].gh_cli.by_action["issue.read"]' "2"
assert_eq "A raw gh commands" ".sessions[0].gh_cli.raw_gh_commands" "0"
assert_eq "A handoff return calls" ".sessions[0].gh_cli.handoff_return_calls" "1"
assert_eq "A gh repeated targets" ".sessions[0].gh_cli.repeated_targets | length" "1"
assert_eq "A gh repeated target count" ".sessions[0].gh_cli.repeated_targets[0].count" "2"
assert_eq "A gh repeated target action" ".sessions[0].gh_cli.repeated_targets[0].action" "issue.read"
assert_eq "A gh repeated target value" ".sessions[0].gh_cli.repeated_targets[0].target" "number=157"
assert_eq "A network tools" ".sessions[0].network_tools.total" "1"
assert_eq "A network by name" ".sessions[0].network_tools.by_name.fetch_content" "1"
assert_eq "A http api lower bound" ".sessions[0].http_api_lower_bound" "3"
assert_eq "A bytes doc read" ".sessions[0].result_bytes_approx.doc_read" "408"
assert_eq "A bytes gh api" ".sessions[0].result_bytes_approx.gh_api" "25"
assert_eq "A bytes bash other" ".sessions[0].result_bytes_approx.bash_other" "8"
assert_eq "A bytes network" ".sessions[0].result_bytes_approx.network_tool" "12"
assert_eq "A bytes unknown" ".sessions[0].result_bytes_approx.unknown" "0"
assert_eq "A bytes total" ".sessions[0].result_bytes_approx.total" "453"
assert_eq "A refetch read paths" ".sessions[0].refetch.read_paths | length" "0"
assert_eq "A tool result errors" ".sessions[0].errors.tool_results_with_error" "1"
assert_eq "A assistant error messages" ".sessions[0].errors.assistant_error_messages" "0"
assert_eq "A stop reasons toolUse" ".sessions[0].stop_reasons.toolUse" "2"
assert_eq "A stop reasons stop" ".sessions[0].stop_reasons.stop" "2"
assert_eq "A skipped lines" ".sessions[0].skipped_lines" "0"

# Session B (child-like): repeated read of the same document.
assert_eq "B session id" ".sessions[1].session_id" "22222222-2222-2222-2222-222222222222"
assert_eq "B elapsed seconds" ".sessions[1].elapsed_seconds" "1.4"
assert_eq "B usage input" ".sessions[1].usage.input" "84"
assert_eq "B usage output" ".sessions[1].usage.output" "17"
assert_eq "B usage total" ".sessions[1].usage.total" "101"
assert_eq "B usage cost" '(.sessions[1].usage.cost * 10000 | round)' "4"
assert_eq "B tool call total" ".sessions[1].tool_calls.total" "2"
assert_eq "B tool call read" ".sessions[1].tool_calls.by_name.read" "2"
assert_eq "B refetch read path count" ".sessions[1].refetch.read_paths[0].count" "2"
assert_eq "B refetch read path target" ".sessions[1].refetch.read_paths[0].target" "/tmp/fixture/docs/spec.md"
assert_eq "B bytes doc read" ".sessions[1].result_bytes_approx.doc_read" "1000"
assert_eq "B bytes total" ".sessions[1].result_bytes_approx.total" "1000"
assert_eq "B gh dispatches" ".sessions[1].gh_cli.dispatches" "0"
assert_eq "B tool result errors" ".sessions[1].errors.tool_results_with_error" "0"

# Cross-session totals.
assert_eq "totals sessions" ".totals.sessions" "2"
assert_eq "totals usage input" ".totals.usage.input" "434"
assert_eq "totals usage output" ".totals.usage.output" "92"
assert_eq "totals usage total" ".totals.usage.total" "659"
assert_eq "totals incl compaction input" ".totals.tokens_including_compaction.input" "1434"
assert_eq "totals incl compaction total" ".totals.tokens_including_compaction.total" "1809"
assert_eq "totals compaction tokens before" ".totals.compaction_tokens_before" "60000"
assert_eq "totals tool calls" ".totals.tool_calls_total" "7"
assert_eq "totals tool calls read" ".totals.tool_calls_by_name.read" "3"
assert_eq "totals tool calls bash" ".totals.tool_calls_by_name.bash" "3"
assert_eq "totals tool calls fetch" ".totals.tool_calls_by_name.fetch_content" "1"
assert_eq "totals gh dispatches" ".totals.gh_dispatches" "2"
assert_eq "totals raw gh" ".totals.raw_gh_commands" "0"
assert_eq "totals handoff returns" ".totals.handoff_return_calls" "1"
assert_eq "totals network tools" ".totals.network_tool_calls" "1"
assert_eq "totals http api lower bound" ".totals.http_api_lower_bound" "3"
assert_eq "totals bytes" ".totals.result_bytes_approx" "1453"
assert_eq "totals errors" ".totals.errors" "1"
assert_eq "totals elapsed sum" ".totals.elapsed_seconds_sum" "6.6"

# Malformed lines are skipped, not fatal; the rest of the metrics stay stable.
cp "$ORCH" "$TEST_TMP/malformed.jsonl"
printf 'not-json-at-all\n' >> "$TEST_TMP/malformed.jsonl"
python3 "$SCRIPT" --json "$TEST_TMP/malformed.jsonl" > "$OUT"
assert_eq "malformed line skipped" ".sessions[0].skipped_lines" "1"
assert_eq "malformed keeps status ok" ".status" "ok"
assert_eq "malformed keeps tool calls" ".sessions[0].tool_calls.total" "5"

# Fail-closed behavior on unreadable input.
expect_fails "missing file exits nonzero" python3 "$SCRIPT" --json "$TEST_TMP/no-such-file.jsonl"

# Text mode stays available for a human-readable report.
expect_ok "text mode exits zero" python3 "$SCRIPT" "$ORCH" "$CHILD"
python3 "$SCRIPT" "$ORCH" "$CHILD" > "$TEST_TMP/text.txt"
grep -q "totals (2 sessions)" "$TEST_TMP/text.txt"
pass_count=$((pass_count + 1))

echo "PASS: $pass_count skill-cost analyzer cases"
