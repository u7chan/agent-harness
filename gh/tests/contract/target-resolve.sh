#!/usr/bin/env bash
set -u

# Issue #180 contract tests for gh/scripts/common/target.sh.
#
# The reference parser used to treat the last path segment as the number, so
# a GitHub UI suffix (/pull/12/files), a query string (/pull/12?diff=split)
# or a fragment (/pull/12#discussion_r123) crashed tonumber, a trailing
# slash produced number: null, and decimals (/pull/1.5), 0 and negatives
# passed through. The contract now requires positive integers and treats
# query strings, fragments, trailing slashes, and any path after the issue/
# PR number as decorations that address the same resource.
#
# Two layers are pinned:
#   1. unit level - resolve_target / resolve_pr_target (the real common
#      script, sourced in a subshell) return the canonical target JSON or
#      fail for every reference form.
#   2. action level - pr.draft (a write action) behind a strict mock gh that
#      only serves the canonical pulls/200 endpoint and logs every call:
#      decorated references write to the canonical target, and invalid
#      references fail with a TARGET_ERROR envelope before any gh call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# --- unit level --------------------------------------------------------------

target_out=""
target_rc=0

# Run one target.sh function in a subshell (the script enables errexit when
# sourced, so a failing function must not abort this suite) and capture its
# stdout and exit status.
run_target_fn() {
  local fn="$1"
  shift

  target_out="$( {
    source "$GH_ROOT/scripts/common/target.sh"
    set +e
    "$fn" "$@"
  } 2>/dev/null )"
  target_rc=$?
}

# resolve_pr_target / resolve_target must turn every accepted reference into
# the canonical target JSON: the owner/repo spelling from the reference is
# kept, the number is a JSON integer, and the url carries no query string,
# fragment, trailing slash, or navigation suffix.
test_target_canonical_url_forms() (
  local reference expected actual

  while IFS='|' read -r reference type repo number url; do
    [ -z "$reference" ] && continue
    run_target_fn resolve_pr_target "$reference"
    if [ "$target_rc" -ne 0 ]; then
      echo "resolve_pr_target failed for: $reference"
      return 1
    fi
    expected="$(jq -nc -S \
      --arg type "$type" --arg repo "$repo" --arg number "$number" --arg url "$url" \
      '{type: $type, repository: $repo,
        number: (if $number == "" then null else ($number | tonumber) end),
        url: $url}')"
    actual="$(printf '%s\n' "$target_out" | jq -S -c)"
    assert_eq "$actual" "$expected" || {
      echo "  reference: $reference"
      return 1
    }
  done <<'CASES'
https://github.com/u7chan/agent-harness/pull/12|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/U7chan/Agent-Harness/pull/200|pull_request|U7chan/Agent-Harness|200|https://github.com/U7chan/Agent-Harness/pull/200
https://github.com/u7chan/agent-harness/pull/12/|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12?diff=split|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12#discussion_r123|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12/files|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12/commits|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12?diff=split#discussion_r123|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/12/files#discussion_r123|pull_request|u7chan/agent-harness|12|https://github.com/u7chan/agent-harness/pull/12
https://github.com/u7chan/agent-harness/pull/200/commits/abc123|pull_request|u7chan/agent-harness|200|https://github.com/u7chan/agent-harness/pull/200
CASES
)

test_target_issue_and_repository_forms() (
  local reference type expected actual
  run_target_fn resolve_target "https://github.com/u7chan/agent-harness/issues/7#issuecomment-123"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_target failed for an issues URL with a comment fragment"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "issue", repository: "u7chan/agent-harness", number: 7,
      url: "https://github.com/u7chan/agent-harness/issues/7"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  run_target_fn resolve_target "https://github.com/u7chan/agent-harness/"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_target failed for a repository URL with a trailing slash"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "repository", repository: "u7chan/agent-harness", number: null,
      url: "https://github.com/u7chan/agent-harness"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  # An issue URL against an expected pull_request is a type mismatch.
  run_target_fn resolve_pr_target "https://github.com/u7chan/agent-harness/issues/7"
  assert_eq "$target_rc" "1" || return 1
)

