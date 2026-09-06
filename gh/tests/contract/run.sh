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

# Issue #154: a fake gh CLI that logs every invocation lets the tests pin
# which gh commands a dispatch actually runs. FAKE_GH_AUTH selects what
# `gh auth status` reports; any other gh command exits 64.
make_fake_gh() {
  local bin_dir="$1"
  local log_file="$2"

  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$log_file"
if [ "\${1:-}" = "auth" ] && [ "\${2:-}" = "status" ]; then
  case "\${FAKE_GH_AUTH:-fail}" in
    fail)
      echo "not logged into any hosts" >&2
      exit 1
      ;;
    github.com)
      printf 'github.com\n  ✓ Logged in to github.com account contract-test (keyring)\n'
      exit 0
      ;;
    ghe.example.com)
      printf 'ghe.example.com\n  ✓ Logged in to ghe.example.com account contract-test\n'
      exit 0
      ;;
  esac
fi
exit 64
EOF
  chmod +x "$bin_dir/gh"
}

cleanup_fake_gh() {
  rm -rf "$1"
}

# The catalog marks the catalog actions auth-free: they must run without any
# gh invocation, gh auth status included, even with no gh CLI available.
test_requires_auth_false_runs_without_auth () (
  local bin_dir log_file input_file output rc
  bin_dir="$(mktemp -d /tmp/gh-contract-fakegh-XXXXXX)"
  log_file="$bin_dir/calls.log"
  make_fake_gh "$bin_dir" "$log_file"
  trap 'cleanup_fake_gh "$bin_dir"' EXIT

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$(PATH="$bin_dir:$PATH" FAKE_GH_AUTH=fail "$GH_SCRIPT" actions.list "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | length > 0' "true" || return 1
  if [ -s "$log_file" ]; then
    echo "gh was invoked for a requires_auth:false action:"
    cat "$log_file"
    return 1
  fi
)

# A required number that is explicitly null must be rejected by the common
# layer before any gh command runs: neither an auth check nor the dispatch
# may observe it.
test_required_number_null_rejected_before_dispatch () (
  local bin_dir log_file input_file output rc
  bin_dir="$(mktemp -d /tmp/gh-contract-fakegh-XXXXXX)"
  log_file="$bin_dir/calls.log"
  make_fake_gh "$bin_dir" "$log_file"
  trap 'cleanup_fake_gh "$bin_dir"' EXIT

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":null}' > "$input_file"
  output="$(PATH="$bin_dir:$PATH" FAKE_GH_AUTH=fail "$GH_SCRIPT" issue.get "$input_file" 2>&1)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "MISSING_REQUIRED_FIELD" || return 1
  if [ -s "$log_file" ]; then
    echo "a null required field reached gh:"
    cat "$log_file"
    return 1
  fi
)

# Actions that the catalog marks requires_auth:true keep the auth gate: an
# unauthenticated run and a non-github.com host both fail with AUTH_ERROR,
# a github.com account passes, and one dispatch runs gh auth status exactly
# once (the gate reuses a single call for the auth and host checks).
test_requires_auth_true_single_auth_call () (
  local bin_dir log_file input_file output rc auth_calls
  bin_dir="$(mktemp -d /tmp/gh-contract-fakegh-XXXXXX)"
  log_file="$bin_dir/calls.log"
  make_fake_gh "$bin_dir" "$log_file"
  trap 'cleanup_fake_gh "$bin_dir"' EXIT

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":1}' > "$input_file"

  output="$(PATH="$bin_dir:$PATH" FAKE_GH_AUTH=fail "$GH_SCRIPT" issue.get "$input_file" 2>/dev/null)"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "AUTH_ERROR" || return 1
  auth_calls="$(grep -c 'gh auth status' "$log_file" || true)"
  assert_eq "${auth_calls:-0}" "1" || return 1

  : > "$log_file"
  output="$(PATH="$bin_dir:$PATH" FAKE_GH_AUTH=ghe.example.com "$GH_SCRIPT" issue.get "$input_file" 2>/dev/null)"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "AUTH_ERROR" || return 1
  auth_calls="$(grep -c 'gh auth status' "$log_file" || true)"
  assert_eq "${auth_calls:-0}" "1" || return 1

  # With a github.com active account the dispatch passes the gate and the
  # action runs: issue.get reaches target resolution (which fails against
  # the fake gh), proving the auth check did not consume the request.
  : > "$log_file"
  output="$(PATH="$bin_dir:$PATH" FAKE_GH_AUTH=github.com "$GH_SCRIPT" issue.get "$input_file" 2>/dev/null)"
  rc=$?
  rm -f "$input_file"
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "TARGET_ERROR" || return 1
  auth_calls="$(grep -c 'gh auth status' "$log_file" || true)"
  assert_eq "${auth_calls:-0}" "1" || return 1
  assert_contains "$(cat "$log_file")" "gh repo view" || return 1
)

# Both entry points share one validator: missing, null, empty, and wrongly
# typed values must mean the same thing whether the input arrives as an
# argument (string-input path) or as a request file (comments.* path).
test_input_semantics_match_both_entrypoints () (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  local schema='{"number":{"type":"number","required":true},"label":{"type":"string","required":false}}'
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

  local input_file out_str out_file rc_str rc_file
  run_both() {
    local payload="$1"
    input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
    printf '%s\n' "$payload" > "$input_file"
    out_str="$(fixture_gh contract.matrix.str "$input_file" 2>&1 </dev/null)"
    rc_str=$?
    out_file="$(fixture_gh comments.matrix.file "$input_file" 2>&1 </dev/null)"
    rc_file=$?
    rm -f "$input_file"
  }

  local case_payload case_expect
  while IFS='|' read -r case_payload case_expect; do
    [ -z "$case_payload" ] && continue
    run_both "$case_payload"
    if [ "$case_expect" = "ok" ]; then
      assert_eq "$rc_str" "0" || return 1
      assert_eq "$rc_file" "$rc_str" || return 1
      assert_eq "$(jq -c '.data' <<< "$out_str")" "$(jq -c '.data' <<< "$out_file")" || return 1
    else
      assert_eq "$rc_str" "1" || return 1
      assert_eq "$rc_file" "$rc_str" || return 1
      assert_json_eq "$out_str" '.error.code' "$case_expect" || return 1
      assert_json_eq "$out_file" '.error.code' "$case_expect" || return 1
    fi
  done <<'CASES'
{}|MISSING_INPUT
{"number":null}|MISSING_REQUIRED_FIELD
{"number":""}|MISSING_REQUIRED_FIELD
{"number":"x"}|TYPE_MISMATCH
{"number":1}|ok
{"number":1,"label":null}|ok
{"number":1,"label":""}|ok
{"number":1,"label":3}|TYPE_MISMATCH
CASES
)

# Update-style actions distinguish an absent optional field ("keep the
# current value") from an explicit null ("clear it"): the null must pass
# validation and reach the action with the key present.
test_optional_null_contract_preserved () (
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  local schema='{"number":{"type":"number","required":true},"title":{"type":"string","required":false},"body":{"type":"string","required":false}}'
  register_mock_action contract.optional.null "$schema" '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
envelope_ok "contract.optional.null" "{}" "$1"'

  local input_file output
  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"number":1,"body":null}' > "$input_file"
  if ! output="$(fixture_gh contract.optional.null "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "explicit null on an optional field unexpectedly failed validation"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.number' "1" || return 1
  assert_json_eq "$output" '(.data.body == null)' "true" || return 1
  assert_json_eq "$output" '.data | has("body") | tostring' "true" || return 1
  assert_json_eq "$output" '.data | has("title") | tostring' "false" || return 1
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

register_large_envelope_mock() {
  local mock
  mock="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
payload="$(jq -cn --argjson len 160000 '"x" * $len | {patch: .}')"
envelope_ok "contract.large.envelope" "{}" "$payload"
EOF
)"
  register_mock_action contract.large.envelope "$mock"
}

