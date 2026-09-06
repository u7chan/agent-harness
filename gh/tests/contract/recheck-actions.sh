#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

write_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_file = os.environ["MOCK_GH_STATE"]
calls_file = os.environ.get("MOCK_GH_CALLS")

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

if args[1] == "user":
    if "--jq" in args:
        print("reviewer")
    else:
        output({"login": "reviewer"})
    sys.exit(0)

if args[1] == "graphql":
    state = load()
    query = arg_value("query=", "")
    gql_calls_file = os.environ.get("MOCK_GH_GQL_CALLS")
    if gql_calls_file:
        if "reviewThreads(" in query:
            fingerprint = "reviewThreads"
        elif "unresolveReviewThread" in query:
            fingerprint = "unresolveReviewThread"
        elif "resolveReviewThread" in query:
            fingerprint = "resolveReviewThread"
        elif "node(id:" in query:
            fingerprint = "node"
        else:
            fingerprint = "other"
        with open(gql_calls_file, "a", encoding="utf-8") as f:
            f.write("graphql " + fingerprint + "\n")
    if os.environ.get("MOCK_GQL_MODE") != "1":
        output({"errors": [{"message": "graphql mode disabled"}]})
        sys.exit(0)
    threads = state.get("gql_threads", [])
    after = arg_value("after=", "null")
    def graphql_comments(thread):
        result = []
        for raw in thread.get("comments", []):
            if isinstance(raw, dict) and "databaseId" in raw:
                result.append({
                    "id": raw.get("id"),
                    "databaseId": raw.get("databaseId"),
                    "body": raw.get("body"),
                    "url": raw.get("url"),
                    "path": raw.get("path"),
                    "line": raw.get("line"),
                    "outdated": raw.get("outdated", False),
                    "commit": raw.get("commit"),
                    "replyTo": raw.get("replyTo"),
                    "author": raw.get("author"),
                    "authorAssociation": raw.get("authorAssociation"),
                    "createdAt": raw.get("createdAt"),
                    "updatedAt": raw.get("updatedAt"),
                    "lastEditedAt": raw.get("lastEditedAt"),
                })
            else:
                rest = state.get("comments", [])
                source = next((c for c in rest if c.get("node_id") == (raw.get("id") if isinstance(raw, dict) else raw)), {})
                result.append({
                    "id": source.get("node_id"),
                    "databaseId": source.get("id"),
                    "body": source.get("body"),
                    "url": source.get("html_url"),
                    "path": source.get("path"),
                    "line": source.get("line"),
                    "outdated": source.get("outdated", False),
                    "commit": {"oid": source.get("commit_id")},
                    "replyTo": source.get("gql_reply_to"),
                    "author": source.get("user"),
                    "authorAssociation": source.get("author_association"),
                    "createdAt": source.get("created_at"),
                    "updatedAt": source.get("updated_at"),
                    "lastEditedAt": source.get("last_edited_at"),
                })
        return result

    if "pullRequest { reviewThreads(" in query or "reviewThreads(" in query:
        if after in (None, "null", ""):
            page = threads[:100]
            next_page = len(threads) > 100
            end = "threads-100" if next_page else None
        else:
            page = threads[100:]
            next_page = False
            end = None
        api_page = []
        for thread in page:
            comments = graphql_comments(thread)
            api_page.append({
                "id": thread.get("node_id", thread["id"]) if isinstance(thread, dict) else thread,
                "isResolved": thread["isResolved"],
                "comments": {
                    "pageInfo": {
                        "hasNextPage": len(comments) > 100,
                        "endCursor": "comments-100" if len(comments) > 100 else None,
                    },
                    "nodes": comments[:100],
                },
            })
        output({"data": {"repository": {"pullRequest": {"reviewThreads": {
            "pageInfo": {"hasNextPage": next_page, "endCursor": end},
            "nodes": api_page,
        }}}}})
        sys.exit(0)

    thread_id = arg_value("threadId=", "")
    if "unresolveReviewThread" in query:
        thread = next((t for t in threads if (t.get("node_id", t["id"]) if isinstance(t, dict) else t) == thread_id), None)
        if thread is None:
            output({"errors": [{"message": "thread not found"}]})
            sys.exit(0)
        if isinstance(thread, dict):
            thread["isResolved"] = False
            resolved_id = thread.get("node_id", thread["id"])
        else:
            resolved_id = thread
        save(state)
        output({"data": {"unresolveReviewThread": {"thread": {"id": resolved_id, "isResolved": False}}}})
        sys.exit(0)
    if "resolveReviewThread" in query:
        thread = next((t for t in threads if (t.get("node_id", t["id"]) if isinstance(t, dict) else t) == thread_id), None)
        if thread is None:
            output({"errors": [{"message": "thread not found"}]})
            sys.exit(0)
        if isinstance(thread, dict):
            thread["isResolved"] = True
            resolved_id = thread.get("node_id", thread["id"])
        else:
            resolved_id = thread
        save(state)
        output({"data": {"resolveReviewThread": {"thread": {"id": resolved_id, "isResolved": True}}}})
        sys.exit(0)
    if "node(id:" in query:
        # Failure injection for regression tests: return the raw body from
        # MOCK_GQL_NODE_FAIL with the exit code MOCK_GQL_NODE_FAIL_RC
        # (default 1), mirroring how the real gh CLI surfaces GraphQL errors
        # (body on stdout, message on stderr, non-zero exit).
        node_fail = os.environ.get("MOCK_GQL_NODE_FAIL")
        if node_fail is not None:
            print(node_fail)
            print("gh: mock injected failure", file=sys.stderr)
            sys.exit(int(os.environ.get("MOCK_GQL_NODE_FAIL_RC", "1")))
        thread = next((t for t in threads if (t.get("node_id", t["id"]) if isinstance(t, dict) else t) == thread_id), None)
        if thread is None:
            # Mirror the real gh behavior for an unresolvable node id: the
            # body with data.node == null goes to stdout, the message to
            # stderr, and the exit code is non-zero.
            print(json.dumps({"data": {"node": None},
                              "errors": [{"type": "NOT_FOUND",
                                          "path": ["node"],
                                          "message": f"Could not resolve to a node with the global id of '{thread_id}'"}]},
                             ensure_ascii=False, separators=(",", ":")))
            print(f"gh: Could not resolve to a node with the global id of '{thread_id}'", file=sys.stderr)
            sys.exit(1)
        comments = graphql_comments(thread)
        start = 0
        if after not in (None, "null", ""):
            try:
                start = int(str(after).replace("comments-", ""))
            except ValueError:
                start = 0
        page = comments[start:start + 100]
        next_page = len(comments) > start + 100
        # A thread may override the owning pull request so membership checks
        # can be tested; the default is the fixture PR 200.
        pr_info = thread.get("pull_request") or {
            "url": "https://github.com/u7chan/agent-harness/pull/200",
            "number": 200,
            "repository": {"nameWithOwner": "u7chan/agent-harness"},
        }
        output({"data": {"node": {
            "id": thread.get("node_id", thread["id"]) if isinstance(thread, dict) else thread,
            "isResolved": thread["isResolved"],
            "pullRequest": pr_info,
            "comments": {
                "pageInfo": {"hasNextPage": next_page,
                              "endCursor": f"comments-{start + 100}" if next_page else None},
                "nodes": page,
            },
        }}})
        sys.exit(0)
    output({"errors": [{"message": "unknown graphql query"}]})
    sys.exit(0)

