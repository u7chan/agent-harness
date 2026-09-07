#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Issue #172 contract tests for issue.subissues.reorder.
#
# Fully offline: a mock gh CLI on PATH serves `gh repo view` (target
# resolution) and the sub_issues REST endpoints behind a state file, and logs
# every invocation so the tests can pin the number of PATCH requests.
# MOCK_REORDER_PATCH_MODE mutates the list after a successful PATCH to
# simulate a concurrent change between the PATCH and the post-write re-fetch:
#   drop_anchor  - remove the after_id/before_id reference sub-issue
#   drop_target  - remove the moved sub-issue
write_reorder_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_file = os.environ["MOCK_REORDER_STATE"]
calls_file = os.environ.get("MOCK_REORDER_CALLS", "")
patch_mode = os.environ.get("MOCK_REORDER_PATCH_MODE", "")


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


args = sys.argv[1:]
if not args:
    fail("unsupported mock command")

if args[0] == "auth" and args[1] == "status":
    print("github.com\n  ✓ Logged in to github.com account contract-test")
    sys.exit(0)

if args[0] == "repo" and args[1] == "view":
    print("u7chan/agent-harness")
    sys.exit(0)

if args[0] != "api":
    fail("unsupported mock command")

with open(state_file, encoding="utf-8") as f:
    state = json.load(f)

method = "GET"
endpoint = ""
body = None
i = 1
while i < len(args):
    arg = args[i]
    if arg == "--method":
        method = args[i + 1]
        i += 2
    elif arg == "--input":
        with open(args[i + 1], encoding="utf-8") as f:
            body = json.load(f)
        i += 2
    elif arg in ("-H", "-f", "-F"):
        i += 2
    elif arg.startswith("repos/"):
        endpoint = arg
        i += 1
    else:
        i += 1

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(method + " " + endpoint + "\n")

if method == "GET" and endpoint.endswith("/sub_issues"):
    output(state["sub_issues"])
    sys.exit(0)

if method == "PATCH" and endpoint.endswith("/sub_issues/priority"):
    if body is None:
        fail("HTTP 422: PATCH without a body")
    sub_issue_id = body["sub_issue_id"]
    after_id = body.get("after_id")
    before_id = body.get("before_id")
    current = state["sub_issues"]
    ids = [item["id"] for item in current]
    if sub_issue_id not in ids:
        fail("HTTP 422: sub_issue_id is not in the list")
    ref_id = after_id if after_id is not None else before_id
    if ref_id is None:
        fail("HTTP 422: no anchor id")
    if ref_id == sub_issue_id:
        fail("HTTP 422: self reference")
    if ref_id not in ids:
        fail("HTTP 422: anchor id is not in the list")
    target_item = next(item for item in current if item["id"] == sub_issue_id)
    rest = [item for item in current if item["id"] != sub_issue_id]
    rest_ids = [item["id"] for item in rest]
    if after_id is not None:
        position = rest_ids.index(after_id) + 1
    else:
        position = rest_ids.index(before_id)
    rest.insert(position, target_item)
    if patch_mode == "drop_anchor":
        rest = [item for item in rest if item["id"] != ref_id]
    elif patch_mode == "drop_target":
        rest = [item for item in rest if item["id"] != sub_issue_id]
    state["sub_issues"] = rest
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)
    output({})
    sys.exit(0)

fail("unsupported endpoint: " + method + " " + endpoint)
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# Copies the real action under test into the fixture and wires the mock gh
# CLI, the state file and the invocation log.
setup_reorder_fixture() {
  setup_fixture
  cp "$GH_ROOT/scripts/actions/issue.subissues.reorder.sh" \
    "$FIXTURE_DIR/scripts/actions/issue.subissues.reorder.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/issue.subissues.reorder.sh"
  write_reorder_mock_gh

  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_REORDER_STATE="$FIXTURE_DIR/state.json"
  export MOCK_REORDER_CALLS="$FIXTURE_DIR/calls.log"
  export MOCK_REORDER_PATCH_MODE=""
  : > "$MOCK_REORDER_CALLS"
}

# seed_reorder_sub_issues <id>... : the mock sub-issue list holding one item
# per id, in the given order.
seed_reorder_sub_issues() {
  local list_json="[]"
  local id
  for id in "$@"; do
    list_json="$(jq -nc --argjson list "$list_json" --argjson id "$id" \
      '$list + [{id: $id, number: $id, title: ("sub " + ($id | tostring)),
                 state: "open",
                 html_url: ("https://github.com/u7chan/agent-harness/issues/" + ($id | tostring))}]')"
  done
  jq -n --argjson list "$list_json" '{sub_issues: $list}' > "$MOCK_REORDER_STATE"
}

run_reorder() {
  local input_json="$1"
  local input_file
  local rc

  input_file="$(mktemp /tmp/gh-reorder-input-XXXXXX)"
  printf '%s\n' "$input_json" > "$input_file"
  fixture_gh "issue.subissues.reorder" "$input_file" 2>/dev/null
  rc=$?
  rm -f "$input_file"
  return "$rc"
}

reorder_patch_count() {
  grep -c '^PATCH ' "$MOCK_REORDER_CALLS" 2>/dev/null || true
}