# The Issue #152 reproduction: a 160,000-character payload used to abort the
# dispatcher with "jq: Argument list too long" (exit 126) because envelope_ok
# passed the whole data JSON as a single jq argument. The envelope now routes
# data through a temp file, so the same payload yields a valid envelope.
test_envelope_large_payload() {
  register_large_envelope_mock

  local input_file output line_count

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  if ! output="$(fixture_gh contract.large.envelope "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "large envelope unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  line_count="$(printf '%s\n' "$output" | wc -l)"
  assert_eq "$line_count" "1" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.patch | length' "160000" || return 1
}

register_bounded_read_mock() {
  local mock
  mock="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
source "$COMMON_DIR/file.sh"
data="$(jq -cn --argjson count "$CONTRACT_BOUND_ITEMS" --argjson patch_len "$CONTRACT_BOUND_PATCH_LEN" --argjson urls "${CONTRACT_BOUND_URLS:-0}" \
  '[range(0; $count) | {
    sha: ("a" * 40),
    filename: ("file-\(.).txt"),
    status: "modified",
    additions: 1,
    deletions: 0,
    patch: (if $patch_len > 0 then ("x" * $patch_len) else null end)
  }]
  | if $urls == 1 then
      map(. + {
        blob_url: ("https://github.com/u7chan/agent-harness/blob/abc123def4567890abcdef1234567890abcdef12/" + .filename),
        raw_url: ("https://github.com/u7chan/agent-harness/raw/abc123def4567890abcdef1234567890abcdef12/" + .filename),
        contents_url: ("https://api.github.com/repos/u7chan/agent-harness/contents/" + .filename + "?ref=abc123def4567890abcdef1234567890abcdef12")
      })
    else . end')"