if args[1] == "repo" and args[2] == "view":
    if "--jq" in args:
        print("u7chan/agent-harness")
    else:
        output({"nameWithOwner": "u7chan/agent-harness"})
    sys.exit(0)

state = load()
endpoint = next((arg for arg in args[1:] if arg.startswith("repos/")), "")
method = "GET"
if "--method" in args:
    method = args[args.index("--method") + 1]
page = int(arg_value("page=", "1"))
per_page = int(arg_value("per_page=", "100"))

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(method + " " + endpoint + "\n")

if method == "POST" and endpoint.endswith("/comments"):
    input_path = args[args.index("--input") + 1]
    with open(input_path, encoding="utf-8") as f:
        request = json.load(f)
    comment = {
        "id": state.get("next_id", max([c["id"] for c in state.get("comments", [])], default=0) + 1),
        "node_id": f"N{state.get('next_id', max([c['id'] for c in state.get('comments', [])], default=0) + 1)}",
        "body": request["body"],
        "html_url": f"https://github.com/u7chan/agent-harness/pull/200#discussion_r{state.get('next_id', 2)}",
        "path": "review/SKILL.md",
        "position": 1,
        "line": 42,
        "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "in_reply_to_id": request["in_reply_to"],
        "pull_request_url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
        "user": {"login": "reviewer"},
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "author_association": "OWNER",
    }
    mode = os.environ.get("MOCK_POST_MODE", "ok")
    if mode == "fail":
        print("mock post failed", file=sys.stderr)
        sys.exit(1)
    comment_id = comment["id"]
    state.setdefault("comments", []).append(comment)
    state["next_id"] = comment_id + 1
    save(state)
    if mode == "writefail":
        print("mock post failed after write", file=sys.stderr)
        sys.exit(1)
    output(comment)
    sys.exit(0)

