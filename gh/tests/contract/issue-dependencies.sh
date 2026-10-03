#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Stateful, symmetric relationship mock. The dispatcher, catalog, action
# scripts, and common helpers are real; only gh/sleep are replaced.
setup_dependencies_fixture() {
  setup_fixture
  local action
  for action in issue.get issue.dependencies.add issue.dependencies.remove; do
    cp "$GH_ROOT/scripts/actions/$action.sh" "$FIXTURE_DIR/scripts/actions/$action.sh"
  done
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if args[:2] == ["repo", "view"]:
    print("u7chan/agent-harness")
    sys.exit(0)
if args[:1] != ["api"]:
    sys.exit(64)

with open(os.environ["MOCK_GH_STATE"], encoding="utf-8") as f:
    state = json.load(f)


def save():
    with open(os.environ["MOCK_GH_STATE"], "w", encoding="utf-8") as f:
        json.dump(state, f)


def output(value):
    print(json.dumps(value, separators=(",", ":")))


def log(value):
    value["argv"] = args
    with open(os.environ["MOCK_GH_CALLS"], "a", encoding="utf-8") as f:
        f.write(json.dumps(value) + "\n")


def field(name):
    return next((arg[len(name) + 1:] for arg in args if arg.startswith(name + "=")), "")


def node(number):
    return {"number": number, "title": f"Issue {number}", "state": "OPEN",
            "url": f"https://github.com/u7chan/agent-harness/issues/{number}"}


def connection(numbers):
    return {"nodes": [node(n) for n in numbers[:100]], "totalCount": len(numbers),
            "pageInfo": {"hasNextPage": len(numbers) > 100}}


if "graphql" not in args:
    endpoint = next(arg for arg in args if arg.startswith("repos/"))
    number = int(endpoint.rsplit("/", 1)[1])
    log({"kind": "rest", "number": number})
    if state.get("rest_failure_number") == number:
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    issue = {**node(number), "id": number + 1000, "node_id": f"I_{number}",
             "state": "open", "html_url": node(number)["url"], "body": "fixture",
             "user": {"login": "u7chan"}, "labels": [], "assignees": [],
             "milestone": None, "comments": 0}
    if state.get("pr_number") == number:
        issue["pull_request"] = {"url": "fixture"}
    if state.get("invalid_node_number") == number:
        del issue["node_id"]
    output(issue)
    sys.exit(0)

query = field("query")
number = int(field("issueId").removeprefix("I_"))
if query.startswith("query"):
    log({"kind": "read", "number": number, "query": query})
    state["reads"] = state.get("reads", 0) + 1
    save()
    if state["reads"] <= state.get("read_retry_until", 0):
        print("gh: Service Unavailable (HTTP 503)", file=sys.stderr)
        sys.exit(1)
    if state.get("read_errors") or (state.get("post_read_errors") and state.get("mutations")):
        output({"data": {"node": None}, "errors": [{"message": "denied"}]})
        sys.exit(0)
    pairs = state.get("pairs", [])
    issue = {"__typename": "Issue", "id": f"I_{number}", "number": number,
             "repository": {"nameWithOwner": "u7chan/agent-harness"},
             "blockedBy": connection([b for i, b in pairs if i == number]),
             "blocking": connection([i for i, b in pairs if b == number])}
    shape = state.get("after_shape") if state.get("mutations") else state.get("read_shape")
    if shape == "missing_connection":
        del issue["blockedBy"]
    elif shape == "missing_nodes":
        del issue["blockedBy"]["nodes"]
    elif shape == "missing_page_info":
        del issue["blocking"]["pageInfo"]
    elif shape == "nonboolean_page_info":
        issue["blocking"]["pageInfo"]["hasNextPage"] = "false"
    elif shape == "wrong_id":
        issue["id"] = "I_999"
    elif shape == "wrong_type":
        issue["__typename"] = "PullRequest"
    elif shape == "wrong_repo":
        issue["repository"]["nameWithOwner"] = "elsewhere/repo"
    elif shape == "null_node":
        issue = None
    elif shape == "missing_data":
        output({})
        sys.exit(0)
    output({"data": {"node": issue}})
    sys.exit(0)

mutation = "addBlockedBy" if "addBlockedBy" in query else "removeBlockedBy"
blocker = int(field("blockingIssueId").removeprefix("I_"))
log({"kind": "mutation", "mutation": mutation, "issue": number, "blocker": blocker})
state["mutations"] = state.get("mutations", 0) + 1
save()
if (number == blocker or state.get("mutation_errors") or
        state.get("fail_mutation_at") == state["mutations"]):
    output({"errors": [{"message": "raw secret/error must not be forwarded"}]})
    sys.exit(0)
if state.get("mutation_transport_error"):
    print("gh: Service Unavailable (HTTP 503)", file=sys.stderr)
    sys.exit(1)
if state.get("malformed_mutation"):
    output({"data": {mutation: None}})
    sys.exit(0)
if not state.get("ignore_mutations"):
    pair = [number, blocker]
    pairs = state.setdefault("pairs", [])
    if mutation == "addBlockedBy" and pair not in pairs:
        pairs.append(pair)
    if mutation == "removeBlockedBy" and pair in pairs:
        pairs.remove(pair)
    save()
output({"data": {mutation: {"clientMutationId": None}}})
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
  cat > "$FIXTURE_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_SLEEP_LOG:?}"
SH
  chmod +x "$FIXTURE_DIR/bin/sleep"
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json" MOCK_GH_CALLS="$FIXTURE_DIR/calls.jsonl"
  export MOCK_SLEEP_LOG="$FIXTURE_DIR/sleep.log"
  printf '{"pairs":[]}\n' > "$MOCK_GH_STATE"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_SLEEP_LOG"
}

