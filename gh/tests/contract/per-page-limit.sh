#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Issue #179: issue.list / prs.list / prs.search must reject per_page values
# outside the integer range 1..100 before any gh invocation, keep the default
# 30 when per_page is absent or null, and pass 1 / 100 through to the API.

write_per_page_mock_gh() {
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

if args[0] == "repo" and len(args) > 1 and args[1] == "view":
    print(os.environ.get("MOCK_REPO", "u7chan/agent-harness"))
    sys.exit(0)

if args[0] != "api":
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

endpoint = next(
    (a for a in args if a.startswith("repos/") or a.startswith("search/")), ""
)
per_page = arg_value("per_page=", "100")
page = arg_value("page=", "1")

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(endpoint + "|per_page=" + per_page + "|page=" + page + "\n")

try:
    pp = int(per_page)
except ValueError:
    print("mock: non-integer per_page " + per_page, file=sys.stderr)
    sys.exit(1)

# Mirror the GitHub API contract: a per_page below 1 is invalid.
if pp < 1:
    print("HTTP 422: per_page must be between 1 and 100", file=sys.stderr)
    sys.exit(1)

start = (int(page) - 1) * pp
if endpoint.startswith("search/"):
    items = json.loads(os.environ.get("MOCK_SEARCH_ITEMS", "[]"))
    total = int(os.environ.get("MOCK_SEARCH_TOTAL", str(len(items))))
    output({"total_count": total, "items": items[start:start + pp]})
else:
    items = json.loads(os.environ.get("MOCK_ITEMS", "[]"))
    output(items[start:start + pp])
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# Copy one real action into the fixture and prepare the mock gh environment.
setup_per_page_action() {
  local action="$1"
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/$action.sh" "$FIXTURE_DIR/scripts/actions/$action.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/$action.sh"
  write_per_page_mock_gh
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
  export MOCK_REPO="u7chan/agent-harness"
}

run_per_page_action() {
  local action="$1"
  local payload="$2"
  local input_file

  input_file="$(mktemp /tmp/gh-pp-input-XXXXXX)"
  printf '%s\n' "$payload" > "$input_file"
  fixture_gh "$action" "$input_file" 2>&1
  local rc=$?
  rm -f "$input_file"
  return "$rc"
}

last_api_call() {
  grep -F "$1" "$MOCK_GH_CALLS" | tail -n 1
}

# Per-action assertion shared by the boundary tests: one call with the
# expected per_page, the full dataset returned, the target resolved.
assert_boundary_run() {
  local output="$1"
  local expected_per_page="$2"
  local expected_items="$3"
  local call_marker="$4"

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data | length' "$expected_items" || return 1
  assert_json_eq "$output" '.target.type' "repository" || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1
  assert_contains "$(last_api_call "$call_marker")" "per_page=$expected_per_page" || return 1
}

# An invalid per_page must be rejected before any gh invocation: the failure
# envelope is INVALID_PARAMETER and the mock call log stays empty.
assert_invalid_per_page() {
  local action="$1"
  local payload="$2"
  local output
  local rc

  output="$(run_per_page_action "$action" "$payload")"
  rc=$?
  if [ "$rc" = "0" ]; then
    echo "per_page $payload unexpectedly accepted by $action"
    return 1
  fi
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "INVALID_PARAMETER" || return 1
  assert_json_eq "$output" '.error.message' "per_page must be an integer between 1 and 100" || return 1
  if [ -s "$MOCK_GH_CALLS" ]; then
    echo "invalid per_page reached gh:"
    cat "$MOCK_GH_CALLS"
    return 1
  fi
}

MOCK_ISSUES='[
  {"id":11,"number":177,"title":"PR 作成前の既存確認失敗を停止する","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/issues/177",
   "user":{"login":"u7chan"},"labels":[{"name":"P2"}],"assignees":[{"login":"u7chan"}],
   "milestone":{"title":"Epic 169"},"comments":1,
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z","closed_at":null},
  {"id":12,"number":178,"title":"reviews.read の偽の comments_count を解消する","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/issues/178",
   "user":{"login":"u7chan"},"labels":[{"name":"P2"}],"assignees":[],
   "milestone":{"title":"Epic 169"},"comments":0,
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z","closed_at":null},
  {"id":13,"number":179,"title":"一覧 action の per_page を整数 1〜100 に制限する","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/issues/179",
   "user":{"login":"u7chan"},"labels":[{"name":"P2"}],"assignees":[],
   "milestone":{"title":"Epic 169"},"comments":0,
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z","closed_at":null}
]'

MOCK_PULLS='[
  {"id":201,"number":184,"title":"アンインストールで共有リンクを削除しない","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/pull/184","draft":false,
   "user":{"login":"u7chan"},"labels":[{"name":"docs"}],
   "head":{"ref":"docs/gh-174-uninstall-shared-skill-links","sha":"aaaa","repo":{"full_name":"u7chan/agent-harness"}},
   "base":{"ref":"main","sha":"bbbb","repo":{"full_name":"u7chan/agent-harness"}},
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"},
  {"id":202,"number":185,"title":"非 open PR の draft/ready を状態エラーで返す","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/pull/185","draft":true,
   "user":{"login":"u7chan"},"labels":[{"name":"fix"}],
   "head":{"ref":"fix/gh-171-pr-draft-ready-nonopen","sha":"cccc","repo":{"full_name":"u7chan/agent-harness"}},
   "base":{"ref":"main","sha":"bbbb","repo":{"full_name":"u7chan/agent-harness"}},
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"},
  {"id":203,"number":186,"title":"maintainer_can_modify=false を保持する","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/pull/186","draft":false,
   "user":{"login":"u7chan"},"labels":[{"name":"fix"}],
   "head":{"ref":"fix/gh-173-maintainer-can-modify","sha":"dddd","repo":{"full_name":"u7chan/agent-harness"}},
   "base":{"ref":"main","sha":"bbbb","repo":{"full_name":"u7chan/agent-harness"}},
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"}
]'

MOCK_SEARCH='[
  {"id":301,"number":185,"title":"非 open PR の draft/ready を状態エラーで返す","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/pull/185","draft":true,
   "user":{"login":"u7chan"},"labels":[{"name":"fix"}],
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"},
  {"id":302,"number":186,"title":"maintainer_can_modify=false を保持する","state":"open",
   "html_url":"https://github.com/u7chan/agent-harness/pull/186","draft":false,
   "user":{"login":"u7chan"},"labels":[{"name":"fix"}],
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"},
  {"id":303,"number":188,"title":"review thread を fail-closed で検証する","state":"closed",
   "html_url":"https://github.com/u7chan/agent-harness/pull/188","draft":false,
   "user":{"login":"u7chan"},"labels":[{"name":"fix"}],
   "created_at":"2026-09-07T00:00:00Z","updated_at":"2026-09-07T00:00:00Z"}
]'

test_issue_list_default_per_page() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  local output
  output="$(run_per_page_action issue.list '{}')" || return 1
  assert_boundary_run "$output" "30" "3" "repos/u7chan/agent-harness/issues" || return 1
  assert_json_eq "$output" '.data[2].number' "179" || return 1
)

test_issue_list_min_per_page() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  local output
  output="$(run_per_page_action issue.list '{"per_page":1}')" || return 1
  # Pagination walks three single-item pages plus one empty page.
  assert_boundary_run "$output" "1" "3" "repos/u7chan/agent-harness/issues" || return 1
  assert_contains "$(last_api_call repos/u7chan/agent-harness/issues)" "page=4" || return 1
)

test_issue_list_max_per_page() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  local output
  output="$(run_per_page_action issue.list '{"per_page":100}')" || return 1
  assert_boundary_run "$output" "100" "3" "repos/u7chan/agent-harness/issues" || return 1
)

test_issue_list_null_per_page() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  # The existing null contract: an optional explicit null passes the
  # dispatcher and the action applies its default, here 30.
  local output
  output="$(run_per_page_action issue.list '{"per_page":null}')" || return 1
  assert_boundary_run "$output" "30" "3" "repos/u7chan/agent-harness/issues" || return 1
)

test_issue_list_invalid_per_page_values() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  local payload
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    : > "$MOCK_GH_CALLS"
    assert_invalid_per_page issue.list "$payload" || return 1
  done <<'CASES'
{"per_page":0}
{"per_page":-1}
{"per_page":1.5}
{"per_page":101}
CASES
)

test_issue_list_string_per_page() (
  setup_per_page_action issue.list
  export MOCK_ITEMS="$MOCK_ISSUES"

  # A string is rejected by the shared dispatcher type check before the
  # action runs: no gh invocation may happen.
  local output rc
  output="$(run_per_page_action issue.list '{"per_page":"5"}')"
  rc=$?
  if [ "$rc" = "0" ]; then
    echo "string per_page unexpectedly accepted"
    return 1
  fi
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "TYPE_MISMATCH" || return 1
  if [ -s "$MOCK_GH_CALLS" ]; then
    echo "string per_page reached gh:"
    cat "$MOCK_GH_CALLS"
    return 1
  fi
)

test_prs_list_default_per_page() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local output
  output="$(run_per_page_action prs.list '{}')" || return 1
  assert_boundary_run "$output" "30" "3" "repos/u7chan/agent-harness/pulls" || return 1
  assert_json_eq "$output" '.data[0].head.ref' "docs/gh-174-uninstall-shared-skill-links" || return 1
)