if endpoint.endswith("/pulls/200"):
    output({"url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
            "html_url": "https://github.com/u7chan/agent-harness/pull/200"})
    sys.exit(0)

if "/pulls/comments/" in endpoint:
    comment_id = int(endpoint.rsplit("/", 1)[1])
    comment = next((c for c in state.get("comments", []) if c["id"] == comment_id), None)
    if comment is None:
        sys.exit(1)
    output(comment)
    sys.exit(0)

if endpoint.endswith("/pulls/200/comments"):
    comments = state.get("comments", [])
    start = (page - 1) * per_page
    output(comments[start:start + per_page])
    sys.exit(0)

print("unsupported endpoint: " + endpoint, file=sys.stderr)
sys.exit(1)
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

setup_fixture_env() {
  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GQL_MODE=1
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  export MOCK_GH_GQL_CALLS="$FIXTURE_DIR/gql-calls.log"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_GH_GQL_CALLS"
}

# Number of GraphQL calls recorded by the mock; pass a fingerprint
# (reviewThreads, node, resolveReviewThread, other) or none for all calls.
gql_call_count() {
  local fingerprint="${1:-}"
  if [ -n "$fingerprint" ]; then
    grep -c "^graphql $fingerprint\$" "$MOCK_GH_GQL_CALLS" || true
  else
    grep -c "^graphql " "$MOCK_GH_GQL_CALLS" || true
  fi
}

setup_threads_read_fixture() {
  setup_fixture_env
  cp "$GH_ROOT/scripts/actions/review-threads.read.sh" "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  write_mock_gh
}

setup_reply_fixture() {
  setup_fixture_env
  cp "$GH_ROOT/scripts/actions/review-comments.reply.sh" "$FIXTURE_DIR/scripts/actions/review-comments.reply.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-comments.reply.sh"
  write_mock_gh
  export MOCK_POST_MODE=ok
}

setup_resolve_fixture() {
  setup_fixture_env
  cp "$GH_ROOT/scripts/actions/review-threads.resolve.sh" "$FIXTURE_DIR/scripts/actions/review-threads.resolve.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.resolve.sh"
  write_mock_gh
}

setup_unresolve_fixture() {
  setup_fixture_env
  cp "$GH_ROOT/scripts/actions/review-threads.unresolve.sh" "$FIXTURE_DIR/scripts/actions/review-threads.unresolve.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.unresolve.sh"
  write_mock_gh
}

reply_request() {
  local body="${1:-**Resolved**: old evidence}"
  jq -n --arg body "$body" '{
    reference: "u7chan/agent-harness",
    number: 200,
    reply_to: 1,
    body: $body,
    grant: "write"
  }'
}

root_comment() {
  jq -n --argjson id "${1:-1}" '{
    id: $id,
    node_id: ("N" + ($id | tostring)),
    body: "root",
    html_url: ("https://github.com/u7chan/agent-harness/pull/200#discussion_r" + ($id | tostring)),
    path: "review/SKILL.md",
    position: 1,
    line: 42,
    commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    in_reply_to_id: null,
    pull_request_url: "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
    user: {login: "reviewer"},
    created_at: "2026-08-22T00:00:00Z",
    updated_at: "2026-08-22T00:00:00Z",
    author_association: "OWNER"
  }'
}

reply_comment() {
  local id="$1"
  local body="$2"
  local root="$3"
  local actor="${4:-reviewer}"
  jq -n --argjson id "$id" --arg body "$body" --argjson root "$root" --arg actor "$actor" '{
    id: $id,
    node_id: ("N" + ($id | tostring)),
    body: $body,
    html_url: ("https://github.com/u7chan/agent-harness/pull/200#discussion_r" + ($id | tostring)),
    path: "review/SKILL.md",
    position: 1,
    line: 42,
    commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    in_reply_to_id: $root,
    pull_request_url: "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
    user: {login: $actor},
    created_at: "2026-08-22T00:00:00Z",
    updated_at: "2026-08-22T00:00:00Z",
    author_association: "OWNER"
  }'
}

