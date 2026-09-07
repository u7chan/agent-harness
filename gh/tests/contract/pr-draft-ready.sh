#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# A fake gh CLI serving the pr.draft / pr.ready API surface: the PR detail
# read (state/draft/merged injected from MOCK_GH_STATE) and the two GraphQL
# mutations, which flip draft in the state file so a re-run observes the new
# state (idempotency). Every invocation is logged; no real API is touched.
write_draft_ready_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_file = os.environ["MOCK_GH_STATE"]
calls_file = os.environ.get("MOCK_GH_CALLS")
gql_calls_file = os.environ.get("MOCK_GH_GQL_CALLS")


def load():
    with open(state_file, encoding="utf-8") as f:
        return json.load(f)


def save(state):
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def arg_value(prefix, default=None):
    for arg in sys.argv[1:]:
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return default


args = sys.argv[1:]
if not args:
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)
if args[0] == "repo" and args[1] == "view":
    if "--jq" in args:
        print("u7chan/agent-harness")
    else:
        output({"nameWithOwner": "u7chan/agent-harness"})
    sys.exit(0)
if args[0] != "api":
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

if args[1] == "graphql":
    query = arg_value("query=", "")
    if "convertPullRequestToDraft" in query:
        fingerprint = "convertPullRequestToDraft"
    elif "markPullRequestReadyForReview" in query:
        fingerprint = "markPullRequestReadyForReview"
    else:
        fingerprint = "other"
    if gql_calls_file:
        with open(gql_calls_file, "a", encoding="utf-8") as f:
            f.write("graphql " + fingerprint + "\n")
    state = load()
    pr = state.get("pr")
    if pr is None:
        output({"errors": [{"message": "no pr in mock state"}]})
        sys.exit(0)
    if fingerprint == "convertPullRequestToDraft":
        pr["draft"] = True
        save(state)
        output({"data": {"convertPullRequestToDraft": {"pullRequest": {"isDraft": True}}}})
    elif fingerprint == "markPullRequestReadyForReview":
        pr["draft"] = False
        save(state)
        output({"data": {"markPullRequestReadyForReview": {"pullRequest": {"isDraft": False}}}})
    else:
        output({"errors": [{"message": "unknown graphql query"}]})
    sys.exit(0)

endpoint = next((arg for arg in args[1:] if arg.startswith("repos/")), "")
method = "GET"
if "--method" in args:
    method = args[args.index("--method") + 1]

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(method + " " + endpoint + "\n")

if method == "GET" and endpoint == "repos/u7chan/agent-harness/pulls/200":
    output(load().get("pr"))
    sys.exit(0)

print("unsupported endpoint: " + endpoint, file=sys.stderr)
sys.exit(1)
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

setup_draft_ready_fixture() {
  setup_fixture_env
  cp "$GH_ROOT/scripts/actions/pr.draft.sh" "$FIXTURE_DIR/scripts/actions/pr.draft.sh"
  cp "$GH_ROOT/scripts/actions/pr.ready.sh" "$FIXTURE_DIR/scripts/actions/pr.ready.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/pr.draft.sh" "$FIXTURE_DIR/scripts/actions/pr.ready.sh"
  write_draft_ready_mock_gh
}

setup_fixture_env() {
  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  export MOCK_GH_GQL_CALLS="$FIXTURE_DIR/gql-calls.log"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_GH_GQL_CALLS"
}

# Inject the PR the mock serves: state open/closed, draft true/false, and
# merged (a merged PR is state=closed with merged=true on the API).
set_pr_state() {
  local state="$1"
  local draft="$2"
  local merged="$3"
  jq -n --arg state "$state" --argjson draft "$draft" --argjson merged "$merged" '{
    pr: {
      id: 200,
      number: 200,
      title: "draft/ready fixture PR",
      state: $state,
      draft: $draft,
      merged: $merged,
      merged_at: (if $merged then "2026-09-01T00:00:00Z" else null end),
      node_id: "PR_kwDOAB",
      html_url: "https://github.com/u7chan/agent-harness/pull/200",
      head: {ref: "fix/gh-171", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: "u7chan/agent-harness"}},
      base: {ref: "main", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", repo: {full_name: "u7chan/agent-harness"}}
    }
  }' > "$MOCK_GH_STATE"
}

