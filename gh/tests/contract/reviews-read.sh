#!/usr/bin/env bash
set -u

# Contract tests for the reviews.read output contract (Issue #178): the
# fake comments_count (computed as the body_text length, not a real comment
# count) must not exist anywhere in the output. GitHub review objects carry
# no comments count, and counting per-review comments truthfully would cost
# one extra GET /pulls/{n}/reviews/{id}/comments per review. No consumer
# uses the field, so the contract is: no count field at all - the presence
# or length of a review body must not change any other output field, and
# the list/single reads stay at their existing API cost.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Mock gh for the reviews.read REST flow:
#   - repo view              -> current repository (target resolution)
#   - GET .../pulls/{n}/reviews[/{id}] -> review collection / single review
# Every api call is logged to $MOCK_GH_CALLS so tests can pin that the read
# stays at one GET (no per-review counting calls).
# $MOCK_REVIEWS holds the review objects; review bodies are longer than any
# plausible comment count so the old body_text-length fake would show up.
write_reviews_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
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
    if "--jq" in args:
        print(os.environ.get("MOCK_REPO", "u7chan/agent-harness"))
    else:
        output({"nameWithOwner": os.environ.get("MOCK_REPO", "u7chan/agent-harness")})
    sys.exit(0)

if args[0] != "api":
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

method = "GET"
if "--method" in args:
    method = args[args.index("--method") + 1]
endpoint = next((a for a in args if a.startswith("repos/")), "")
per_page = int(arg_value("per_page=", "100"))
page = int(arg_value("page=", "1"))

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write("api %s %s per_page=%d page=%d\n" % (method, endpoint, per_page, page))

if os.environ.get("MOCK_API_FAIL") == "1":
    print("HTTP 404 Not Found", file=sys.stderr)
    sys.exit(1)

reviews = json.loads(os.environ.get("MOCK_REVIEWS", "[]"))

single = re.search(r"/reviews/(\d+)$", endpoint)
if single:
    match = next((r for r in reviews if r.get("id") == int(single.group(1))), None)
    if match is None:
        print("HTTP 404 Not Found", file=sys.stderr)
        sys.exit(1)
    output(match)
    sys.exit(0)

start = (page - 1) * per_page
output(reviews[start:start + per_page])
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# Two reviews that differ ONLY in id, html_url and body (500-char body with
# a matching body_text vs. an empty body with no body_text at all): under
# the fake comments_count the first would report 500 comments and the
# second 0 although both have zero real review comments. The fixture also
# carries API noise fields (node_id, body_html, links, ...) that must not
# leak into the formatted output.
install_reviews_mock() {
  cp "$GH_ROOT/scripts/actions/reviews.read.sh" "$FIXTURE_DIR/scripts/actions/reviews.read.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/reviews.read.sh"
  write_reviews_mock_gh

  local long_body
  long_body="$(printf 'L%.0s' $(seq 1 500))"
  export MOCK_REVIEWS="$(jq -nc \
    --arg long "$long_body" \
    '[
      {
        id: 11,
        state: "APPROVED",
        body: $long,
        body_text: $long,
        body_html: "<p>noise</p>",
        node_id: "PRR_noise_11",
        author_association: "OWNER",
        pull_request_url: "https://api.github.com/repos/u7chan/agent-harness/pulls/5",
        links: {html: {href: "https://github.com/u7chan/agent-harness/pull/5#pullrequestreview-11"}},
        html_url: "https://github.com/u7chan/agent-harness/pull/5#pullrequestreview-11",
        user: {login: "alice", id: 9001, type: "User"},
        submitted_at: "2026-09-01T00:00:00Z",
        commit_id: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
      },
      {
        id: 12,
        state: "APPROVED",
        body: "",
        node_id: "PRR_noise_12",
        author_association: "OWNER",
        pull_request_url: "https://api.github.com/repos/u7chan/agent-harness/pulls/5",
        links: {html: {href: "https://github.com/u7chan/agent-harness/pull/5#pullrequestreview-12"}},
        html_url: "https://github.com/u7chan/agent-harness/pull/5#pullrequestreview-12",
        user: {login: "alice", id: 9001, type: "User"},
        submitted_at: "2026-09-01T00:00:00Z",
        commit_id: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
      }
    ]')"
}

run_reviews_read() {
  local input_json="$1"
  local input_file

  input_file="$(mktemp /tmp/gh-reviews-input-XXXXXX)"
  printf '%s\n' "$input_json" > "$input_file"
  fixture_gh "reviews.read" "$input_file"
  local rc=$?
  rm -f "$input_file"
  return "$rc"
}

