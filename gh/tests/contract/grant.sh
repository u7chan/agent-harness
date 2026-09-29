#!/usr/bin/env bash
set -u

# Contract tests for the grant field (Issue #224): grant is declared on
# every action, read actions accept it as an optional field (default read),
# write actions keep it required, and only read / write / sensitive-write
# are accepted. The value is compared on the JSON string, so trailing
# whitespace such as "read\n" must not collapse into an allowed value.
# The catalog entries are the real ones from actions.json (the fixture
# symlinks it); only the action bodies are mocked so dispatch returns an
# ok envelope without any GitHub call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Write a mock action body into the fixture. The catalog entry stays the
# real one, so schema, permission, and requires_auth are the shipped values.
mock_action() {
  local action_name="$1"
  add_mock_action "$action_name" "#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
COMMON_DIR=\"\$SCRIPT_DIR/../common\"
source \"\$COMMON_DIR/envelope.sh\"
envelope_ok \"$action_name\" \"{}\" \"\$1\""
}

# dispatch <action> <payload>: prints the dispatcher output and returns its
# exit status.
dispatch() {
  local action="$1"
  local payload="$2"
  local input_file
  local rc=0

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' "$payload" > "$input_file"
  fixture_gh "$action" "$input_file" 2>&1 || rc=$?
  rm -f "$input_file"
  return "$rc"
}

test_read_action_accepts_grant_read() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action issue.get

  local output
  output="$(dispatch issue.get '{"number":224,"grant":"read"}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
)

test_repo_get_accepts_grant_only_input() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action repo.get

  local output
  output="$(dispatch repo.get '{"grant":"read"}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
)

test_repo_get_unknown_key_rejected() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action repo.get

  local output
  output="$(dispatch repo.get '{"title":"x"}')" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "UNKNOWN_FIELDS" || return 1
)

test_unknown_grant_rejected() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action issue.get

  local output
  output="$(dispatch issue.get '{"number":224,"grant":"writ"}')" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_GRANT" || return 1
)

# A trailing newline used to be stripped by the command substitution that
# read the grant value, turning "read\n" into the allowed value "read"
# (Issue #224 review blocker). The comparison happens on the JSON string,
# so all three values must fail as INVALID_GRANT with the newline intact.
test_grant_trailing_newline_rejected() (
  setup_fixture
  trap teardown_fixture EXIT

  local payload output
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    output="$(dispatch actions.describe "$payload")" && return 1 || true
    assert_json_eq "$output" '.status' "failed" || {
      echo "  payload: $payload"
      return 1
    }
    assert_json_eq "$output" '.error.code' "INVALID_GRANT" || {
      echo "  payload: $payload"
      return 1
    }
  done <<'CASES'
{"action":"repo.get","grant":"read\n"}
{"action":"repo.get","grant":"write\n"}
{"action":"repo.get","grant":"sensitive-write\n"}
CASES
)

test_read_action_without_grant_defaults_to_read() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action issue.get

  local output
  output="$(dispatch issue.get '{"number":224}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
)

test_write_action_without_grant_still_required() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  local output
  output="$(dispatch issue.create '{"title":"x"}')" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "MISSING_REQUIRED_FIELD" || return 1
)

test_unknown_fields_message_comma_space_no_trailing() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  mock_action issue.get

  local output
  output="$(dispatch issue.get '{"number":1,"a":1,"b":2}')" && return 1 || true
  assert_json_eq "$output" '.error.code' "UNKNOWN_FIELDS" || return 1
  assert_json_eq "$output" '.error.message' "Unknown fields: a, b" || return 1
)

main() {
  echo "=== grant contract tests ==="
  run_test test_read_action_accepts_grant_read
  run_test test_repo_get_accepts_grant_only_input
  run_test test_repo_get_unknown_key_rejected
  run_test test_unknown_grant_rejected
  run_test test_grant_trailing_newline_rejected
  run_test test_read_action_without_grant_defaults_to_read
  run_test test_write_action_without_grant_still_required
  run_test test_unknown_fields_message_comma_space_no_trailing
  print_summary
}

main