set_state() {
  printf '%s\n' "$1" > "$MOCK_GH_STATE"
}

dispatch_dependencies() {
  local action="$1" payload="$2"
  printf '%s\n' "$payload" > "$FIXTURE_DIR/input.json"
  output="$(fixture_gh "$action" "$FIXTURE_DIR/input.json" 2>"$FIXTURE_DIR/stderr")" && rc=0 || rc=$?
}

assert_result() {
  assert_eq "$rc" "$1" || return 1
  assert_json_eq "$output" '.status' "$2" || return 1
  if [ "$#" -gt 2 ]; then assert_json_eq "$output" '.error.code' "$3" || return 1; fi
}

mutation_count() {
  jq -s '[.[] | select(.kind == "mutation")] | length' "$MOCK_GH_CALLS"
}

test_add_both_directions_and_idempotency() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local payload='{"number":200,"blocked_by":[201,201],"blocking":[202,202],"grant":"write"}'
  dispatch_dependencies issue.dependencies.add "$payload"
  assert_result 0 ok || return 1
  assert_json_eq "$output" '.data.blockedBy.nodes[0].number' 201 || return 1
  assert_json_eq "$output" '.data.blocking.nodes[0].number' 202 || return 1
  assert_json_eq "$output" '.data.blockedBy.nodes[0].state' open || return 1
  assert_json_eq "$output" '.data.blockedBy.nodes[0].html_url' 'https://github.com/u7chan/agent-harness/issues/201' || return 1
  assert_eq "$(jq -cs '[.[] | select(.kind == "mutation") | [.mutation,.issue,.blocker]]' "$MOCK_GH_CALLS")" \
    '[["addBlockedBy",200,201],["addBlockedBy",202,200]]' || return 1
  assert_eq "$(jq -cs '[.[] | select(.kind == "rest") | .number] | sort' "$MOCK_GH_CALLS")" '[200,201,202]' || return 1
  dispatch_dependencies issue.dependencies.add "$payload"
  assert_result 0 already_applied || return 1
  assert_eq "$(mutation_count)" 2 || return 1
)

test_remove_both_directions_and_symmetry() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  set_state '{"pairs":[[200,201],[202,200]]}'
  local payload='{"number":200,"blocked_by":[201],"blocking":[202],"grant":"write"}'
  dispatch_dependencies issue.dependencies.remove "$payload"
  assert_result 0 ok || return 1
  assert_eq "$(jq -cs '[.[] | select(.kind == "mutation") | [.mutation,.issue,.blocker]]' "$MOCK_GH_CALLS")" \
    '[["removeBlockedBy",200,201],["removeBlockedBy",202,200]]' || return 1
  dispatch_dependencies issue.get '{"number":201}'
  assert_result 0 ok || return 1
  assert_json_eq "$output" '.data.blocking.totalCount' 0 || return 1
  dispatch_dependencies issue.get '{"number":202}'
  assert_result 0 ok || return 1
  assert_json_eq "$output" '.data.blockedBy.totalCount' 0 || return 1
  dispatch_dependencies issue.dependencies.remove "$payload"
  assert_result 0 already_applied || return 1
  assert_eq "$(mutation_count)" 2 || return 1
)