test_reply_posts_and_dedups() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  jq -n --argjson root "$(root_comment 1)" '{comments: [$root], next_id: 2, gql_threads: []}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  reply_request > "$request"

  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.transport_outcome' ok || return 1
  assert_json_eq "$output" '.data.id' 2 || return 1
  assert_json_eq "$output" '.data.in_reply_to_id' 1 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1

  retry="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$retry" '.status' already_applied || return 1
  assert_json_eq "$retry" '.data.transport_outcome' already_applied || return 1
  assert_json_eq "$retry" '.data.id' 2 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1
)

test_reply_dedup_existing() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  jq -n --argjson root "$(root_comment 1)" \
    --argjson reply "$(reply_comment 2 '**Resolved**: old evidence' 1)" \
    '{comments: [$root, $reply], next_id: 3, gql_threads: []}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  reply_request > "$request"

  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.data.id' 2 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1

  # Same body from another actor is not a dedup match and is posted.
  jq -n --argjson root "$(root_comment 1)" \
    --argjson reply "$(reply_comment 2 '**Resolved**: old evidence' 1 other)" \
    '{comments: [$root, $reply], next_id: 3, gql_threads: []}' > "$MOCK_GH_STATE"
  : > "$MOCK_GH_CALLS"
  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.id' 3 || return 1
)

test_reply_dedup_pagination() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
root = {"id": 1, "node_id": "N1", "body": "root",
        "html_url": "https://github.com/u7chan/agent-harness/pull/200#discussion_r1",
        "path": "review/SKILL.md", "position": 1, "line": 42,
        "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "in_reply_to_id": None,
        "pull_request_url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
        "user": {"login": "reviewer"}, "created_at": "t", "updated_at": "t",
        "author_association": "OWNER"}
comments = [root]
for i in range(2, 102):
    comments.append({
        "id": i, "node_id": f"N{i}",
        "body": "unrelated" if i != 101 else "**Resolved**: old evidence",
        "html_url": f"https://github.com/u7chan/agent-harness/pull/200#discussion_r{i}",
        "path": "review/SKILL.md", "position": 1, "line": 42,
        "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "in_reply_to_id": 1,
        "pull_request_url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
        "user": {"login": "reviewer"}, "created_at": "t", "updated_at": "t",
        "author_association": "OWNER",
    })
json.dump({"comments": comments, "next_id": 102, "gql_threads": []}, open(sys.argv[1], "w"))
PY
  request="$FIXTURE_DIR/request.json"
  reply_request > "$request"
  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.data.id' 101 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1
)

test_reply_post_failure_adopts() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  jq -n --argjson root "$(root_comment 1)" '{comments: [$root], next_id: 2, gql_threads: []}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  reply_request > "$request"

  # POST fails after the write landed: the re-read adopts the exact reply.
  export MOCK_POST_MODE=writefail
  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.data.transport_outcome' already_applied || return 1
  assert_json_eq "$output" '.data.id' 2 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1

  # POST fails without a write: no reply to adopt, outcome unknown.
  jq -n --argjson root "$(root_comment 1)" '{comments: [$root], next_id: 2, gql_threads: []}' > "$MOCK_GH_STATE"
  : > "$MOCK_GH_CALLS"
  export MOCK_POST_MODE=fail
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1
)

test_reply_mismatch() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  jq -n --argjson root "$(root_comment 1 | jq '.pull_request_url = "https://api.github.com/repos/u7chan/agent-harness/pulls/999"')" \
    '{comments: [$root], next_id: 2, gql_threads: []}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  reply_request > "$request"
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' REPLY_MISMATCH || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1
)

test_manual_resolve() (
  setup_resolve_fixture
  trap teardown_fixture EXIT
  echo '{"gql_threads": [{"id": "T1", "isResolved": false}]}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  jq -n '{thread_id: "T1", grant: "sensitive-write"}' > "$request"

  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.outcome' resolved_by_run || return 1
  assert_json_eq "$output" '.data.resolved' true || return 1
  assert_json_eq "$output" '.target.id' T1 || return 1

  # Already-resolved thread returns already_applied.
  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.data.outcome' already_resolved_external || return 1
)

# A foreign-PR thread entry: the thread lives in octocat/other-repo, not the
# fixture CWD repository u7chan/agent-harness.
foreign_thread() {
  local resolved="${1:-false}"
  jq -n --argjson resolved "$resolved" '{
    id: "T1",
    isResolved: $resolved,
    pull_request: {
      url: "https://github.com/octocat/other-repo/pull/7",
      number: 7,
      repository: {nameWithOwner: "octocat/other-repo"}
    }
  }'
}