expected_keys='["body","commit_id","html_url","id","state","submitted_at","user"]'

test_reviews_read_list_no_fake_comments_count() (
  setup_fixture
  trap teardown_fixture EXIT
  install_reviews_mock

  local output
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"

  output="$(run_reviews_read '{"number":5}')" || return 1
  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.target.type' "pull_request" || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1
  assert_json_eq "$output" '.data.items | length' "2" || return 1
  assert_json_eq "$output" '.data.items[0].state' "APPROVED" || return 1
  assert_json_eq "$output" '.data.items[0].user.login' "alice" || return 1
  assert_json_eq "$output" '.data.items[0].commit_id' "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" || return 1
  assert_json_eq "$output" '.data.items[0].body | length' "500" || return 1
  assert_json_eq "$output" '.data.items[0] | has("node_id") | not' "true" || return 1
  assert_json_eq "$output" '.data.items[0] | has("body_text") | not' "true" || return 1

  # Issue #178: no item may carry a comments_count, every item keeps exactly
  # the contract keys, and the two body variants (500 chars vs. absent) are
  # identical apart from id, html_url, and body itself - the body length
  # must not change any count-like or other field.
  assert_json_eq "$output" '[.data.items[] | has("comments_count")] | any | not' "true" || return 1
  assert_json_eq "$output" "[.data.items[] | (keys | sort) == $expected_keys] | all" "true" || return 1
  assert_json_eq "$output" '(.data.items[0] | del(.id, .html_url, .body)) == (.data.items[1] | del(.id, .html_url, .body))' "true" || return 1

  # API cost stays at one paginated GET for the collection: no per-review
  # comment-count calls were added.
  assert_eq "$(grep -c 'api GET repos/u7chan/agent-harness/pulls/5/reviews per_page=' "$MOCK_GH_CALLS")" "1" || return 1
  if grep -q '/comments' "$MOCK_GH_CALLS"; then
    echo "unexpected per-review comment-count calls:"
    grep '/comments' "$MOCK_GH_CALLS"
    return 1
  fi
)

test_reviews_read_single_no_fake_comments_count() (
  setup_fixture
  trap teardown_fixture EXIT
  install_reviews_mock

  local output_long output_empty
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"

  # The same review fetched twice with different bodies: the single-review
  # read must be byte-identical apart from the body field itself.
  output_long="$(run_reviews_read '{"number":5,"review_id":11}')" || return 1
  export MOCK_REVIEWS="$(jq -nc '
    [{
      id: 11,
      state: "APPROVED",
      body: "",
      node_id: "PRR_noise_11",
      html_url: "https://github.com/u7chan/agent-harness/pull/5#pullrequestreview-11",
      user: {login: "alice", id: 9001, type: "User"},
      submitted_at: "2026-09-01T00:00:00Z",
      commit_id: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    }]')"
  output_empty="$(run_reviews_read '{"number":5,"review_id":11}')" || return 1

  assert_json_eq "$output_long" '.status' "ok" || return 1
  assert_json_eq "$output_long" '.target.type' "review" || return 1
  assert_json_eq "$output_long" '.data.item.id' "11" || return 1
  assert_json_eq "$output_long" '.data.item.body | length' "500" || return 1
  assert_json_eq "$output_empty" '.data.item.body | length' "0" || return 1
  assert_json_eq "$output_empty" '(.data.item | has("comments_count")) | not' "true" || return 1
  assert_json_eq "$output_empty" "(.data.item | keys | sort) == $expected_keys" "true" || return 1
  assert_json_eq "$output_long" "(.data.item | keys | sort) == $expected_keys" "true" || return 1
  assert_eq "$(jq -c '.data.item | del(.body)' <<< "$output_long")" \
    "$(jq -c '.data.item | del(.body)' <<< "$output_empty")" || return 1

  # Exactly one GET per single-review read; no per-review counting calls.
  assert_eq "$(grep -c 'api GET repos/u7chan/agent-harness/pulls/5/reviews/11 per_page=' "$MOCK_GH_CALLS")" "2" || return 1
  if grep -q '/comments' "$MOCK_GH_CALLS"; then
    echo "unexpected per-review comment-count calls:"
    grep '/comments' "$MOCK_GH_CALLS"
    return 1
  fi
)

main() {
  echo "=== reviews.read contract tests ==="
  run_test test_reviews_read_list_no_fake_comments_count
  run_test test_reviews_read_single_no_fake_comments_count
  print_summary
}

main
