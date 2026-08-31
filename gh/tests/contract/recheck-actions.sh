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
        thread = next((t for t in threads if (t.get("node_id", t["id"]) if isinstance(t, dict) else t) == thread_id), None)
        if thread is None:
            output({"data": {"node": None}})
            sys.exit(0)
        comments = graphql_comments(thread)
        start = 0 if after in (None, "null", "") else 100
        page = comments[start:start + 100]
        next_page = len(comments) > start + 100
        output({"data": {"node": {
            "id": thread.get("node_id", thread["id"]) if isinstance(thread, dict) else thread,
            "isResolved": thread["isResolved"],
            "pullRequest": {"url": "https://github.com/u7chan/agent-harness/pull/200",
                            "number": 200,
                            "repository": {"nameWithOwner": "u7chan/agent-harness"}},
            "comments": {
                "pageInfo": {"hasNextPage": next_page,
                              "endCursor": "comments-100" if next_page else None},
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
  : > "$MOCK_GH_CALLS"
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

test_threads_read_pagination() (
  setup_fixture_env
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/review-threads.read.sh" "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  write_mock_gh
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

main() {
  echo "=== review action contract tests ==="
  run_test test_reply_posts_and_dedups
  run_test test_reply_dedup_existing
  run_test test_reply_dedup_pagination
  run_test test_reply_post_failure_adopts
  run_test test_reply_mismatch
  run_test test_manual_resolve
  run_test test_threads_read_pagination
  print_summary
}

main