if ! data="$(echo "$data" | bounded_read_output "contract-bounded" 'map(del(.patch))' 'patch')"; then
  envelope_fail "contract.bounded.read" "ARTIFACT_ERROR" "Failed to save the complete data artifact" false
  exit 1
fi
envelope_ok "contract.bounded.read" "{}" "$data"
EOF
)"
  register_mock_action contract.bounded.read "$mock"
}

# Small read responses keep the inline contract byte for byte: the data stays
# an inline array and the patch field is kept.
test_bounded_read_small_inline() (
  setup_fixture
  trap teardown_fixture EXIT
  register_bounded_read_mock

  local input_file output

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  if ! output="$(CONTRACT_BOUND_ITEMS=10 CONTRACT_BOUND_PATCH_LEN=20 fixture_gh contract.bounded.read "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "bounded read unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | type' "array" || return 1
  assert_json_eq "$output" '.data | length' "10" || return 1
  assert_json_eq "$output" '.data[0].patch' "xxxxxxxxxxxxxxxxxxxx" || return 1
)

# Large read responses exceed the conversation boundary: the envelope stays
# valid, the inline view drops the omitted field and caps the item count, and
# the complete data is kept in an artifact that survives the dispatcher exit.
test_bounded_read_large_artifact() (
  setup_fixture
  trap teardown_fixture EXIT
  register_bounded_read_mock

  local input_file output output_file stdout_bytes

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  # 120 items x 2000-character patches (~245 KB full data) against the default
  # 20000-byte inline budget and a 50-item inline cap.
  if ! output="$(CONTRACT_BOUND_ITEMS=120 CONTRACT_BOUND_PATCH_LEN=2000 GH_INLINE_MAX_ITEMS=50 fixture_gh contract.bounded.read "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "bounded read unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.truncated' "true" || return 1
  assert_json_eq "$output" '.data.total_count' "120" || return 1
  assert_json_eq "$output" '.data.inline_count' "50" || return 1
  assert_json_eq "$output" '.data.omitted' "patch" || return 1
  assert_json_eq "$output" '.data.items | length' "50" || return 1
  assert_json_eq "$output" '[.data.items[] | has("patch")] | any | not' "true" || return 1
  assert_json_eq "$output" '.data.size_bytes > 20000' "true" || return 1

  output_file="$(printf '%s\n' "$output" | jq -r '.data.output_file')"
  case "$output_file" in
    /tmp/gh-artifacts-*/*) ;;
    *)
      echo "artifact not saved under the default artifact dir: $output_file"
      return 1
      ;;
  esac

  # The dispatcher process has exited; the artifact must still be readable and
  # hold the complete data: every item, patches included.
  if [ ! -r "$output_file" ]; then
    echo "artifact not readable after dispatcher exit: $output_file"
    return 1
  fi
  assert_eq "$(jq 'length' "$output_file")" "120" || return 1
  assert_eq "$(jq '.[0].patch | length' "$output_file")" "2000" || return 1

  # Conversation bytes regression: the envelope returned to the caller must
  # stay small even when the full data is two orders of magnitude larger.
  stdout_bytes="$(printf '%s' "$output" | wc -c)"
  if [ "$stdout_bytes" -ge 16000 ]; then
    echo "envelope too large for the conversation: $stdout_bytes bytes"
    return 1
  fi

  # Deleting the artifact explicitly is the caller's responsibility.
  rm -f "$output_file"
)

# The item cap only applies beyond the byte boundary: many small items within
# the inline budget are returned inline in full.
test_bounded_read_items_within_budget() (
  setup_fixture
  trap teardown_fixture EXIT
  register_bounded_read_mock

  local input_file output

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  # 120 items x 1-character patches: ~16 KB total, within the default byte
  # budget, above GH_INLINE_MAX_ITEMS=50 but never artifacted.
  if ! output="$(CONTRACT_BOUND_ITEMS=120 CONTRACT_BOUND_PATCH_LEN=1 GH_INLINE_MAX_ITEMS=50 fixture_gh contract.bounded.read "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "bounded read unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | type' "array" || return 1
  assert_json_eq "$output" '.data | length' "120" || return 1
  assert_json_eq "$output" '.data[0].patch' "x" || return 1
)

# The inline view is capped by bytes as well as items: light items with long
# fields (40-character SHAs, three URLs each) cannot flood the conversation
# through the item cap alone.
test_bounded_read_inline_bytes_cap() (
  setup_fixture
  trap teardown_fixture EXIT
  register_bounded_read_mock

  local input_file output output_file data_bytes

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  # 120 items with 40-character SHAs and three URLs each: the patch-free
  # items stay far below the 100-item cap, so only the byte cap can bound the
  # conversation output.
  if ! output="$(CONTRACT_BOUND_ITEMS=120 CONTRACT_BOUND_PATCH_LEN=0 CONTRACT_BOUND_URLS=1 fixture_gh contract.bounded.read "$input_file" 2>&1)"; then
    rm -f "$input_file"
    echo "bounded read unexpectedly failed"
    return 1
  fi
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.truncated' "true" || return 1
  assert_json_eq "$output" '.data.total_count' "120" || return 1
  assert_json_eq "$output" '.data.inline_count < .data.total_count' "true" || return 1
  assert_json_eq "$output" '.data.inline_count == (.data.items | length)' "true" || return 1
  assert_json_eq "$output" '[.data.items[] | has("patch")] | any | not' "true" || return 1

  # The bytes returned to the conversation stay within the inline budget.
  data_bytes="$(printf '%s' "$output" | jq '.data | tostring | utf8bytelength')"
  if [ "$data_bytes" -ge 21000 ]; then
    echo "inline data too large for the conversation: $data_bytes bytes"
    return 1
  fi

  # The artifact holds every item with all fields.
  output_file="$(printf '%s\n' "$output" | jq -r '.data.output_file')"
  assert_eq "$(jq 'length' "$output_file")" "120" || return 1
  assert_eq "$(jq '[.[] | has("blob_url")] | any' "$output_file")" "true" || return 1
  rm -f "$output_file"
)

# A failed artifact save must not surface as a truncated success: with an
# unwritable GH_ARTIFACT_DIR the action reports ARTIFACT_ERROR.
test_bounded_read_artifact_failure() (
  setup_fixture
  trap teardown_fixture EXIT
  register_bounded_read_mock

  local input_file output rc

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  # GH_ARTIFACT_DIR=/dev/null: the artifact cannot be created, so the action
  # must fail instead of returning truncated data with an empty output_file.
  output="$(CONTRACT_BOUND_ITEMS=120 CONTRACT_BOUND_PATCH_LEN=2000 GH_ARTIFACT_DIR=/dev/null fixture_gh contract.bounded.read "$input_file" 2>/dev/null)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "ARTIFACT_ERROR" || return 1
)

register_artifact_mock() {
  register_mock_action contract.artifact.write '#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR/../common"
source "$COMMON_DIR/envelope.sh"
source "$COMMON_DIR/file.sh"
scratch_dir="${GH_TEMP_DIR:-}"
info="$(printf "%s\\n" "artifact-body-contract" | large_output "contract-artifact")"
data="$(jq -nc --argjson artifact "$info" --arg scratch_dir "$scratch_dir" \
  "{artifact: \$artifact, scratch_dir: \$scratch_dir}")"
envelope_ok "contract.artifact.write" "{}" "$data"'
}

# Artifacts returned to callers must survive the dispatcher EXIT trap while
# internal scratch is still cleaned up. Fully offline via the fixture.
test_artifact_survives_dispatcher_exit() (
  setup_fixture
  trap teardown_fixture EXIT

  register_artifact_mock

  local input_file output output_file scratch_dir body

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"
  output="$(unset GH_TEMP_DIR GH_ARTIFACT_DIR; fixture_gh contract.artifact.write "$input_file" 2>&1)"
  rm -f "$input_file"

  assert_json_eq "$output" '.status' "ok" || return 1
  output_file="$(printf '%s\n' "$output" | jq -r '.data.artifact.output_file')"
  scratch_dir="$(printf '%s\n' "$output" | jq -r '.data.scratch_dir')"
  if [ -z "$output_file" ] || [ "$output_file" = "null" ]; then
    echo "no output_file returned"
    return 1
  fi
  if [ -z "$scratch_dir" ] || [ "$scratch_dir" = "null" ]; then
    echo "no scratch_dir returned"
    return 1
  fi
  case "$output_file" in
    "$scratch_dir"/*)
      echo "artifact saved inside dispatcher scratch dir: $output_file"
      return 1
      ;;
  esac
  case "$output_file" in
    /tmp/gh-artifacts-*/*) ;;
    *)
      echo "artifact not saved under the default artifact dir: $output_file"
      return 1
      ;;
  esac

  # The dispatcher process has exited; the artifact must still be readable.
  if ! body="$(cat "$output_file")"; then
    echo "artifact not readable after dispatcher exit: $output_file"
    return 1
  fi
  assert_eq "$body" "artifact-body-contract" || return 1

  # Internal scratch is still removed by the dispatcher EXIT trap.
  if [ -e "$scratch_dir" ]; then
    echo "dispatcher scratch dir was not cleaned: $scratch_dir"
    return 1
  fi

  # Deleting the artifact explicitly is the caller's responsibility.
  rm -f "$output_file"
  if [ -e "$output_file" ]; then
    echo "artifact was not deleted: $output_file"
    return 1
  fi
)

