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
  'printf "%s %s %s\n" "${1:-}" "${2:-}" "${3:-}" >> "$HERDR_TEST_CALLS"' \
  'if [ "${1:-}" = pane ]; then' \
  '  [ "${2:-}" = get ] || exit 94' \
  '  [ "${3:-}" = "$HERDR_PANE_ID" ] || exit 95' \
  '  cat "$HERDR_TEST_PANE_JSON"' \
  '  exit 0' \
  'fi' \
  '[ "${1:-}" = agent ] && [ "${2:-}" = prompt ] || exit 90' \
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
export HERDR_TEST_PANE_JSON="$MOCK_LOG/pane.json"
export HERDR_TEST_CALLS="$MOCK_LOG/calls"
: > "$HERDR_TEST_CALLS"
printf '%s\n' \
  '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","label":"bob","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
  > "$HERDR_TEST_PANE_JSON"

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
  [[ "$message" == *'Direct parent pane for result return: wG:p1 (bob)'* ]]
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

parent_display_name_fallbacks() {
  local prompt='run the child'
  printf '%s\n' \
    '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
    > "$HERDR_TEST_PANE_JSON"
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 "$prompt"
  grep -Fqx 'Direct parent pane for result return: wG:p1 (pi)' "$HERDR_TEST_MESSAGE"
  HERDR_TEST_PANE_JSON="$TEST_TMP/missing.json" HERDR_TEST_RC=0 \
    "$PARENT_SCRIPT" wG:p2 "$prompt"
  grep -Fqx 'Direct parent pane for result return: wG:p1' "$HERDR_TEST_MESSAGE"
}

python3_isolation() {
  printf '%s\n' \
    '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","label":"bob","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
    > "$HERDR_TEST_PANE_JSON"
  local hostile="$TEST_TMP/hostile-cwd"
  local marker="$TEST_TMP/jsonpy-executed"
  mkdir -p "$hostile"
  printf '%s\n' \
    'import os' \
    "os.system(\"touch $marker\")" \
    'print("pwned")' > "$hostile/json.py"
  (cd "$hostile" && HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'run the child')
  [ ! -e "$marker" ]
  grep -Fqx 'Direct parent pane for result return: wG:p1 (bob)' "$HERDR_TEST_MESSAGE"
}

call_counts_are_exactly_once() {
  [ "$(grep -Ec '^pane ' "$HERDR_TEST_CALLS")" -eq 1 ]
  grep -Fqx 'pane get wG:p1' "$HERDR_TEST_CALLS"
  [ "$(grep -Ec '^agent prompt ' "$HERDR_TEST_CALLS")" -eq 1 ]
  grep -Fqx 'agent prompt wG:p2' "$HERDR_TEST_CALLS"
}

wrappers_are_thin() {
  ! grep -Eq -- '--wait|herdr (workspace|worktree|agent (get|read))' \
    "$PARENT_SCRIPT" "$CHILD_SCRIPT"
  ! grep -Eq -- 'herdr (pane|workspace|worktree|agent (get|read))' \
    "$CHILD_SCRIPT"
  # The parent may resolve the display name with exactly one read-only lookup.
  grep -Eq 'herdr pane get' "$PARENT_SCRIPT"
  ! grep -Eo 'herdr pane [[:alnum:]_-]+' "$PARENT_SCRIPT" | grep -Fxv 'herdr pane get'
  # Success path: one pane get and one agent prompt, no duplicates.
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'run the child'
  call_counts_are_exactly_once
  # Lookup failure path: still one pane get and one agent prompt, no retries.
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_PANE_JSON="$TEST_TMP/missing.json" HERDR_TEST_RC=0 \
    "$PARENT_SCRIPT" wG:p2 'run the child'
  call_counts_are_exactly_once
}

run_test() {
  local test_name="$1"
  "$test_name"
  pass "$test_name"
}

expected_count=9

run_test parent_success
run_test child_success
run_test child_blocked
run_test invalid_arguments
run_test preflight_failures
run_test cli_failure_is_propagated
run_test parent_display_name_fallbacks
run_test python3_isolation
run_test wrappers_are_thin

[ "$pass_count" -eq "$expected_count" ] || {
  printf 'FAIL: expected %s tests, got %s\n' "$expected_count" "$pass_count" >&2
  exit 1
}

printf 'PASS: %s Herdr async wrapper tests\n' "$pass_count"
