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
if not args or args[0] != "api":
    print("unsupported mock command", file=sys.stderr)
    sys.exit(1)

if len(args) > 1 and args[1] == "user":
    if "--jq" in args:
        print("reviewer")
    else:
        output({"login": "reviewer"})
    sys.exit(0)

if len(args) > 1 and args[1] == "graphql":
    state = load()
    query = arg_value("query=", "")
    if os.environ.get("MOCK_GQL_MODE") != "1":
        output({"errors": [{"message": "graphql mode disabled"}]})
        sys.exit(0)
    threads = state.get("gql_threads", [])
    after = arg_value("after=", "null")
    if "PullRequestReviewThread" in query and "comments(first: 100)" in query:
        thread_id = arg_value("threadId=", "")
        thread = next((t for t in threads if t["id"] == thread_id), None)
        if thread is None:
            output({"data": {"node": None}})
            sys.exit(0)
        comments = thread.get("comments", [])
        is_resolved = thread["isResolved"]
        if os.environ.get("MOCK_THREAD_RESOLVED") == "1":
            is_resolved = True
        output({"data": {"node": {
            "id": thread["id"],
            "isResolved": is_resolved,
            "pullRequest": {
                "url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
                "repository": {"nameWithOwner": "u7chan/agent-harness"},
            },
            "comments": {
                "pageInfo": {"hasNextPage": len(comments) > 100, "endCursor": None},
                "nodes": comments[:100],
            },
        }}})
        sys.exit(0)
    if "reviewThreads(" in query:
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
            comments = thread["comments"]
            api_page.append({
                "id": thread["id"],
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
    if "node(id:" in query:
        thread_id = arg_value("threadId=", "")
        thread = next((t for t in threads if t["id"] == thread_id), None)
        if thread is None:
            output({"data": {"node": None}})
            sys.exit(0)
        comments = thread["comments"][100:]
        output({"data": {"node": {"comments": {
            "pageInfo": {"hasNextPage": False, "endCursor": None},
            "nodes": comments,
        }}}})
        sys.exit(0)
    output({"errors": [{"message": "unknown graphql query"}]})
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
    if os.environ.get("MOCK_POST_FAIL") == "1":
        print("mock post failed", file=sys.stderr)
        sys.exit(1)
    input_path = args[args.index("--input") + 1]
    with open(input_path, encoding="utf-8") as f:
        request = json.load(f)
    comment_id = state.get("next_id", max([c["id"] for c in state.get("comments", [])], default=0) + 1)
    comment = {
        "id": comment_id,
        "node_id": f"N{comment_id}",
        "body": request["body"],
        "html_url": f"https://github.com/u7chan/agent-harness/pull/200#discussion_r{comment_id}",
        "path": "review/SKILL.md",
        "position": 1,
        "line": 42,
        "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "in_reply_to_id": request["in_reply_to"],
        "pull_request_url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
        "user": {"login": "reviewer"},
        "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z",
        "last_edited_at": None,
        "author_association": "OWNER",
    }
    state.setdefault("comments", []).append(comment)
    state["next_id"] = comment_id + 1
    if os.environ.get("MOCK_POST_ADD_EXTRA") == "1":
        extra_id = state["next_id"]
        state["comments"].append({
            **comment,
            "id": extra_id,
            "body": "external concurrent reply",
            "html_url": f"https://github.com/u7chan/agent-harness/pull/200#discussion_r{extra_id}",
            "user": {"login": "other"},
        })
        state["next_id"] = extra_id + 1
    save(state)
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

setup_reply_fixture() {
  setup_fixture
  cp "$GH_ROOT/scripts/actions/review-comments.reply.sh" "$FIXTURE_DIR/scripts/actions/review-comments.reply.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-comments.reply.sh"
  write_mock_gh
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GQL_MODE=1
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
}

reply_request() {
  local ids="$1"
  local body="${2:-**Resolved**: old evidence}"
  jq -n --argjson ids "$ids" --arg body "$body" '{
    reference: "u7chan/agent-harness",
    number: 200,
    reply_to: 1,
    body: $body,
    thread_id: "T1",
    baseline_thread_resolved: false,
    plan_fingerprint: "fp-operation-1",
    baseline_comment_ids: $ids,
    grant: "write"
  }'
}

test_operation_scoped_dedup_and_pagination() (
  setup_reply_fixture
  trap teardown_fixture EXIT

  python3 - "$MOCK_GH_STATE" <<'PY'
import json, sys
comments = []
for i in range(1, 102):
    comments.append({
        "id": i,
        "node_id": f"N{i}",
        "body": "root" if i == 1 else ("**Resolved**: old evidence" if i != 3 else "later actor reply"),
        "html_url": f"https://github.com/u7chan/agent-harness/pull/200#discussion_r{i}",
        "path": "review/SKILL.md", "position": 1, "line": 42,
        "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "in_reply_to_id": None if i == 1 else 1,
        "pull_request_url": "https://api.github.com/repos/u7chan/agent-harness/pulls/200",
        "user": {"login": "reviewer" if i != 3 else "other"}, "created_at": "2026-08-22T00:00:00Z",
        "updated_at": "2026-08-22T00:00:00Z", "last_edited_at": None,
        "author_association": "OWNER",
    })
json.dump({
    "comments": comments,
    "next_id": 102,
    "gql_threads": [{"id": "T1", "isResolved": False,
                     "comments": [{"id": "N1", "databaseId": 1}]}],
}, open(sys.argv[1], "w"))
PY
  ids="$(seq 1 101 | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"
  request="$FIXTURE_DIR/request.json"
  reply_request "$ids" > "$request"
  output="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.transport_outcome' ok || return 1
  assert_json_eq "$output" '.data.id' 102 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1

  retry="$(fixture_gh review-comments.reply "$request")" || return 1
  assert_json_eq "$retry" '.status' already_applied || return 1
  assert_json_eq "$retry" '.data.id' 102 || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1
)

test_precondition_and_unknown_outcomes() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  cat > "$MOCK_GH_STATE" <<'JSON'
{"next_id":3,"comments":[
 {"id":1,"node_id":"N1","body":"root","html_url":"https://github.com/u7chan/agent-harness/pull/200#discussion_r1","path":"review/SKILL.md","position":1,"line":42,"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","in_reply_to_id":null,"pull_request_url":"https://api.github.com/repos/u7chan/agent-harness/pulls/200","user":{"login":"reviewer"},"created_at":"t","updated_at":"t","last_edited_at":null},
 {"id":2,"body":"external","html_url":"https://github.com/u7chan/agent-harness/pull/200#discussion_r2","path":"review/SKILL.md","position":1,"line":42,"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","in_reply_to_id":1,"pull_request_url":"https://api.github.com/repos/u7chan/agent-harness/pulls/200","user":{"login":"other"},"created_at":"t","updated_at":"t","last_edited_at":null}
],"gql_threads":[{"id":"T1","isResolved":false,"comments":[{"id":"N1","databaseId":1}]}]}
JSON
  request="$FIXTURE_DIR/request.json"
  reply_request '[1]' > "$request"
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' PRECONDITION_CHANGED || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1

  jq '.comments = [.comments[0]] | .comments[0].body = "edited root"' "$MOCK_GH_STATE" > "$MOCK_GH_STATE.tmp"
  mv "$MOCK_GH_STATE.tmp" "$MOCK_GH_STATE"
  jq '.baseline_comments = [{id:1,body:"root",in_reply_to_id:null,actor:"reviewer",path:"review/SKILL.md",line:42,commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",created_at:"t",updated_at:"t",last_edited_at:null}]' "$request" > "$request.tmp"
  mv "$request.tmp" "$request"
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' PRECONDITION_CHANGED || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1

  jq '.comments = [.comments[0]] | .comments[0].body = "root" | .next_id = 2' "$MOCK_GH_STATE" > "$MOCK_GH_STATE.tmp"
  mv "$MOCK_GH_STATE.tmp" "$MOCK_GH_STATE"
  jq 'del(.baseline_comments)' "$request" > "$request.tmp"
  mv "$request.tmp" "$request"
  export MOCK_POST_ADD_EXTRA=1
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' PRECONDITION_CHANGED || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 1 ] || return 1

  export MOCK_POST_ADD_EXTRA=0
  jq '.comments = [.comments[0]] | .comments[0].body = "root" | .next_id = 2' "$MOCK_GH_STATE" > "$MOCK_GH_STATE.tmp"
  mv "$MOCK_GH_STATE.tmp" "$MOCK_GH_STATE"
  export MOCK_POST_FAIL=1
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS")" = 2 ] || return 1
)