# Issue #155: the review skill pins every action to the PR-derived owner/repo
# via reference. resolve must accept a reference-bearing request and anchor
# the target (and the membership check) to that repository, not the CWD one.
test_manual_resolve_accepts_reference () (
  setup_resolve_fixture
  trap teardown_fixture EXIT
  jq -n --argjson thread "$(foreign_thread false)" '{gql_threads: [$thread]}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference: "octocat/other-repo", thread_id: "T1", grant: "sensitive-write"}' > "$request"

  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.outcome' resolved_by_run || return 1
  assert_json_eq "$output" '.data.resolved' true || return 1
  assert_json_eq "$output" '.target.repository' "octocat/other-repo" || return 1
)

# Issue #155: a reference that does not match the thread's owning repository
# must be rejected before the mutation fires.
test_manual_resolve_reference_mismatch_rejected_before_mutation () (
  setup_resolve_fixture
  trap teardown_fixture EXIT

  # reference (u7chan/agent-harness) vs the thread's actual repository.
  jq -n --argjson thread "$(foreign_thread false)" '{gql_threads: [$thread]}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference: "u7chan/agent-harness", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.resolve "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' TARGET_MISMATCH || return 1
  [ "$(gql_call_count unresolveReviewThread)" = 0 ] || return 1
  [ "$(gql_call_count resolveReviewThread)" = 0 ] || return 1

  # Reverse direction: reference points elsewhere, thread belongs to the
  # fixture CWD repository.
  echo '{"gql_threads": [{"id": "T1", "isResolved": false}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "octocat/other-repo", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.resolve "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' TARGET_MISMATCH || return 1
  [ "$(gql_call_count resolveReviewThread)" = 0 ] || return 1
)

# Issue #155: reference omitted keeps the CWD-based behavior (existing
# callers and the smoke path are unaffected).
test_manual_resolve_cwd_compat () (
  setup_resolve_fixture
  trap teardown_fixture EXIT
  echo '{"gql_threads": [{"id": "T1", "isResolved": false}]}' > "$MOCK_GH_STATE"
  request="$FIXTURE_DIR/request.json"
  jq -n '{thread_id: "T1", grant: "sensitive-write"}' > "$request"

  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1
)

# Issue #155: unresolve shares the resolve input shape, so it gets the same
# optional-reference contract: accepted and pinned, mismatch rejected before
# the mutation, and omission keeps the CWD repository.
test_manual_unresolve_reference_contract () (
  setup_unresolve_fixture
  trap teardown_fixture EXIT
  request="$FIXTURE_DIR/request.json"

  # Reference accepted and pinned.
  echo '{"gql_threads": [{"id": "T1", "isResolved": true}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "u7chan/agent-harness", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.unresolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.resolved | tostring' false || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1

  # Mismatch is rejected before the mutation. Truncate the call log first so
  # the count reflects only this dispatch (case 1 legitimately mutated).
  : > "$MOCK_GH_GQL_CALLS"
  jq -n --argjson thread "$(foreign_thread true)" '{gql_threads: [$thread]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "u7chan/agent-harness", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.unresolve "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' TARGET_MISMATCH || return 1
  [ "$(gql_call_count unresolveReviewThread)" = 0 ] || return 1

  # Reference omitted keeps the CWD repository.
  echo '{"gql_threads": [{"id": "T1", "isResolved": true}]}' > "$MOCK_GH_STATE"
  jq -n '{thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.unresolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.repository' "u7chan/agent-harness" || return 1
)

# PR #164 review follow-up: reference spellings that differ only in case
# must not stop the membership check. The comparison is normalized like
# review-threads.read (owner/repo lowercased on both sides) for both the
# owner/repo and PR URL reference forms, on both mutation actions.
test_manual_mutation_reference_case_insensitive () (
  # Both action scripts share the fixture.
  setup_unresolve_fixture
  cp "$GH_ROOT/scripts/actions/review-threads.resolve.sh" "$FIXTURE_DIR/scripts/actions/review-threads.resolve.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.resolve.sh"
  trap teardown_fixture EXIT
  request="$FIXTURE_DIR/request.json"

  # owner/repo form: uppercase spelling vs the thread's canonical lowercase
  # repository; the envelope keeps the caller's spelling.
  echo '{"gql_threads": [{"id": "T1", "isResolved": false}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "U7chan/Agent-Harness", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.outcome' resolved_by_run || return 1
  assert_json_eq "$output" '.target.repository' "U7chan/Agent-Harness" || return 1

  # PR URL form: case-differing URL resolves to the same repository. Reset
  # the thread state first - case 1's dispatch resolved it in the mock.
  echo '{"gql_threads": [{"id": "T1", "isResolved": false}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "https://github.com/U7chan/Agent-Harness/pull/200", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.resolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.outcome' resolved_by_run || return 1

  # unresolve: same two forms against a currently resolved thread.
  echo '{"gql_threads": [{"id": "T1", "isResolved": true}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "U7chan/Agent-Harness", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.unresolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.resolved | tostring' false || return 1

  # PR URL form on a fresh resolved thread (case 3's dispatch unresolved it
  # in the mock).
  echo '{"gql_threads": [{"id": "T1", "isResolved": true}]}' > "$MOCK_GH_STATE"
  jq -n '{reference: "https://github.com/U7chan/Agent-Harness/pull/200", thread_id: "T1", grant: "sensitive-write"}' > "$request"
  output="$(fixture_gh review-threads.unresolve "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.resolved | tostring' false || return 1
)

