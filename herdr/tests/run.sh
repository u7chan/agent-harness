#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_SCRIPT="$HERDR_DIR/scripts/parent-delegate-async.sh"
CHILD_SCRIPT="$HERDR_DIR/scripts/child-return-result.sh"
TEST_TMP="$(mktemp -d /tmp/herdr-async-test-XXXXXX)"
MOCK_BIN="$TEST_TMP/bin"
MOCK_LOG="$TEST_TMP/log"
mkdir -p "$MOCK_BIN" "$MOCK_LOG"
trap 'rm -rf "$TEST_TMP"' EXIT

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[ "$1" = agent ] && [ "$2" = prompt ] || exit 90' \
  'shift 2' \
  '[ "$#" -eq 2 ] || exit 91' \
  'printf "%s" "$1" > "$HERDR_TEST_TARGET"' \
  'printf "%s" "$2" > "$HERDR_TEST_MESSAGE"' \
  'for arg in "$@"; do [ "$arg" = --wait ] && exit 92; done' \
  'exit "${HERDR_TEST_RC:-0}"' > "$MOCK_BIN/herdr"
chmod +x "$MOCK_BIN/herdr"

export PATH="$MOCK_BIN:$PATH"
export HERDR_ENV=1
export HERDR_WORKSPACE_ID=wG
export HERDR_PANE_ID=wG:p1
export HERDR_TEST_TARGET="$MOCK_LOG/target"
export HERDR_TEST_MESSAGE="$MOCK_LOG/message"

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$1"
}

expect_rc() {
  local expected="$1"
  shift
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ]
}

assert_file_eq() {
  local expected="$1"
  local file="$2"
  [ "$(<"$file")" = "$expected" ]
}

parent_success() {
  local prompt=$'run the child\nwith this prompt'
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 "$prompt"
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  local message
  message="$(<"$HERDR_TEST_MESSAGE")"
  case "$message" in
    "$prompt"*) ;;
    *) return 1 ;;
  esac
  [[ "$message" == *'Direct parent pane for result return: wG:p1'* ]]
  local return_command="\"${CHILD_SCRIPT}\" \"wG:p1\" <completed|blocked> \"<body>\""
  [[ "$CHILD_SCRIPT" = /* ]]
  [[ "$message" == *"$return_command"* ]]
}

child_success() {
  local body=$'summary line\nsecond line'
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wG:p1 completed "$body"
  assert_file_eq wG:p1 "$HERDR_TEST_TARGET"
  assert_file_eq $'status: completed\nbody:\nsummary line\nsecond line' "$HERDR_TEST_MESSAGE"
}

child_blocked() {
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wG:p1 blocked 'needs parent input'
  assert_file_eq $'status: blocked\nbody:\nneeds parent input' "$HERDR_TEST_MESSAGE"
}

invalid_arguments() {
  expect_rc 2 "$PARENT_SCRIPT" --wait 'prompt'
  expect_rc 2 "$PARENT_SCRIPT" child-agent 'prompt'
  expect_rc 2 "$PARENT_SCRIPT" wG:p2 ''
  expect_rc 2 "$CHILD_SCRIPT" wG:p1 pending 'body'
  expect_rc 2 "$CHILD_SCRIPT" invalid-parent completed 'body'
  expect_rc 2 "$CHILD_SCRIPT" wG:p1 completed ''
}

preflight_failures() {
  expect_rc 1 env -u HERDR_ENV HERDR_PANE_ID=wG:p1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env -u HERDR_PANE_ID HERDR_ENV=1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env -u HERDR_WORKSPACE_ID HERDR_ENV=1 HERDR_PANE_ID=wG:p1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env HERDR_WORKSPACE_ID=wG HERDR_PANE_ID=wJ:p1 \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 "$PARENT_SCRIPT" wJ:p2 prompt
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wG:p1 PATH="$TEST_TMP/empty:/usr/bin:/bin" \
    "$CHILD_SCRIPT" wG:p1 completed body
}

cli_failure_is_propagated() {
  expect_rc 17 env HERDR_TEST_RC=17 "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 17 env HERDR_TEST_RC=17 "$CHILD_SCRIPT" wG:p1 completed body
}

wrappers_are_thin() {
  ! grep -Eq -- '--wait|herdr (pane|workspace|worktree)' \
    "$PARENT_SCRIPT" "$CHILD_SCRIPT"
}

run_test() {
  local test_name="$1"
  "$test_name"
  pass "$test_name"
}

expected_count=7

run_test parent_success
run_test child_success
run_test child_blocked
run_test invalid_arguments
run_test preflight_failures
run_test cli_failure_is_propagated
run_test wrappers_are_thin

[ "$pass_count" -eq "$expected_count" ] || {
  printf 'FAIL: expected %s tests, got %s\n' "$expected_count" "$pass_count" >&2
  exit 1
}

printf 'PASS: %s Herdr async wrapper tests\n' "$pass_count"