# Both anchors given: pre-existing INVALID_INPUT contract, no API call.
test_reorder_both_anchors_invalid_input() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"after_id":101,"before_id":103,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_INPUT" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# No anchor given: pre-existing INVALID_INPUT contract, no API call.
test_reorder_neither_anchor_invalid_input() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_INPUT" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 2: after_id == sub_issue_id must fail without PATCH.
test_reorder_after_self_reference_invalid_input() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"after_id":102,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_INPUT" || return 1
  assert_contains "$output" "after_id must not equal sub_issue_id" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 2: before_id == sub_issue_id must fail without PATCH.
test_reorder_before_self_reference_invalid_input() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"before_id":102,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_INPUT" || return 1
  assert_contains "$output" "before_id must not equal sub_issue_id" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 1: a sub_issue_id that is not in the current list
# must fail without PATCH (an idempotent "already gone" reading does not
# apply to reorder).
test_reorder_absent_target_not_found_no_patch() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":999,"after_id":102,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "NOT_FOUND" || return 1
  assert_contains "$output" "999" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 3 (bug reproduction): an absent after_id used to
# degrade to index -1, so a head target looked already applied. It must now
# fail with NOT_FOUND and issue no PATCH.
test_reorder_absent_after_head_not_already_applied() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":101,"after_id":999,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "NOT_FOUND" || return 1
  assert_contains "$output" "after_id" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 1: an absent after_id with a non-head target used to
# reach the API; it must fail before any PATCH.
test_reorder_absent_after_mid_not_found_no_patch() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"after_id":999,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "NOT_FOUND" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 1: an absent before_id must fail without PATCH.
test_reorder_absent_before_not_found_no_patch() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":101,"before_id":999,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "NOT_FOUND" || return 1
  assert_contains "$output" "before_id" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 4: an already applied after move stays
# already_applied with no PATCH.
test_reorder_already_applied_after() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"after_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "already_applied" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 4: an already applied before move stays
# already_applied with no PATCH.
test_reorder_already_applied_before() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"before_id":103,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "already_applied" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 4: a head target already sitting directly before the
# reference stays already_applied (the legitimate head case).
test_reorder_already_applied_head_before() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":101,"before_id":102,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "already_applied" || return 1
  assert_eq "$(reorder_patch_count)" "0" || return 1
)

# Issue #172 acceptance 4: moving the tail sub-issue after the head succeeds.
test_reorder_move_after_ok() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":103,"after_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "101,103,102" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

# Issue #172 acceptance 4: moving the tail sub-issue before the head succeeds.
test_reorder_move_before_ok() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":103,"before_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "103,101,102" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

# Issue #172 acceptance 4: moving the head sub-issue after the tail succeeds.
test_reorder_move_after_tail_ok() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":101,"after_id":103,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "102,103,101" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

# Issue #172 acceptance 4: moving the middle sub-issue before the head
# succeeds.
test_reorder_move_before_head_ok() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"before_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "102,101,103" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

# Issue #172 acceptance 5 (bug reproduction): when the after_id reference
# disappears between the PATCH and the post-write re-fetch, the head
# position must not pass as success. Reported as unknown_outcome.
test_reorder_anchor_vanished_after_patch_unknown_outcome() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  export MOCK_REORDER_PATCH_MODE="drop_anchor"
  seed_reorder_sub_issues 102 101 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":102,"after_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "unknown_outcome" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "102,103" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

# Issue #172 acceptance 5: a target that vanishes after the PATCH is not a
# success either.
test_reorder_target_vanished_after_patch_unknown_outcome() (
  setup_reorder_fixture
  trap teardown_fixture EXIT
  export MOCK_REORDER_PATCH_MODE="drop_target"
  seed_reorder_sub_issues 101 102 103

  local output rc
  output="$(run_reorder '{"number":1,"sub_issue_id":103,"after_id":101,"grant":"write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "unknown_outcome" || return 1
  assert_json_eq "$output" '.data | map(.id) | join(",")' "101,102" || return 1
  assert_eq "$(reorder_patch_count)" "1" || return 1
)

main() {
  echo "=== issue.subissues.reorder contract tests ==="

  run_test test_reorder_both_anchors_invalid_input
  run_test test_reorder_neither_anchor_invalid_input
  run_test test_reorder_after_self_reference_invalid_input
  run_test test_reorder_before_self_reference_invalid_input
  run_test test_reorder_absent_target_not_found_no_patch
  run_test test_reorder_absent_after_head_not_already_applied
  run_test test_reorder_absent_after_mid_not_found_no_patch
  run_test test_reorder_absent_before_not_found_no_patch
  run_test test_reorder_already_applied_after
  run_test test_reorder_already_applied_before
  run_test test_reorder_already_applied_head_before
  run_test test_reorder_move_after_ok
  run_test test_reorder_move_before_ok
  run_test test_reorder_move_after_tail_ok
  run_test test_reorder_move_before_head_ok
  run_test test_reorder_anchor_vanished_after_patch_unknown_outcome
  run_test test_reorder_target_vanished_after_patch_unknown_outcome

  print_summary
}

main