test_remove_missing_is_noop() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  dispatch_dependencies issue.dependencies.remove '{"number":200,"blocked_by":[201],"grant":"write"}'
  assert_result 0 already_applied || return 1
  assert_eq "$(mutation_count)" 0 || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "rest")] | length' "$MOCK_GH_CALLS")" 1 || return 1
)

test_only_changed_relationships_are_mutated() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  set_state '{"pairs":[[200,201]]}'
  dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"blocking":[202],"grant":"write"}'
  assert_result 0 ok || return 1
  assert_eq "$(mutation_count)" 1 || return 1
  assert_eq "$(jq -cs '[.[] | select(.kind == "rest") | .number]' "$MOCK_GH_CALLS")" '[200,202]' || return 1
)

test_dependency_input_validation() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local action payload
  for action in issue.dependencies.add issue.dependencies.remove; do
    for payload in '{"number":200,"grant":"write"}' \
        '{"number":200,"blocked_by":[],"blocking":[],"grant":"write"}' \
        '{"number":200,"blocked_by":null,"grant":"write"}'; do
      dispatch_dependencies "$action" "$payload"
      assert_result 1 failed MISSING_REQUIRED_FIELD || return 1
    done
    dispatch_dependencies "$action" '{"number":200,"blockedBy":[201],"grant":"write"}'
    assert_result 1 failed UNKNOWN_FIELDS || return 1
    dispatch_dependencies "$action" '{"number":200,"blocked_by":"201","grant":"write"}'
    assert_result 1 failed TYPE_MISMATCH || return 1
    dispatch_dependencies "$action" '{"number":200,"blocked_by":[201],"grant":"read"}'
    assert_result 1 failed GRANT_INSUFFICIENT || return 1
    dispatch_dependencies "$action" '{"number":200,"blocked_by":[201]}'
    assert_result 1 failed MISSING_REQUIRED_FIELD || return 1
    for payload in '{"number":0,"blocking":[201],"grant":"write"}' \
        '{"number":1.5,"blocking":[201],"grant":"write"}' \
        '{"number":200,"blocked_by":[0],"grant":"write"}' \
        '{"number":200,"blocking":[-1],"grant":"write"}' \
        '{"number":200,"blocked_by":[1.5],"grant":"write"}' \
        '{"number":200,"blocking":[null],"grant":"write"}' \
        '{"number":200,"blocking":["https://github.com/elsewhere/repo/issues/1"],"grant":"write"}'; do
      dispatch_dependencies "$action" "$payload"
      assert_result 1 failed TARGET_ERROR || return 1
    done
  done
  assert_eq "$(wc -l < "$MOCK_GH_CALLS")" 0 || return 1
)

test_graphql_zero_exit_errors_fail_closed() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  set_state '{"mutation_errors":true}'
  dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"grant":"write"}'
  assert_result 1 failed API_ERROR || return 1
  assert_eq "$(mutation_count)" 1 || return 1
  if printf '%s\n' "$output" | grep -q 'raw secret'; then return 1; fi
)

test_self_reference_is_api_error() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[200],"grant":"write"}'
  assert_result 1 failed API_ERROR || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "rest")] | length' "$MOCK_GH_CALLS")" 1 || return 1
)

test_invalid_peers_fail_before_any_write() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local mode code
  for mode in pr_number invalid_node_number rest_failure_number; do
    if [ "$mode" = pr_number ]; then code=NOT_FOUND; else code=API_ERROR; fi
    set_state "{\"$mode\":202}"
    dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"blocking":[202],"grant":"write"}'
    assert_result 1 failed "$code" || return 1
    assert_eq "$(mutation_count)" 0 || return 1
  done
)

test_unverified_write_is_unknown_outcome() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local mode
  for mode in ignore_mutations post_read_errors mutation_transport_error malformed_mutation; do
    set_state "{\"$mode\":true}"
    : > "$MOCK_GH_CALLS"
    dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"grant":"write"}'
    assert_result 1 unknown_outcome || return 1
    assert_eq "$(mutation_count)" 1 || return 1
  done
  assert_eq "$(wc -l < "$MOCK_SLEEP_LOG")" 0 || return 1
)

test_partial_batch_is_unknown_outcome() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  set_state '{"fail_mutation_at":2}'
  dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"blocking":[202,203],"grant":"write"}'
  assert_result 1 unknown_outcome || return 1
  assert_eq "$(mutation_count)" 2 || return 1
  assert_eq "$(jq -c '.pairs' "$MOCK_GH_STATE")" '[[200,201]]' || return 1
)