test_target_owner_repo_text_forms() (
  local expected actual

  # owner/repo + number resolves to the canonical PR target.
  run_target_fn resolve_pr_target "u7chan/agent-harness" "12"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_pr_target failed for owner/repo + number"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "pull_request", repository: "u7chan/agent-harness", number: 12,
      url: "https://github.com/u7chan/agent-harness/pull/12"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  # owner/repo + number + expected_type issue resolves to the issue target.
  run_target_fn resolve_target "u7chan/agent-harness" "7" "issue"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_target failed for owner/repo + number + issue type"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "issue", repository: "u7chan/agent-harness", number: 7,
      url: "https://github.com/u7chan/agent-harness/issues/7"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  # owner/repo without a number is a repository target; a PR action must
  # reject it (cannot determine the PR).
  run_target_fn resolve_pr_target "u7chan/agent-harness"
  assert_eq "$target_rc" "1" || return 1
)

# Broken references, a foreign host, decimals, 0, negatives, non-numeric
# number segments, and missing numbers must all fail resolution: only a
# positive integer ([1-9][0-9]*) is a valid issue/PR number.
test_target_invalid_references_rejected() (
  local reference number rc_expected

  while IFS='|' read -r reference number; do
    [ -z "$reference" ] && continue
    if [ -n "$number" ]; then
      run_target_fn resolve_pr_target "$reference" "$number"
    else
      run_target_fn resolve_pr_target "$reference"
    fi
    assert_eq "$target_rc" "1" || {
      echo "  unexpectedly accepted: reference='$reference' number='$number'"
      printf '%s\n' "$target_out"
      return 1
    }
  done <<'CASES'
https://github.com/u7chan/agent-harness/pull/|
https://github.com/u7chan/agent-harness/pull|
https://github.com/u7chan/agent-harness/pulls/12|
https://github.com/u7chan/agent-harness/tree/main|
https://github.com/u7chan/agent-harness/pull/12abc|
https://github.com/u7chan/agent-harness/pull/12.diff|
https://github.com/u7chan/agent-harness/pull/1.5|
https://github.com/u7chan/agent-harness/pull/0|
https://github.com/u7chan/agent-harness/pull/-3|
https://github.com/u7chan/agent-harness/pull/01|
https://github.com/u7chan/agent-harness/issues/0|
https://github.com/u7chan/agent-harness/issues/1.5|
https://github.com/u7chan/agent-harness/issues/|
https://ghe.example.com/u7chan/agent-harness/pull/12|
http://github.com/u7chan/agent-harness/pull/12|
https://github.com.evil.example/u7chan/agent-harness/pull/12|
https://github.com/|
https://github.com/u7chan//pull/12|
https://github.com//u7chan/agent-harness/pull/12|
https://github.com/u7chan/agent-harness/pull/../issues/12|
u7chan/agent-harness|1.5
u7chan/agent-harness|0
u7chan/agent-harness|-3
u7chan/agent-harness|abc
../agent-harness|
u7chan/agent-harness extra|
CASES

  # Number-only references are validated before the repository lookup: no
  # gh call may happen for an invalid number (checked at the action level
  # below, where the call log is visible).
  run_target_fn resolve_pr_target "" "1.5"
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_pr_target "" "0"
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_pr_target "" "-3"
  assert_eq "$target_rc" "1" || return 1
)

# --- action level ------------------------------------------------------------

# A fake gh CLI that serves only the canonical PR 200 endpoint on
# u7chan/agent-harness (state injected through MOCK_GH_STATE) plus the
# convertPullRequestToDraft GraphQL mutation, and logs every invocation:
# any request for a different endpoint or number makes the test fail, so an
# ok result proves the reference was normalized to the canonical target and
# a TARGET_ERROR result proves no API call (no wrong write) happened.
write_target_mock_gh() {
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
    print("unsupported mock command: " + " ".join(args), file=sys.stderr)
    sys.exit(1)

if args[1] == "graphql":
    query = arg_value("query=", "")
    if "convertPullRequestToDraft" in query:
        fingerprint = "convertPullRequestToDraft"
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

setup_target_action_fixture() {
  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  export MOCK_GH_GQL_CALLS="$FIXTURE_DIR/gql-calls.log"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_GH_GQL_CALLS"
  cp "$GH_ROOT/scripts/actions/pr.draft.sh" \
    "$FIXTURE_DIR/scripts/actions/pr.draft.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/pr.draft.sh"
  write_target_mock_gh
}

# An open, non-draft PR 200 that the mock serves.
seed_target_pr() {
  jq -n '{
    pr: {
      id: 200,
      number: 200,
      title: "target-resolve fixture PR",
      state: "open",
      draft: false,
      merged: false,
      node_id: "PR_kwDOAB",
      html_url: "https://github.com/u7chan/agent-harness/pull/200",
      head: {ref: "fix/gh-180", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: "u7chan/agent-harness"}},
      base: {ref: "main", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", repo: {full_name: "u7chan/agent-harness"}}
    }
  }' > "$MOCK_GH_STATE"
}

