#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Issue #183 (epic #169, review points N13/N2): the dispatcher must give
# empty, whitespace-only, {} and invalid JSON the same error on both entry
# paths - the request-file path (comments.*/reviews.* family actions, whose
# scripts read the request from a file argument) and the string-input path
# (every other action, whose scripts read inline JSON). And dispatch must
# never chmod action scripts: action files are read-only dependencies of the
# dispatcher, launched through bash, so a read-only checkout works and git
# status stays clean.
#
# Both paths were already sharing one field validator; the remaining gap was
# the input acquisition in front of it: an empty or whitespace-only request
# file is zero JSON inputs for jq, so it used to slip past the INVALID_JSON
# check into per-field validation and failed as MISSING_REQUIRED_FIELD while
# the string path normalized it to {} and failed as MISSING_INPUT.

# Two mock actions with an identical required-field schema, one on each
# entry path: contract.matrix.str receives the inline JSON text as $1,
# comments.matrix.file receives the request file path as $1.
setup_matrix_actions() {
  local schema='{"number":{"type":"number","required":true}}'
  register_mock_action contract.matrix.str "$schema" '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "contract.matrix.str" "{}" "$1"'
  register_mock_action comments.matrix.file "$schema" '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "comments.matrix.file" "{}" "$(cat "$1")"'
}

# invoke_action <action> <mode:file|stdin|noinput> <payload>: prints the
# dispatcher output on stdout and returns the dispatcher exit status.
invoke_action() {
  local action="$1"
  local mode="$2"
  local payload="$3"
  local input_file
  local rc=0 output=""

  case "$mode" in
    file)
      input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
      printf '%b' "$payload" > "$input_file"
      output="$(fixture_gh "$action" "$input_file" 2>&1 </dev/null)" || rc=$?
      rm -f "$input_file"
      ;;
    stdin)
      output="$(printf '%b' "$payload" | fixture_gh "$action" 2>&1)" || rc=$?
      ;;
    noinput)
      output="$(fixture_gh "$action" 2>&1 </dev/null)" || rc=$?
      ;;
  esac
  printf '%s\n' "$output"
  return "$rc"
}

# status_of <output>: "ok" for a successful envelope, the error code for a
# failed one, or "NO_ENVELOPE" when the output is not a JSON envelope.
status_of() {
  jq -r 'if .status == "ok" then "ok" elif (.error.code != null) then .error.code else "NO_ENVELOPE" end' \
    <<< "$1" 2>/dev/null || echo "NO_ENVELOPE"
}

# Both entry paths must produce the same exit status and the same error code
# for empty, whitespace-only, {} and invalid JSON input, through the file
# argument, stdin and no-input-at-all entry points alike.
test_input_contract_match_both_entrypoints() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0
  setup_matrix_actions

  local case_payload case_mode case_expect
  while IFS='|' read -r case_payload case_mode case_expect; do
    [ -z "$case_mode" ] && continue
    local out_str out_file rc_str rc_file code_str code_file
    out_str="$(invoke_action contract.matrix.str "$case_mode" "$case_payload")"
    rc_str=$?
    out_file="$(invoke_action comments.matrix.file "$case_mode" "$case_payload")"
    rc_file=$?
    code_str="$(status_of "$out_str")"
    code_file="$(status_of "$out_file")"

    assert_eq "$rc_str" "$rc_file" || {
      echo "  case payload=[$case_payload] mode=$case_mode: rc differs ($rc_str vs $rc_file)"
      return 1
    }
    assert_eq "$code_str" "$code_file" || {
      echo "  case payload=[$case_payload] mode=$case_mode: code differs ($code_str vs $code_file)"
      return 1
    }

    if [ "$case_expect" = "ok" ]; then
      assert_eq "$rc_str" "0" || {
        echo "  case payload=[$case_payload] mode=$case_mode: expected success, got rc=$rc_str"
        return 1
      }
      assert_eq "$(jq -c '.data' <<< "$out_str")" "$(jq -c '.data' <<< "$out_file")" || {
        echo "  case payload=[$case_payload] mode=$case_mode: data differs between entry paths"
        return 1
      }
    else
      assert_eq "$rc_str" "1" || {
        echo "  case payload=[$case_payload] mode=$case_mode: expected failure, got rc=$rc_str"
        return 1
      }
      assert_json_eq "$out_str" '.error.code' "$case_expect" || {
        echo "  case payload=[$case_payload] mode=$case_mode (string path)"
        return 1
      }
      assert_json_eq "$out_file" '.error.code' "$case_expect" || {
        echo "  case payload=[$case_payload] mode=$case_mode (file path)"
        return 1
      }
    fi
  done <<'CASES'