run_draft_ready_case() {
  local action="$1"
  local state="$2"
  local draft="$3"
  local merged="$4"
  local expected="$5"
  local desired_draft
  local request="$FIXTURE_DIR/request.json"
  local output rc
  local label="$state"

  if [ "$action" = "pr.draft" ]; then
    desired_draft=true
  else
    desired_draft=false
  fi

  if [ "$merged" = "true" ]; then
    label=merged
  fi

  set_pr_state "$state" "$draft" "$merged"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_GH_GQL_CALLS"
  jq -n '{reference: "u7chan/agent-harness", number: 200, grant: "sensitive-write"}' > "$request"

  output="$(fixture_gh "$action" "$request" 2>&1)"
  rc=$?

  case "$expected" in
    failed)
      if [ "$rc" -ne 1 ]; then
        echo "case action=$action state=$state draft=$draft merged=$merged: expected exit 1, got $rc"
        echo "$output"
        return 1
      fi
      assert_json_eq "$output" '.status' failed || return 1
      assert_json_eq "$output" '.error.code' PR_NOT_OPEN || return 1
      assert_json_eq "$output" '.error.retryable | tostring' false || return 1
      # The error names the actual PR state explicitly.
      assert_json_eq "$output" ".error.message | contains(\"$label\")" true || return 1
      # No mutation: exactly one read, zero GraphQL calls, state unchanged.
      assert_eq "$(grep -c '^GET repos/u7chan/agent-harness/pulls/200$' "$MOCK_GH_CALLS" || true)" "1" || return 1
      assert_eq "$(gql_call_count)" "0" || return 1
      ;;
    already_applied)
      if [ "$rc" -ne 0 ]; then
        echo "case action=$action state=$state draft=$draft merged=$merged: expected success exit 0, got $rc"
        echo "$output"
        return 1
      fi
      assert_json_eq "$output" '.status' already_applied || return 1
      assert_json_eq "$output" '.data.state' open || return 1
      assert_json_eq "$output" ".data.draft | tostring" "$draft" || return 1
      # No mutation: only the pre-read ran.
      assert_eq "$(grep -c '^GET repos/u7chan/agent-harness/pulls/200$' "$MOCK_GH_CALLS" || true)" "1" || return 1
      assert_eq "$(gql_call_count)" "0" || return 1
      ;;
    ok)
      if [ "$rc" -ne 0 ]; then
        echo "case action=$action state=$state draft=$draft merged=$merged: expected success exit 0, got $rc"
        echo "$output"
        return 1
      fi
      assert_json_eq "$output" '.status' ok || return 1
      assert_json_eq "$output" '.data.state' open || return 1
      assert_json_eq "$output" ".data.draft | tostring" "$desired_draft" || return 1
      # Mutation ran exactly once (pre-read + GraphQL + post-read).
      assert_eq "$(grep -c '^GET repos/u7chan/agent-harness/pulls/200$' "$MOCK_GH_CALLS" || true)" "2" || return 1
      assert_eq "$(gql_call_count)" "1" || return 1

      # Re-running the same request on the mutated state is already_applied
      # and does not mutate again.
      output="$(fixture_gh "$action" "$request" 2>&1)" || return 1
      assert_json_eq "$output" '.status' already_applied || return 1
      assert_json_eq "$output" ".data.draft | tostring" "$desired_draft" || return 1
      assert_eq "$(gql_call_count)" "1" || return 1
      ;;
    *)
      echo "unknown expectation: $expected"
      return 1
      ;;
  esac
}

gql_call_count() {
  grep -c '^graphql ' "$MOCK_GH_GQL_CALLS" || true
}

# Issue #171: state != open must not be reported as already_applied. The
# matrix covers open/closed/merged x draft true/false for pr.draft; a non-open
# PR always fails with PR_NOT_OPEN and never mutates.
test_pr_draft_state_matrix() (
  setup_draft_ready_fixture
  trap teardown_fixture EXIT
  run_draft_ready_case pr.draft open true false already_applied || return 1
  run_draft_ready_case pr.draft open false false ok || return 1
  run_draft_ready_case pr.draft closed true false failed || return 1
  run_draft_ready_case pr.draft closed false false failed || return 1
  run_draft_ready_case pr.draft closed true true failed || return 1
  run_draft_ready_case pr.draft closed false true failed || return 1
)

# Issue #171: the pr.ready matrix mirrors pr.draft with ready semantics
# (already_applied only for open PRs that are already ready).
test_pr_ready_state_matrix() (
  setup_draft_ready_fixture
  trap teardown_fixture EXIT
  run_draft_ready_case pr.ready open true false ok || return 1
  run_draft_ready_case pr.ready open false false already_applied || return 1
  run_draft_ready_case pr.ready closed true false failed || return 1
  run_draft_ready_case pr.ready closed false false failed || return 1
  run_draft_ready_case pr.ready closed true true failed || return 1
  run_draft_ready_case pr.ready closed false true failed || return 1
)

main() {
  echo "=== pr draft/ready action contract tests ==="
  run_test test_pr_draft_state_matrix
  run_test test_pr_ready_state_matrix
  print_summary
}

main
