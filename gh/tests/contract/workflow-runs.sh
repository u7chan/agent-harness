#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

write_wf_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
calls_file = os.environ.get("MOCK_GH_CALLS")


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def arg_value(prefix, default=None):
    for arg in args:
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return default


if not args:
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

if args[0] == "repo" and args[1] == "view":
    print(os.environ.get("MOCK_REPO", "u7chan/agent-harness"))
    sys.exit(0)

if args[0] != "api":
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

method = "GET"
if "--method" in args:
    method = args[args.index("--method") + 1]
endpoint = next((a for a in args if a.startswith("repos/")), "")
per_page = arg_value("per_page=", "100")
page = arg_value("page=", "1")

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(method + " " + endpoint + "|per_page=" + per_page + "|page=" + page + "\n")

if os.environ.get("MOCK_API_FAIL") == "1":
    print("HTTP 404 Not Found", file=sys.stderr)
    sys.exit(1)

runs = json.loads(os.environ.get("MOCK_WF_RUNS", "[]"))
limit = int(per_page)
total = min(len(runs), limit)
output({"total_count": total, "workflow_runs": runs[:limit]})
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

run_workflow_runs() {
  local input_json="$1"
  local input_file

  input_file="$(mktemp /tmp/gh-wf-input-XXXXXX)"
  printf '%s\n' "$input_json" > "$input_file"
  fixture_gh "workflow-runs.list" "$input_file"
  local rc=$?
  rm -f "$input_file"
  return "$rc"
}

last_calls() {
  grep '/actions/runs' "$MOCK_GH_CALLS" | tail -n 1
}

test_wf_runs_default_limit() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_WF_RUNS='[{"name":"CI","run_number":3,"head_branch":"main","head_sha":"aaaa1111","event":"push","status":"completed","conclusion":"failure","html_url":"https://github.com/u7chan/agent-harness/actions/runs/3","created_at":"2026-08-22T00:00:00Z","updated_at":"2026-08-22T00:01:00Z"},{"name":"Lint","run_number":2,"head_branch":"main","head_sha":"bbbb2222","event":"pull_request","status":"completed","conclusion":"success","html_url":"https://github.com/u7chan/agent-harness/actions/runs/2","created_at":"2026-08-21T00:00:00Z","updated_at":"2026-08-21T00:01:00Z"}]'

  output="$(run_workflow_runs '{}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | length' "2" || return 1
  assert_json_eq "$output" '.target.type' "repository" || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1
  assert_json_eq "$output" '.data[0].name' "CI" || return 1
  assert_json_eq "$output" '.data[0].conclusion' "failure" || return 1

  assert_contains "$(last_calls)" "per_page=20" || return 1
  assert_contains "$(last_calls)" "page=1" || return 1
)

test_wf_runs_custom_limit() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_WF_RUNS='[{"name":"CI","run_number":1,"head_branch":"main","head_sha":"cc","event":"push","status":"completed","conclusion":null,"html_url":"u","created_at":"c","updated_at":"u"}]'

  output="$(run_workflow_runs '{"limit":5}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_contains "$(last_calls)" "per_page=5" || return 1
)

test_wf_runs_max_limit() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0 MOCK_WF_RUNS='[]'

  output="$(run_workflow_runs '{"limit":100}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_contains "$(last_calls)" "per_page=100" || return 1
)

test_wf_runs_invalid_limit_low() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  output="$(run_workflow_runs '{"limit":0}' 2>&1)" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_PARAMETER" || return 1
)

test_wf_runs_invalid_limit_high() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  output="$(run_workflow_runs '{"limit":101}' 2>&1)" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_PARAMETER" || return 1
)

test_wf_runs_invalid_limit_non_integer() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  output="$(run_workflow_runs '{"limit":1.5}' 2>&1)" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_PARAMETER" || return 1
)

test_wf_runs_fields_and_conclusion_passthrough() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_WF_RUNS='[
    {"id":77,"display_title":"ignore me","name":"CI","run_number":3,"workflow_id":1,"run_attempt":1,
     "head_branch":"main","head_sha":"aaaa1111","event":"push","status":"in_progress","conclusion":null,
     "html_url":"https://github.com/u7chan/agent-harness/actions/runs/3",
     "created_at":"2026-08-22T00:00:00Z","updated_at":"2026-08-22T00:01:00Z"},
    {"id":66,"display_title":"ignore me 2","name":"Lint","run_number":2,"workflow_id":2,"run_attempt":2,
     "head_branch":"release","head_sha":"bbbb2222","event":"pull_request","status":"completed","conclusion":"timed_out",
     "html_url":"https://github.com/u7chan/agent-harness/actions/runs/2",
     "created_at":"2026-08-21T00:00:00Z","updated_at":"2026-08-21T00:01:00Z"}
  ]'

  output="$(run_workflow_runs '{}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | length' "2" || return 1
  assert_json_eq "$output" '.data[0] | keys | length' "10" || return 1
  assert_json_eq "$output" '.data[0] | has("id") | not' "true" || return 1
  assert_json_eq "$output" '.data[0] | has("display_title") | not' "true" || return 1
  assert_json_eq "$output" '.data[0] | has("workflow_id") | not' "true" || return 1
  assert_json_eq "$output" '.data[0] | has("run_attempt") | not' "true" || return 1
  assert_json_eq "$output" '.data[0].status' "in_progress" || return 1
  assert_json_eq "$output" '.data[0].conclusion == null' "true" || return 1
  assert_json_eq "$output" '.data[1].status' "completed" || return 1
  assert_json_eq "$output" '.data[1].conclusion' "timed_out" || return 1
)

test_wf_runs_api_failure() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
  export MOCK_API_FAIL=1
  output="$(run_workflow_runs '{}')" && return 1 || true
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "API_ERROR" || return 1
  assert_json_eq "$output" '.error.retryable == false' "true" || return 1
)

test_wf_runs_empty_repo() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0 MOCK_WF_RUNS='[]'
  output="$(run_workflow_runs '{}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data' '[]' || return 1
)

test_wf_runs_empty_input() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/workflow-runs.list.sh" "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/workflow-runs.list.sh"
  write_wf_mock_gh

  local output input_file
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0 MOCK_WF_RUNS='[]'
  input_file="$(mktemp /tmp/gh-wf-input-XXXXXX)"
  : > "$input_file"
  output="$(fixture_gh "workflow-runs.list" "$input_file")" || return 1
  rm -f "$input_file"
  assert_json_eq "$output" '.status' "ok" || return 1
)

main() {
  echo "=== workflow-runs.list contract tests ==="
  run_test test_wf_runs_default_limit
  run_test test_wf_runs_custom_limit
  run_test test_wf_runs_max_limit
  run_test test_wf_runs_invalid_limit_low
  run_test test_wf_runs_invalid_limit_high
  run_test test_wf_runs_invalid_limit_non_integer
  run_test test_wf_runs_fields_and_conclusion_passthrough
  run_test test_wf_runs_api_failure
  run_test test_wf_runs_empty_repo
  run_test test_wf_runs_empty_input
  print_summary
}

main