# Caller-provided directories: a GH_TEMP_DIR with the cleanup marker is still
# removed on exit, a marker-less one survives (escape hatch), and
# GH_ARTIFACT_DIR pins the artifact save location.
test_artifact_caller_dirs() (
  setup_fixture
  trap teardown_fixture EXIT

  register_artifact_mock

  local input_file output output_file
  local marked_scratch unmarked_scratch artifact_dir

  artifact_dir="$FIXTURE_DIR/artifacts"
  marked_scratch="$FIXTURE_DIR/scratch-marked"
  unmarked_scratch="$FIXTURE_DIR/scratch-unmarked"
  mkdir -p "$marked_scratch" "$unmarked_scratch"
  touch "$marked_scratch/.gh-tmp-marker"

  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{}' > "$input_file"

  output="$(export GH_TEMP_DIR="$marked_scratch" GH_ARTIFACT_DIR="$artifact_dir"; fixture_gh contract.artifact.write "$input_file" 2>&1)"
  assert_json_eq "$output" '.status' "ok" || return 1
  output_file="$(printf '%s\n' "$output" | jq -r '.data.artifact.output_file')"
  case "$output_file" in
    "$artifact_dir"/*) ;;
    *)
      echo "artifact not saved under caller-provided GH_ARTIFACT_DIR: $output_file"
      return 1
      ;;
  esac
  if [ ! -r "$output_file" ]; then
    echo "artifact not readable after dispatcher exit: $output_file"
    return 1
  fi
  if [ -e "$marked_scratch" ]; then
    echo "marked caller scratch dir was not cleaned: $marked_scratch"
    return 1
  fi
  rm -f "$output_file"

  output="$(export GH_TEMP_DIR="$unmarked_scratch" GH_ARTIFACT_DIR="$artifact_dir"; fixture_gh contract.artifact.write "$input_file" 2>&1)"
  assert_json_eq "$output" '.status' "ok" || return 1
  if [ ! -d "$unmarked_scratch" ]; then
    echo "unmarked caller scratch dir should survive: $unmarked_scratch"
    return 1
  fi
  rm -f "$input_file"
)

test_recheck_action_contracts() {
  "$SCRIPT_DIR/recheck-actions.sh" >/dev/null
}

test_workflow_runs_contracts() {
  "$SCRIPT_DIR/workflow-runs.sh" >/dev/null
}

test_attach_contracts() {
  "$SCRIPT_DIR/attach.sh" >/dev/null
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

  # Group C2: catalog auth flags and unified input validation (Issue #154)
  run_test test_requires_auth_false_runs_without_auth
  run_test test_required_number_null_rejected_before_dispatch
  run_test test_requires_auth_true_single_auth_call
  run_test test_input_semantics_match_both_entrypoints
  run_test test_optional_null_contract_preserved

  # Group D: envelope and dispatch
  run_test test_envelope
  run_test test_dispatch
  run_test test_envelope_large_payload
  run_test test_bounded_read_small_inline
  run_test test_bounded_read_large_artifact
  run_test test_bounded_read_items_within_budget
  run_test test_bounded_read_inline_bytes_cap
  run_test test_bounded_read_artifact_failure
  run_test test_artifact_survives_dispatcher_exit
  run_test test_artifact_caller_dirs
  run_test test_recheck_action_contracts
  run_test test_workflow_runs_contracts
  run_test test_attach_contracts

  teardown_fixture
  trap - EXIT

  print_summary
}

main