# pr.draft (a write action) must accept decorated references, resolve them
# to PR 200, and mutate exactly the canonical endpoint: the mock refuses any
# other endpoint, so ok + one mutation proves the canonical target.
test_draft_decorated_references_write_canonical_target() (
  setup_target_action_fixture
  trap teardown_fixture EXIT
  local request="$FIXTURE_DIR/request.json"
  local payload output

  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    seed_target_pr
    : > "$MOCK_GH_CALLS"
    : > "$MOCK_GH_GQL_CALLS"
    printf '%s\n' "$payload" > "$request"

    output="$(fixture_gh pr.draft "$request" 2>&1)"
    if [ "$?" -ne 0 ]; then
      echo "pr.draft failed for payload: $payload"
      printf '%s\n' "$output"
      return 1
    fi
    assert_json_eq "$output" '.status' ok || return 1
    assert_json_eq "$output" '.target.type' pull_request || return 1
    assert_json_eq "$output" '.target.repository' u7chan/agent-harness || return 1
    assert_json_eq "$output" '.target.number' 200 || return 1
    assert_json_eq "$output" '.target.url' "https://github.com/u7chan/agent-harness/pull/200" || return 1
    assert_json_eq "$output" '.data.draft | tostring' true || return 1
    # Exactly the canonical pre/post reads and one mutation.
    assert_eq "$(grep -c '^GET repos/u7chan/agent-harness/pulls/200$' "$MOCK_GH_CALLS" || true)" "2" || return 1
    assert_eq "$(grep -c '^graphql convertPullRequestToDraft$' "$MOCK_GH_GQL_CALLS" || true)" "1" || return 1
  done <<'PAYLOADS'
{"reference":"https://github.com/u7chan/agent-harness/pull/200","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200/","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200/files","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200/commits","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200?diff=split","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200#discussion_r9","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/200/commits?diff=split#discussion_r9","grant":"sensitive-write"}
{"reference":"u7chan/agent-harness","number":200,"grant":"sensitive-write"}
{"number":200,"grant":"sensitive-write"}
PAYLOADS
)

# Broken URLs, a foreign host, decimals, 0, negatives and type mismatches
# fail with a TARGET_ERROR envelope before any gh call: no write can ever
# reach a wrong repository or number.
test_draft_invalid_references_fail_before_any_gh_call() (
  setup_target_action_fixture
  trap teardown_fixture EXIT
  local request="$FIXTURE_DIR/request.json"
  local payload output rc

  while IFS= read -r payload; do
    [ -z "$payload" ] && continue
    seed_target_pr
    : > "$MOCK_GH_CALLS"
    : > "$MOCK_GH_GQL_CALLS"
    printf '%s\n' "$payload" > "$request"

    output="$(fixture_gh pr.draft "$request" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "pr.draft unexpectedly succeeded for payload: $payload"
      return 1
    fi
    assert_json_eq "$output" '.status' failed || {
      echo "  payload: $payload"
      return 1
    }
    assert_json_eq "$output" '.error.code' TARGET_ERROR || {
      echo "  payload: $payload"
      return 1
    }
    assert_json_eq "$output" '.error.retryable | tostring' false || return 1
    if [ -s "$MOCK_GH_CALLS" ] || [ -s "$MOCK_GH_GQL_CALLS" ]; then
      echo "gh was invoked for a rejected target (payload: $payload):"
      cat "$MOCK_GH_CALLS" "$MOCK_GH_GQL_CALLS"
      return 1
    fi
  done <<'PAYLOADS'
{"reference":"https://github.com/u7chan/agent-harness/pull/0","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/-3","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/1.5","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/12abc","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull/","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pull","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/pulls/200","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/tree/main","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness/issues/200","grant":"sensitive-write"}
{"reference":"https://github.com/u7chan/agent-harness","grant":"sensitive-write"}
{"reference":"https://github.com/octocat","grant":"sensitive-write"}
{"reference":"https://github.com/octocat?tab=repos","grant":"sensitive-write"}
{"reference":"https://ghe.example.com/u7chan/agent-harness/pull/200","grant":"sensitive-write"}
{"reference":"http://github.com/u7chan/agent-harness/pull/200","grant":"sensitive-write"}
{"reference":"u7chan/agent-harness","number":0,"grant":"sensitive-write"}
{"reference":"u7chan/agent-harness","number":1.5,"grant":"sensitive-write"}
{"reference":"u7chan/agent-harness","number":-3,"grant":"sensitive-write"}
{"number":0,"grant":"sensitive-write"}
{"number":1.5,"grant":"sensitive-write"}
{"number":-3,"grant":"sensitive-write"}
PAYLOADS
)