|file|MISSING_INPUT
|stdin|MISSING_INPUT
|noinput|MISSING_INPUT
   \n|file|MISSING_INPUT
 \t\n\n|stdin|MISSING_INPUT
{}|file|MISSING_INPUT
{}|stdin|MISSING_INPUT
not-json|file|INVALID_JSON
not-json|stdin|INVALID_JSON
{"number":1}|file|ok
{"number":1}|stdin|ok
CASES
)

# Actions that expect no input must keep dispatching when the input is
# empty, whitespace-only or {} - on both entry paths.
test_noinput_actions_dispatch_unchanged() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  register_mock_action contract.noinput.str '{}' '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "contract.noinput.str" "{}" "$1"'
  register_mock_action comments.noinput.file '{}' '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "comments.noinput.file" "{}" "$(cat "$1")"'

  local case_payload case_mode
  while IFS='|' read -r case_payload case_mode; do
    [ -z "$case_mode" ] && continue
    local out_str out_file rc_str rc_file
    out_str="$(invoke_action contract.noinput.str "$case_mode" "$case_payload")"
    rc_str=$?
    out_file="$(invoke_action comments.noinput.file "$case_mode" "$case_payload")"
    rc_file=$?

    assert_eq "$rc_str" "0" || {
      echo "  case payload=[$case_payload] mode=$case_mode: string path failed (rc=$rc_str)"
      return 1
    }
    assert_eq "$rc_file" "0" || {
      echo "  case payload=[$case_payload] mode=$case_mode: file path failed (rc=$rc_file)"
      return 1
    }
    assert_json_eq "$out_str" '.status' "ok" || return 1
    assert_json_eq "$out_file" '.status' "ok" || return 1
  done <<'CASES'
|file
   \n|file
{}|file
{}|stdin
CASES
)

# Issue #183 (N2): dispatch must leave the checkout untouched. The action
# script is deliberately tracked without an executable bit (git records it
# as 100644): launching through bash must still dispatch it, and the file
# mode and git status must not change. The pre-fix dispatcher chmod +x'd
# the script at runtime, which dirtied the checkout.
test_dispatch_never_modifies_checkout() (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  register_mock_action contract.noop '{}' '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "contract.noop" "{}" "{}"'

  local action_file="$FIXTURE_DIR/scripts/actions/contract.noop.sh"
  # Track the action as 100644, i.e. intentionally without an executable
  # bit, so any runtime chmod would show up as a mode change.
  chmod -x "$action_file"
  git -C "$FIXTURE_DIR" init -q
  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" -c user.email=contract-test@example.com -c user.name=contract-test commit -qm init

  local input_file mode_before status_before output rc mode_after status_after
  mode_before="$(stat -c%a "$action_file")"
  status_before="$(git -C "$FIXTURE_DIR" status --porcelain)"

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$(fixture_gh contract.noop "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  mode_after="$(stat -c%a "$action_file")"
  status_after="$(git -C "$FIXTURE_DIR" status --porcelain)"

  assert_eq "$rc" "0" || {
    echo "  dispatch of a non-executable action script failed (rc=$rc): $output"
    return 1
  }
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_eq "$mode_before" "$mode_after" || {
    echo "  action file mode changed by dispatch: $mode_before -> $mode_after"
    return 1
  }
  assert_eq "$status_before" "$status_after" || {
    echo "  git status changed by dispatch: [${status_before}] -> [${status_after}]"
    return 1
  }
  assert_eq "$status_after" "" || {
    echo "  git status not clean after dispatch: [${status_after}]"
    return 1
  }
)

# Issue #183 (N2): dispatch must work from a read-only checkout. Action
# scripts are only ever read (never chmod +x'd), so a read-only tree is
# enough to run any action.
test_dispatch_readonly_checkout() (
  setup_fixture
  trap 'chmod -R u+w "$FIXTURE_DIR" 2>/dev/null; teardown_fixture' EXIT
  export GH_TEST_AUTH_RESULT=0

  register_mock_action contract.noop '{}' '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "contract.noop" "{}" "{}"'

  chmod -R a-w "$FIXTURE_DIR"

  local input_file output rc
  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$(fixture_gh contract.noop "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "0" || {
    echo "  dispatch failed from a read-only checkout (rc=$rc): $output"
    return 1
  }
  assert_json_eq "$output" '.status' "ok" || return 1
)

main() {
  echo "=== dispatcher input contract tests ==="
  run_test test_input_contract_match_both_entrypoints
  run_test test_noinput_actions_dispatch_unchanged
  run_test test_dispatch_never_modifies_checkout
  run_test test_dispatch_readonly_checkout
  print_summary
}

main