test_unverifiable_connections_fail_closed() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local shape
  for shape in missing_connection missing_nodes missing_page_info nonboolean_page_info \
      wrong_id wrong_type wrong_repo null_node missing_data; do
    set_state "{\"read_shape\":\"$shape\"}"
    dispatch_dependencies issue.get '{"number":200}'
    assert_result 1 failed API_ERROR || return 1
    dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"grant":"write"}'
    assert_result 1 failed API_ERROR || return 1
    assert_eq "$(mutation_count)" 0 || return 1
    set_state "{\"after_shape\":\"$shape\"}"
    : > "$MOCK_GH_CALLS"
    dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[201],"grant":"write"}'
    assert_result 1 unknown_outcome || return 1
    : > "$MOCK_GH_CALLS"
  done
)

test_issue_get_returns_bounded_connections() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  jq -nc '{pairs: ([range(1000;1101) | [200,.]] + [range(2000;2101) | [.,200]])}' > "$MOCK_GH_STATE"
  dispatch_dependencies issue.get '{"number":200,"grant":"read"}'
  assert_result 0 ok || return 1
  assert_json_eq "$output" '.data.number' 200 || return 1
  assert_json_eq "$output" '.data.body' fixture || return 1
  assert_json_eq "$output" '.data.blockedBy.nodes | length' 100 || return 1
  assert_json_eq "$output" '.data.blockedBy.totalCount' 101 || return 1
  assert_json_eq "$output" '.data.blockedBy.hasNextPage | tostring' true || return 1
  assert_json_eq "$output" '.data.blocking.nodes | length' 100 || return 1
  assert_json_eq "$output" '.data.blocking.totalCount' 101 || return 1
  assert_json_eq "$output" '.data.blocking.hasNextPage | tostring' true || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "read")] | length' "$MOCK_GH_CALLS")" 1 || return 1
  jq -e -s 'all(.[] | select(.kind == "read"); (.query | contains("blockedBy(first: 100)")) and (.query | contains("blocking(first: 100)")))' "$MOCK_GH_CALLS" >/dev/null || return 1
)

test_truncation_never_proves_absence() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  local action
  jq -nc '{pairs: [range(1000;1102) | [200,.]]}' > "$MOCK_GH_STATE"
  for action in issue.dependencies.add issue.dependencies.remove; do
    dispatch_dependencies "$action" '{"number":200,"blocked_by":[1101],"grant":"write"}'
    assert_result 1 failed API_ERROR || return 1
    assert_eq "$(mutation_count)" 0 || return 1
  done
  # Visible presence is enough to skip an add, even on a truncated list.
  dispatch_dependencies issue.dependencies.add '{"number":200,"blocked_by":[1000],"grant":"write"}'
  assert_result 0 already_applied || return 1
  # Removing a visible member cannot prove its absence from the remaining
  # truncated list without following cursors, so it must remain unknown.
  dispatch_dependencies issue.dependencies.remove '{"number":200,"blocked_by":[1000],"grant":"write"}'
  assert_result 1 unknown_outcome || return 1
)

test_graphql_reads_retry_with_unchanged_arguments() (
  setup_dependencies_fixture
  trap teardown_fixture EXIT
  set_state '{"read_retry_until":2}'
  dispatch_dependencies issue.get '{"number":200}'
  assert_result 0 ok || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n2')" || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "read")] | length' "$MOCK_GH_CALLS")" 3 || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "read") | .argv] | unique | length' "$MOCK_GH_CALLS")" 1 || return 1
  set_state '{"read_errors":true}'
  : > "$MOCK_GH_CALLS"
  dispatch_dependencies issue.get '{"number":200}'
  assert_result 1 failed API_ERROR || return 1
  assert_eq "$(jq -s '[.[] | select(.kind == "read")] | length' "$MOCK_GH_CALLS")" 1 || return 1
)

main() {
  echo "=== issue dependency contract tests ==="
  run_test test_add_both_directions_and_idempotency
  run_test test_remove_both_directions_and_symmetry
  run_test test_remove_missing_is_noop
  run_test test_only_changed_relationships_are_mutated
  run_test test_dependency_input_validation
  run_test test_graphql_zero_exit_errors_fail_closed
  run_test test_self_reference_is_api_error
  run_test test_invalid_peers_fail_before_any_write
  run_test test_unverified_write_is_unknown_outcome
  run_test test_partial_batch_is_unknown_outcome
  run_test test_unverifiable_connections_fail_closed
  run_test test_issue_get_returns_bounded_connections
  run_test test_truncation_never_proves_absence
  run_test test_graphql_reads_retry_with_unchanged_arguments
  print_summary
}

main
