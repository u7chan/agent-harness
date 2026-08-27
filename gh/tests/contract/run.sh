#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SCRIPT="$SCRIPT_DIR/../../scripts/gh.sh"

source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Group A: tests against the real gh.sh.
test_unknown_action() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$("$GH_SCRIPT" "no.such.action" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "UNKNOWN_ACTION" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.schema_version' "1" || return 1
}

test_invalid_json() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' 'not-json' > "$input_file"
  output="$("$GH_SCRIPT" "issue.get" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_JSON" || return 1
}

test_missing_required_field() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"grant":"read"}' > "$input_file"
  output="$("$GH_SCRIPT" "issue.create" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "MISSING_REQUIRED_FIELD" || return 1
}

test_unknown_fields() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":1,"extra":"x"}' > "$input_file"
  output="$("$GH_SCRIPT" "issue.get" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "UNKNOWN_FIELDS" || return 1
}

test_type_mismatch() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":"not-a-number"}' > "$input_file"
  output="$("$GH_SCRIPT" "issue.get" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "TYPE_MISMATCH" || return 1
}

# Group B: tests against the fixture gh.sh.
test_grant_insufficient() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"title":"test","grant":"read"}' > "$input_file"
  output="$(fixture_gh "issue.create" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "GRANT_INSUFFICIENT" || return 1
}

test_auth_error() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":1}' > "$input_file"
  output="$(fixture_gh "issue.get" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "AUTH_ERROR" || return 1
}

test_not_implemented() {
  local input_file
  local output
  local rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$(fixture_gh "actions.list" "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "NOT_IMPLEMENTED" || return 1
}

setup_actions_list_fixture() {
  setup_fixture
  cp "$SCRIPT_DIR/../../scripts/actions/actions.list.sh" \
    "$FIXTURE_DIR/scripts/actions/actions.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/actions.list.sh"
}

register_actions_list_mock() {
  local action_name="$1"
  local category="$2"
  local permission="$3"
  local actions_file="$FIXTURE_DIR/actions.json"
  local actions_tmp="$actions_file.tmp"

  register_mock_action "$action_name" '#!/usr/bin/env bash
set -euo pipefail
exit 0'

  jq --arg name "$action_name" \
    --arg category "$category" \
    --arg permission "$permission" \
    '(.actions[] | select(.name == $name)) |=
      (.category = $category | .permission = $permission)' \
    "$actions_file" > "$actions_tmp"
  mv "$actions_tmp" "$actions_file"
}

run_actions_list() {
  local input_json="$1"
  local input_file

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' "$input_json" > "$input_file"
  fixture_gh "actions.list" "$input_file"
  local rc=$?
  rm -f "$input_file"
  return "$rc"
}

test_actions_list_no_filter() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.issue.read" "issue" "read"
  register_actions_list_mock "contract.pr.write" "pr" "write"

  local output expected actual
  output="$(run_actions_list '{}')" || return 1
  expected="$(jq -c '[.actions[] | {name, description, category, permission}] | sort_by(.name)' \
    "$FIXTURE_DIR/actions.json")"
  actual="$(jq -c '.data | sort_by(.name)' <<< "$output")"
  assert_eq "$actual" "$expected" || return 1
)

test_actions_list_filter_by_categories() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.issue.filter" "issue" "read"
  register_actions_list_mock "contract.pr.filter" "pr" "read"

  local output
  output="$(run_actions_list '{"categories":["issue"]}')" || return 1
  assert_json_eq "$output" '[.data[].category] | unique == ["issue"]' "true" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.issue.filter")) | length' "1" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.pr.filter")) | length' "0" || return 1
)

test_actions_list_filter_by_permissions() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.read.filter" "issue" "read"
  register_actions_list_mock "contract.write.filter" "issue" "write"

  local output
  output="$(run_actions_list '{"permissions":["read"]}')" || return 1
  assert_json_eq "$output" '[.data[].permission] | unique == ["read"]' "true" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.read.filter")) | length' "1" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.write.filter")) | length' "0" || return 1
)

test_actions_list_filter_by_query() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.pull.filter" "pr" "read"
  register_actions_list_mock "contract.other.filter" "pr" "read"

  local output
  output="$(run_actions_list '{"query":"pull"}')" || return 1
  assert_json_eq "$output" '.data | all(.[]; ((.name | ascii_downcase | contains("pull")) or (.description | ascii_downcase | contains("pull"))))' "true" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.pull.filter")) | length' "1" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.other.filter")) | length' "0" || return 1
)

test_actions_list_filter_query_case_insensitive() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.pull.case" "pr" "read"
  register_actions_list_mock "contract.other.case" "pr" "read"

  local lower_output upper_output lower_data upper_data
  lower_output="$(run_actions_list '{"query":"pull"}')" || return 1
  upper_output="$(run_actions_list '{"query":"PULL"}')" || return 1
  lower_data="$(jq -c '.data | sort_by(.name)' <<< "$lower_output")"
  upper_data="$(jq -c '.data | sort_by(.name)' <<< "$upper_output")"
  assert_eq "$upper_data" "$lower_data" || return 1
)