# Issue #180 acceptance FB1: a GitHub URL without a repository (owner-only)
# must not resolve to a guessed repository (octocat -> octocat/octocat): it
# fails before any API call. Query/fragment/trailing-slash decoration on the
# full owner/repo form stays accepted.
test_target_owner_only_url_rejected() (
  local reference expected actual

  while IFS= read -r reference; do
    [ -z "$reference" ] && continue
    run_target_fn resolve_target "$reference"
    assert_eq "$target_rc" "1" || {
      echo "  unexpectedly accepted owner-only URL: $reference"
      printf '%s\n' "$target_out"
      return 1
    }
  done <<'CASES'
https://github.com/octocat
https://github.com/octocat/
https://github.com/octocat?tab=repos
https://github.com/octocat#top
https://github.com/octocat?tab=repos#top
CASES

  # Controls: the same decoration forms on the full owner/repo URL keep
  # resolving to the repository.
  while IFS= read -r reference; do
    [ -z "$reference" ] && continue
    run_target_fn resolve_target "$reference"
    if [ "$target_rc" -ne 0 ]; then
      echo "resolve_target failed for full repo URL: $reference"
      return 1
    fi
    expected="$(jq -nc -S \
      '{type: "repository", repository: "octocat/Hello-World", number: null,
        url: "https://github.com/octocat/Hello-World"}')"
    actual="$(printf '%s\n' "$target_out" | jq -S -c)"
    assert_eq "$actual" "$expected" || {
      echo "  reference: $reference"
      return 1
    }
  done <<'CASES'
https://github.com/octocat/Hello-World
https://github.com/octocat/Hello-World/
https://github.com/octocat/Hello-World?tab=readme
https://github.com/octocat/Hello-World#readme
CASES
)

# Issue #180 acceptance FB2: only a segment that is exactly '.' or '..' is
# rejected; dots inside a name (release..notes) stay accepted in both the
# owner/repo and the URL form, matching the pre-#180 behavior.
test_target_double_dot_repo_names() (
  local expected actual

  # Text form: repo names with interior double dots are accepted.
  run_target_fn resolve_pr_target "octocat/release..notes" "12"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_pr_target failed for owner/repo with interior dots"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "pull_request", repository: "octocat/release..notes", number: 12,
      url: "https://github.com/octocat/release..notes/pull/12"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  # URL forms with interior dots are accepted (repository and PR targets).
  run_target_fn resolve_target "https://github.com/octocat/release..notes/"
  if [ "$target_rc" -ne 0 ]; then
    echo "resolve_target failed for a repo URL with interior dots"
    return 1
  fi
  expected="$(jq -nc -S \
    '{type: "repository", repository: "octocat/release..notes", number: null,
      url: "https://github.com/octocat/release..notes"}')"
  actual="$(printf '%s\n' "$target_out" | jq -S -c)"
  assert_eq "$actual" "$expected" || return 1

  run_target_fn resolve_pr_target "https://github.com/octocat/release..notes/pull/12"
  assert_eq "$target_rc" "0" || return 1

  # A segment that is exactly '.' or '..' is rejected in both forms.
  run_target_fn resolve_pr_target "octocat/.." "12"
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_pr_target "octocat/." "12"
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_pr_target "../octocat" "12"
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_target "https://github.com/octocat/.."
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_target "https://github.com/octocat/."
  assert_eq "$target_rc" "1" || return 1
  run_target_fn resolve_target "https://github.com/./octocat"
  assert_eq "$target_rc" "1" || return 1
)

main() {
  echo "=== target resolution contract tests ==="

  run_test test_target_canonical_url_forms
  run_test test_target_issue_and_repository_forms
  run_test test_target_owner_repo_text_forms
  run_test test_target_invalid_references_rejected
  run_test test_target_owner_only_url_rejected
  run_test test_target_double_dot_repo_names
  run_test test_draft_decorated_references_write_canonical_target
  run_test test_draft_invalid_references_fail_before_any_gh_call

  print_summary
}

main