test_prs_list_min_per_page() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local output
  output="$(run_per_page_action prs.list '{"per_page":1}')" || return 1
  assert_boundary_run "$output" "1" "3" "repos/u7chan/agent-harness/pulls" || return 1
  assert_contains "$(last_api_call repos/u7chan/agent-harness/pulls)" "page=4" || return 1
)

test_prs_list_max_per_page() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local output
  output="$(run_per_page_action prs.list '{"per_page":100}')" || return 1
  assert_boundary_run "$output" "100" "3" "repos/u7chan/agent-harness/pulls" || return 1
)

test_prs_list_null_per_page() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local output
  output="$(run_per_page_action prs.list '{"per_page":null}')" || return 1
  assert_boundary_run "$output" "30" "3" "repos/u7chan/agent-harness/pulls" || return 1
)

test_prs_list_invalid_per_page_values() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local payload
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    : > "$MOCK_GH_CALLS"
    assert_invalid_per_page prs.list "$payload" || return 1
  done <<'CASES'
{"per_page":0}
{"per_page":-1}
{"per_page":1.5}
{"per_page":101}
CASES
)

test_prs_list_string_per_page() (
  setup_per_page_action prs.list
  export MOCK_ITEMS="$MOCK_PULLS"

  local output rc
  output="$(run_per_page_action prs.list '{"per_page":"5"}')"
  rc=$?
  if [ "$rc" = "0" ]; then
    echo "string per_page unexpectedly accepted"
    return 1
  fi
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "TYPE_MISMATCH" || return 1
  if [ -s "$MOCK_GH_CALLS" ]; then
    echo "string per_page reached gh:"
    cat "$MOCK_GH_CALLS"
    return 1
  fi
)