test_actions_list_filter_combined() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.pr.read" "pr" "read"
  register_actions_list_mock "contract.pr.write" "pr" "write"

  local output
  output="$(run_actions_list '{"categories":["pr"],"permissions":["read"]}')" || return 1
  assert_json_eq "$output" '.data | all(.[]; .category == "pr" and .permission == "read")' "true" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.pr.read")) | length' "1" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.pr.write")) | length' "0" || return 1
)

test_actions_list_filter_or_within_field() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  register_actions_list_mock "contract.issue.or" "issue" "read"
  register_actions_list_mock "contract.pr.or" "pr" "read"

  local output
  output="$(run_actions_list '{"categories":["issue","pr"]}')" || return 1
  assert_json_eq "$output" '[.data[].category] | unique == ["issue", "pr"]' "true" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.issue.or")) | length' "1" || return 1
  assert_json_eq "$output" '.data | map(select(.name == "contract.pr.or")) | length' "1" || return 1
)

test_actions_list_filter_empty_result() (
  setup_actions_list_fixture
  trap teardown_fixture EXIT

  local output
  output="$(run_actions_list '{"categories":["nonexistent"]}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data' '[]' || return 1
)

test_envelope() {
  local input_file
  local output
  local line_count

  register_mock_action echo_ok '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "echo_ok" "{}" "{}"'

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  if ! output="$(fixture_gh echo_ok "$input_file")"; then
    rm -f "$input_file"
    echo "echo_ok unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  line_count="$(printf '%s\n' "$output" | wc -l)"
  assert_eq "$line_count" "1" || return 1
  if ! printf '%s\n' "$output" | jq empty >/dev/null 2>&1; then
    echo "echo_ok output is not valid JSON"
    return 1
  fi
  assert_json_eq "$output" '.schema_version' '1' || return 1
  assert_json_eq "$output" '.status' 'ok' || return 1
  assert_json_eq "$output" 'has("data")' 'true' || return 1

  register_mock_action echo_fail '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_fail "echo_fail" "TEST_ERROR" "test failure" false'

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  if ! output="$(fixture_gh echo_fail "$input_file")"; then
    rm -f "$input_file"
    echo "echo_fail unexpectedly failed to dispatch"
    return 1
  fi
  rm -f "$input_file"

  line_count="$(printf '%s\n' "$output" | wc -l)"
  assert_eq "$line_count" "1" || return 1
  if ! printf '%s\n' "$output" | jq empty >/dev/null 2>&1; then
    echo "echo_fail output is not valid JSON"
    return 1
  fi
  assert_json_eq "$output" '.schema_version' '1' || return 1
  assert_json_eq "$output" '.status' 'failed' || return 1
  assert_json_eq "$output" 'has("error")' 'true' || return 1
  assert_json_eq "$output" '.error.code != null' 'true' || return 1
  assert_json_eq "$output" '.error.message != null' 'true' || return 1
}

test_dispatch() {
  local input_file
  local output

  register_mock_action echo \
    '{"hello":{"type":"string","required":true}}' \
    '#!/usr/bin/env bash
set -euo pipefail
jq -nc --arg received "$1" '"'"'{received: $received}'"'"''

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"hello":"world"}' > "$input_file"
  if ! output="$(fixture_gh echo "$input_file")"; then
    rm -f "$input_file"
    echo "echo unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.received' '{"hello":"world"}' || return 1
  assert_contains "$output" 'received' || return 1
  assert_contains "$output" 'hello' || return 1
}

test_recheck_action_contracts() {
  "$SCRIPT_DIR/recheck-actions.sh" >/dev/null
}

test_workflow_runs_contracts() {
  "$SCRIPT_DIR/workflow-runs.sh" >/dev/null
}

main() {
  echo "=== gh dispatcher contract tests ==="
  echo

  # Group A
  run_test test_unknown_action
  run_test test_invalid_json
  run_test test_missing_required_field
  run_test test_unknown_fields
  run_test test_type_mismatch

  # Group B
  setup_fixture
  trap teardown_fixture EXIT

  export GH_TEST_AUTH_RESULT=0
  run_test test_grant_insufficient
  export GH_TEST_AUTH_RESULT=1
  run_test test_auth_error
  export GH_TEST_AUTH_RESULT=0
  run_test test_not_implemented

  # Group C: actions.list filters
  run_test test_actions_list_no_filter
  run_test test_actions_list_filter_by_categories
  run_test test_actions_list_filter_by_permissions
  run_test test_actions_list_filter_by_query
  run_test test_actions_list_filter_query_case_insensitive
  run_test test_actions_list_filter_combined
  run_test test_actions_list_filter_or_within_field
  run_test test_actions_list_filter_empty_result

  # Group D: envelope and dispatch
  run_test test_envelope
  run_test test_dispatch
  run_test test_recheck_action_contracts
  run_test test_workflow_runs_contracts

  teardown_fixture
  trap - EXIT

  print_summary
}

main