test_threads_read_pagination() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(thread, n, root=False):
    return {"id": f"C{thread}-{n}", "databaseId": (thread + 1) * 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{thread}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = []
for t in range(101):
    count = 101 if t == 0 else 1
    threads.append({"id": f"T{t}", "isResolved": False,
                    "comments": [comment(t, n, n == 0) for n in range(count)]})
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference:"u7chan/agent-harness",number:200,per_page:100}' > "$request"
  output="$(fixture_gh review-threads.read "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads | length' 101 || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 101 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[100].id' C0-100 || return 1
)

# Issue #153 acceptance 1/3/4: confirming one thread by thread_id must not
# depend on the number of unrelated threads. The scoped read issues exactly
# one GraphQL node call, no matter how many threads or unrelated comments the
# PR holds, and the fresh read reflects a changed resolved state.
test_threads_read_scoped_avoids_collection() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = []
for t in range(101):
    count = 3 if t == 5 else 1
    threads.append({"id": f"T{t}", "isResolved": False,
                    "comments": [comment(t, n, n == 0) for n in range(count)]})
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference:"u7chan/agent-harness",number:200,thread_id:"T5"}' > "$request"

  output="$(fixture_gh review-threads.read "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads | length' 1 || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' T5 || return 1
  assert_json_eq "$output" '.data.threads[0].resolved | tostring' "false" || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 3 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[1].in_reply_to_id' C5-0 || return 1
  assert_json_eq "$output" '.data.pagination.threads_complete' true || return 1
  assert_json_eq "$output" '.data.pagination.comments_complete' true || return 1
  # 100 unrelated threads on the PR: no collection page, one node call.
  assert_eq "$(gql_call_count reviewThreads)" "0" || return 1
  assert_eq "$(gql_call_count)" "1" || return 1

  # Growing the PR to 250 threads, 149 comments on an unrelated thread, and
  # resolving the target thread must not change the scoped read's API count.
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = []
for t in range(250):
    count = 3 if t == 5 else (150 if t == 0 else 1)
    threads.append({"id": f"T{t}", "isResolved": t == 5,
                    "comments": [comment(t, n, n == 0) for n in range(count)]})
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  : > "$MOCK_GH_GQL_CALLS"
  output="$(fixture_gh review-threads.read "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' T5 || return 1
  assert_json_eq "$output" '.data.threads[0].resolved' true || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 3 || return 1
  assert_eq "$(gql_call_count reviewThreads)" "0" || return 1
  assert_eq "$(gql_call_count)" "1" || return 1
)

# Issue #153 acceptance 2: the scoped read keeps fetch completeness. A thread
# with more than one comment page is paginated to the tail with the same
# pageInfo/nodes validation, so root and tail are fully available.
test_threads_read_scoped_comment_pagination() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = [{"id": "T0", "isResolved": False,
            "comments": [comment(0, n, n == 0) for n in range(250)]}]
for t in range(1, 4):
    threads.append({"id": f"T{t}", "isResolved": False,
                    "comments": [comment(t, 0, True)]})
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference:"u7chan/agent-harness",number:200,thread_id:"T0"}' > "$request"

  output="$(fixture_gh review-threads.read "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads | length' 1 || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' T0 || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 250 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[99].id' C0-99 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[100].id' C0-100 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[249].id' C0-249 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[249].in_reply_to_id' C0-0 || return 1
  assert_json_eq "$output" '.data.pagination.comments_complete' true || return 1
  # One first page plus two continuation pages; no collection calls.
  assert_eq "$(gql_call_count reviewThreads)" "0" || return 1
  assert_eq "$(gql_call_count node)" "3" || return 1
)