test_thread_state_precondition() (
  setup_reply_fixture
  trap teardown_fixture EXIT
  cat > "$MOCK_GH_STATE" <<'JSON'
{"next_id":2,"comments":[
 {"id":1,"node_id":"N1","body":"root","html_url":"https://github.com/u7chan/agent-harness/pull/200#discussion_r1","path":"review/SKILL.md","position":1,"line":42,"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","in_reply_to_id":null,"pull_request_url":"https://api.github.com/repos/u7chan/agent-harness/pulls/200","user":{"login":"reviewer"},"created_at":"t","updated_at":"t","last_edited_at":null}
],"gql_threads":[{"id":"T1","isResolved":false,"comments":[{"id":"N1","databaseId":1}]}]}
JSON
  request="$FIXTURE_DIR/request.json"
  reply_request '[1]' > "$request"
  export MOCK_THREAD_RESOLVED=1
  output="$(fixture_gh review-comments.reply "$request" 2>&1)" && return 1 || true
  assert_json_eq "$output" '.error.code' PRECONDITION_CHANGED || return 1
  [ "$(grep -c 'POST repos/u7chan/agent-harness/pulls/200/comments' "$MOCK_GH_CALLS" || true)" = 0 ] || return 1
)

test_threads_read_pagination() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/review-threads.read.sh" "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/review-threads.read.sh"
  write_mock_gh
  export PATH="$FIXTURE_DIR/bin:$PATH" GH_TEST_AUTH_RESULT=0 MOCK_GH_STATE="$FIXTURE_DIR/gql-state.json" MOCK_GQL_MODE=1
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
  run_test test_operation_scoped_dedup_and_pagination
  run_test test_precondition_and_unknown_outcomes
  run_test test_thread_state_precondition
  run_test test_threads_read_pagination
  print_summary
}

main