test_prs_search_default_per_page() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local output
  output="$(run_per_page_action prs.search '{"q":"is:merged"}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.items | length' "3" || return 1
  assert_json_eq "$output" '.data.total_count' "3" || return 1
  assert_contains "$(last_api_call search/issues)" "per_page=30" || return 1
)

test_prs_search_min_per_page() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local output
  output="$(run_per_page_action prs.search '{"q":"is:merged","per_page":1}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.items | length' "3" || return 1
  assert_contains "$(last_api_call search/issues)" "per_page=1" || return 1
)

test_prs_search_max_per_page() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local output
  output="$(run_per_page_action prs.search '{"q":"is:merged","per_page":100}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.items | length' "3" || return 1
  assert_contains "$(last_api_call search/issues)" "per_page=100" || return 1
)

test_prs_search_null_per_page() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local output
  output="$(run_per_page_action prs.search '{"q":"is:merged","per_page":null}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.items | length' "3" || return 1
  assert_contains "$(last_api_call search/issues)" "per_page=30" || return 1
)

test_prs_search_invalid_per_page_values() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local payload
  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    : > "$MOCK_GH_CALLS"
    assert_invalid_per_page prs.search "$payload" || return 1
  done <<'CASES'
{"q":"is:merged","per_page":0}
{"q":"is:merged","per_page":-1}
{"q":"is:merged","per_page":1.5}
{"q":"is:merged","per_page":101}
CASES
)

test_prs_search_string_per_page() (
  setup_per_page_action prs.search
  export MOCK_SEARCH_ITEMS="$MOCK_SEARCH"

  local output rc
  output="$(run_per_page_action prs.search '{"q":"is:merged","per_page":"5"}')"
  rc=$?
  if [ "$rc" = "0" ]; then
    echo "string per_page unexpectedly accepted"
    return 1
  fi
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "TYPE_MISMATCH" || return 1
  if [ -s "$MOCK_GH_CALLS" ]; then
    echo "string per_page reached gh:"
    cat "$MOCK_GH_CALLS"
    return 1
  fi
)

main() {
  echo "=== per_page limit contract tests (Issue #179) ==="
  run_test test_issue_list_default_per_page
  run_test test_issue_list_min_per_page
  run_test test_issue_list_max_per_page
  run_test test_issue_list_null_per_page
  run_test test_issue_list_invalid_per_page_values
  run_test test_issue_list_string_per_page
  run_test test_prs_list_default_per_page
  run_test test_prs_list_min_per_page
  run_test test_prs_list_max_per_page
  run_test test_prs_list_null_per_page
  run_test test_prs_list_invalid_per_page_values
  run_test test_prs_list_string_per_page
  run_test test_prs_search_default_per_page
  run_test test_prs_search_min_per_page
  run_test test_prs_search_max_per_page
  run_test test_prs_search_null_per_page
  run_test test_prs_search_invalid_per_page_values
  run_test test_prs_search_string_per_page
  print_summary
}

main