# Issue #153 acceptance 2: PR membership is verified, not weakened. A node
# that is unknown, not a review thread, or owned by another repository or
# another PR is not returned as a thread of the target PR (the same
# filtered-empty contract the collection path had), while a matching thread
# is returned.
test_threads_read_scoped_membership() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t):
    tid = f"T{t}"
    return {"id": f"C{t}-0", "databaseId": 1000,
            "body": "root", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None,
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = [
    {"id": "Tok", "isResolved": False, "comments": [comment("ok")]},
    {"id": "Tforeign", "isResolved": False, "comments": [comment("foreign")],
     "pull_request": {"url": "https://github.com/octocat/other/pull/7", "number": 7,
                      "repository": {"nameWithOwner": "octocat/other"}}},
    {"id": "Totherpr", "isResolved": False, "comments": [comment("Totherpr")],
     "pull_request": {"url": "https://github.com/u7chan/agent-harness/pull/999", "number": 999,
                      "repository": {"nameWithOwner": "u7chan/agent-harness"}}},
]
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  run_scoped_read() {
    local tid="$1"
    jq -n --arg tid "$tid" '{reference:"u7chan/agent-harness",number:200,thread_id:$tid}' > "$FIXTURE_DIR/request.json"
    fixture_gh review-threads.read "$FIXTURE_DIR/request.json"
  }

  output="$(run_scoped_read Tforeign)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads' '[]' || return 1

  output="$(run_scoped_read Totherpr)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads' '[]' || return 1

  output="$(run_scoped_read Tmissing)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads' '[]' || return 1

  output="$(run_scoped_read Tok)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads | length' 1 || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' Tok || return 1
  assert_json_eq "$output" '.data.threads[0].comments[0].user.login' reviewer || return 1
)

# Issue #162 Blocker regression: only the exact NOT_FOUND response for an
# unresolvable node id maps to the filtered-empty contract. FORBIDDEN,
# HTTP-level error JSON, and incomplete success bodies must surface as
# API_ERROR like the collection path, not as an empty success.
test_threads_read_scoped_failure_classification() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = [
    {"id": "Tok", "isResolved": False,
     "comments": [comment("ok", 0, True), comment("ok", 1)]},
    {"id": "Tother", "isResolved": False, "comments": [comment("other", 0, True)]},
]
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  run_scoped_read() {
    local tid="$1"
    jq -n --arg tid "$tid" '{reference:"u7chan/agent-harness",number:200,thread_id:$tid}' > "$FIXTURE_DIR/request.json"
    fixture_gh review-threads.read "$FIXTURE_DIR/request.json"
  }

  # FORBIDDEN with a node-null body: non-zero exit, must stay a failure.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null},"errors":[{"type":"FORBIDDEN","path":["node"],"message":"Resource not accessible by integration"}]}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tok 2>&1)"; then
    echo "FORBIDDEN unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # HTTP-level error JSON without data: non-zero exit, must stay a failure.
  if output="$(MOCK_GQL_NODE_FAIL='{"message":"API rate limit exceeded"}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tok 2>&1)"; then
    echo "rate-limit body unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # Incomplete success body: data present but the node key missing.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{}}' MOCK_GQL_NODE_FAIL_RC=0 run_scoped_read Tok 2>&1)"; then
    echo "incomplete body unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # A NOT_FOUND error mixed with another type is not the unresolvable-node
  # shape: it must stay a failure instead of an empty success.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"message":"Could not resolve to a node"},{"type":"FORBIDDEN","path":["node"],"message":"Resource not accessible by integration"}]}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tok 2>&1)"; then
    echo "mixed-error body unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # A node-null body without errors on a non-zero exit: the exit code is not
  # discarded, so this stays a failure instead of an empty success.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null}}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tok 2>&1)"; then
    echo "node-null body with non-zero exit unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # A non-object node (array) on a normal exit: invalid node form, failure.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":[]}}' MOCK_GQL_NODE_FAIL_RC=0 run_scoped_read Tok 2>&1)"; then
    echo "array node unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # A NOT_FOUND on a child path (e.g. ["node","pullRequest"]) is a child
  # fetch error, not an unresolvable id: must stay a failure.
  if output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node","pullRequest"],"message":"Could not fetch pullRequest"}]}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tok 2>&1)"; then
    echo "child-path NOT_FOUND unexpectedly succeeded"
    return 1
  fi
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1

  # Control: the exact NOT_FOUND shape for an unresolvable id keeps the
  # filtered-empty contract, on a non-zero exit...
  output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"message":"Could not resolve to a node with the global id of Tmissing"}]}' MOCK_GQL_NODE_FAIL_RC=1 run_scoped_read Tmissing 2>&1)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads' '[]' || return 1

  # ...and on a normal exit.
  output="$(MOCK_GQL_NODE_FAIL='{"data":{"node":null},"errors":[{"type":"NOT_FOUND","path":["node"],"message":"Could not resolve to a node with the global id of Tmissing"}]}' MOCK_GQL_NODE_FAIL_RC=0 run_scoped_read Tmissing 2>&1)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads' '[]' || return 1

  # Control: without injection the matching thread is returned unchanged.
  output="$(run_scoped_read Tok)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' Tok || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 2 || return 1
)

# Issue #162 Blocker regression: the membership comparison must be
# case-insensitive. resolve_pr_target keeps the reference spelling while
# nameWithOwner is canonical, so a differently cased owner/repo must still
# find the existing thread instead of returning an empty list.
test_threads_read_scoped_reference_case_insensitive() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = [
    {"id": "T0", "isResolved": False,
     "comments": [comment(0, n, n == 0) for n in range(3)]},
]
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  request="$FIXTURE_DIR/request.json"
  jq -n '{reference:"U7chan/Agent-Harness",number:200,thread_id:"T0"}' > "$request"

  output="$(fixture_gh review-threads.read "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.threads | length' 1 || return 1
  assert_json_eq "$output" '.data.threads[0].thread_id' T0 || return 1
  assert_json_eq "$output" '.data.threads[0].resolved | tostring' "false" || return 1
  assert_json_eq "$output" '.data.threads[0].comments | length' 3 || return 1
  assert_json_eq "$output" '.data.threads[0].comments[1].in_reply_to_id' C0-0 || return 1
)

# The scoped read's envelope is byte-compatible with the collection path's
# output filtered to the same thread (single authoritative schema).
test_threads_read_scoped_matches_collection_shape() (
  setup_threads_read_fixture
  trap teardown_fixture EXIT
  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
def comment(t, n, root=False):
    tid = f"T{t}"
    return {"id": f"C{t}-{n}", "databaseId": 1000 + n,
            "body": "root" if root else f"reply-{n}", "url": "u", "path": "a",
            "line": 1, "outdated": False, "commit": {"oid": "h"},
            "replyTo": None if root else {"id": f"C{t}-0"},
            "author": {"login": "reviewer"}, "authorAssociation": "OWNER",
            "createdAt": "same", "updatedAt": "same", "lastEditedAt": None}
threads = [
    {"id": "T0", "isResolved": False,
     "comments": [comment(0, n, n == 0) for n in range(2)]},
    {"id": "T1", "isResolved": False, "comments": [comment(1, 0, True)]},
]
json.dump({"gql_threads": threads}, open(sys.argv[1], "w"))
PY
  full_request="$FIXTURE_DIR/full.json"
  scoped_request="$FIXTURE_DIR/scoped.json"
  jq -n '{reference:"u7chan/agent-harness",number:200}' > "$full_request"
  jq -n '{reference:"u7chan/agent-harness",number:200,thread_id:"T0"}' > "$scoped_request"

  full_output="$(fixture_gh review-threads.read "$full_request")" || return 1
  scoped_output="$(fixture_gh review-threads.read "$scoped_request")" || return 1

  full_thread="$(jq -c '[.data.threads[] | select(.thread_id == "T0")]' <<< "$full_output")"
  scoped_thread="$(jq -c '.data.threads' <<< "$scoped_output")"
  assert_eq "$scoped_thread" "$full_thread" || return 1
)

main() {
  echo "=== review action contract tests ==="
  run_test test_reply_posts_and_dedups
  run_test test_reply_dedup_existing
  run_test test_reply_dedup_pagination
  run_test test_reply_post_failure_adopts
  run_test test_reply_mismatch
  run_test test_manual_resolve
  run_test test_manual_resolve_accepts_reference
  run_test test_manual_resolve_reference_mismatch_rejected_before_mutation
  run_test test_manual_resolve_cwd_compat
  run_test test_manual_unresolve_reference_contract
  run_test test_manual_mutation_reference_case_insensitive
  run_test test_threads_read_pagination
  run_test test_threads_read_scoped_avoids_collection
  run_test test_threads_read_scoped_comment_pagination
  run_test test_threads_read_scoped_membership
  run_test test_threads_read_scoped_failure_classification
  run_test test_threads_read_scoped_reference_case_insensitive
  run_test test_threads_read_scoped_matches_collection_shape
  print_summary
}

main
