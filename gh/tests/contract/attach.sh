#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Mock gh CLI: supports --version, repo view, api user, the REST endpoints
# used by the attach flows, and the issue/pr create/edit/comment subcommands.
# Attachment body processing is controlled by MOCK_ATTACH_MODE:
#   ok        - rewrite referenced paths to URLs, append unreferenced files
#   norewrite - never rewrite references (missing rewrite simulation)
#   noappend  - never append unreferenced files (missing append simulation)
write_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

state_file = os.environ["MOCK_GH_STATE"]
gh_version = os.environ.get("MOCK_GH_VERSION", "2.99.0")
attach_mode = os.environ.get("MOCK_ATTACH_MODE", "ok")


def load():
    with open(state_file, encoding="utf-8") as f:
        return json.load(f)


def save(state):
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def parse_args():
    pos = []
    flags = {}
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("-"):
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                flags.setdefault(a, []).append(args[i + 1])
                i += 2
            else:
                flags.setdefault(a, [])
                i += 1
        else:
            pos.append(a)
            i += 1
    return pos, flags


def one(flags, name, default=""):
    vals = flags.get(name, [])
    return vals[0] if vals else default


def process_body(body, attaches):
    out = body
    idx = 0
    appended = []
    for item in attaches:
        path = item.split("#", 1)[0]
        if attach_mode != "norewrite" and path in out:
            out = out.replace(path, "https://attachments.example/%d.png" % idx)
            idx += 1
        else:
            appended.append(item)
    if attach_mode != "noappend":
        for item in appended:
            path = item.split("#", 1)[0]
            alt = item.split("#", 1)[1] if "#" in item else ""
            name = os.path.basename(path)
            if out:
                out += "\n\n"
            out += "![%s](https://attachments.example/%d.png)" % (alt or name, idx)
            idx += 1
    return out


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


args = sys.argv[1:]
if not args:
    fail("unsupported mock command")

if args[0] == "--version":
    print("gh version %s (mock)" % gh_version)
    sys.exit(0)

if args[0] == "repo" and args[1] == "view":
    if "--jq" in args:
        print("u7chan/agent-harness")
    else:
        output({"nameWithOwner": "u7chan/agent-harness"})
    sys.exit(0)

state = load()

if args[0] == "api":
    if args[1] == "user":
        if "--jq" in args:
            print("u7chan")
        else:
            output({"login": "u7chan"})
        sys.exit(0)
    endpoint = next((a for a in args[1:] if a.startswith("repos/")), "")
    if not endpoint:
        fail("unsupported api call")
    if "/issues/comments/" in endpoint:
        cid = int(endpoint.rsplit("/", 1)[1])
        for c in state.get("comments", []):
            if c["id"] == cid:
                output(c)
                sys.exit(0)
        fail("comment not found")
    if "/issues/" in endpoint:
        n = int(endpoint.rsplit("/", 1)[1])
        for i in state.get("issues", []):
            if i["number"] == n:
                output(i)
                sys.exit(0)
        for p in state.get("prs", []):
            if p["number"] == n:
                out = dict(p)
                out["pull_request"] = {"url": p["html_url"]}
                output(out)
                sys.exit(0)
        fail("issue not found")
    if "/pulls/" in endpoint:
        n = int(endpoint.rsplit("/", 1)[1])
        for p in state.get("prs", []):
            if p["number"] == n:
                output(p)
                sys.exit(0)
        fail("pr not found")
    if "/milestones/" in endpoint:
        n = endpoint.rsplit("/", 1)[1]
        output({"number": int(n), "title": "Milestone %s" % n})
        sys.exit(0)
    if "/git/ref/heads/" in endpoint:
        output({"ref": "refs/heads/" + endpoint.rsplit("/", 1)[1],
                "object": {"sha": "a" * 40}})
        sys.exit(0)
    if "pulls?" in endpoint or endpoint.endswith("/pulls"):
        output([])
        sys.exit(0)
    fail("unsupported endpoint: " + endpoint)

if args[0] in ("issue", "pr") and args[1] in ("create", "edit", "comment"):
    pos, flags = parse_args()
    pos = pos[2:]
    sub = args[1]
    repo = one(flags, "--repo")
    title = one(flags, "--title")
    base = one(flags, "--base")
    head = one(flags, "--head")
    body_file = one(flags, "--body-file")
    attaches = flags.get("--attach", [])
    labels = flags.get("--label", [])
    assignees = flags.get("--assignee", [])
    milestone = one(flags, "--milestone")
    parent = one(flags, "--parent")
    with open(body_file, encoding="utf-8") as f:
        body = f.read()
    body = process_body(body, attaches)

    if args[0] == "issue":
        if sub == "create":
            n = state["next_issue"]
            state["next_issue"] += 1
            issue = {
                "id": n, "number": n, "title": title, "body": body,
                "state": "open",
                "html_url": "https://github.com/%s/issues/%d" % (repo, n),
                "user": {"login": "u7chan"},
                "labels": [{"name": l} for l in labels],
                "assignees": [{"login": a} for a in assignees],
                "milestone": {"title": milestone} if milestone else None,
                "created_at": "2026-09-01T00:00:00Z",
                "updated_at": "2026-09-01T00:00:00Z",
            }
            state.setdefault("issues", []).append(issue)
            save(state)
            print(issue["html_url"])
            sys.exit(0)
        if sub == "edit":
            n = int(pos[0])
            issue = next((i for i in state.get("issues", [])
                          if i["number"] == n), None)
            if issue is None:
                fail("issue not found")
            if "--title" in flags:
                issue["title"] = title
            if "--body-file" in flags:
                issue["body"] = body
            save(state)
            print(issue["html_url"])
            sys.exit(0)
        if sub == "comment":
            n = int(pos[0])
            cid = state["next_comment"]
            state["next_comment"] += 1
            comment = {
                "id": cid, "body": body,
                "html_url": "https://github.com/%s/issues/%d#issuecomment-%d" % (repo, n, cid),
                "user": {"login": "u7chan"},
                "created_at": "2026-09-01T00:00:00Z",
                "updated_at": "2026-09-01T00:00:00Z",
                "author_association": "OWNER",
            }
            state.setdefault("comments", []).append(comment)
            save(state)
            print(comment["html_url"])
            sys.exit(0)

    if sub == "create":
        n = state["next_pr"]
        state["next_pr"] += 1
        pr = {
            "id": n, "number": n, "title": title, "body": body,
            "state": "open", "draft": "--draft" in flags,
            "html_url": "https://github.com/%s/pull/%d" % (repo, n),
            "user": {"login": "u7chan"},
            "labels": [], "assignees": [], "milestone": None,
            "maintainer_can_modify": "--no-maintainer-edit" not in flags,
            "created_at": "2026-09-01T00:00:00Z",
            "updated_at": "2026-09-01T00:00:00Z",
            "head": {"ref": head, "sha": "a" * 40,
                     "repo": {"full_name": repo}},
            "base": {"ref": base, "sha": "b" * 40,
                     "repo": {"full_name": repo}},
        }
        state.setdefault("prs", []).append(pr)
        save(state)
        print(pr["html_url"])
        sys.exit(0)
    if sub == "edit":
        n = int(pos[0])
        pr = next((p for p in state.get("prs", [])
                   if p["number"] == n), None)
        if pr is None:
            fail("pr not found")
        if "--title" in flags:
            pr["title"] = title
        if "--body-file" in flags:
            pr["body"] = body
        if "--base" in flags:
            pr["base"]["ref"] = base
        save(state)
        print(pr["html_url"])
        sys.exit(0)
    if sub == "comment":
        n = int(pos[0])
        cid = state["next_comment"]
        state["next_comment"] += 1
        comment = {
            "id": cid, "body": body,
            "html_url": "https://github.com/%s/pull/%d#issuecomment-%d" % (repo, n, cid),
            "user": {"login": "u7chan"},
            "created_at": "2026-09-01T00:00:00Z",
            "updated_at": "2026-09-01T00:00:00Z",
            "author_association": "OWNER",
        }
        state.setdefault("comments", []).append(comment)
        save(state)
        print(comment["html_url"])
        sys.exit(0)

fail("unsupported mock command: " + " ".join(args))
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# setup_attach_fixture <action-name>
# Builds the fixture (mock gh on PATH, seeded empty state), copies the action
# script under test, and moves into a work directory so relative attachment
# paths resolve.
setup_attach_fixture() {
  local action_name="$1"

  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_VERSION="${MOCK_GH_VERSION:-2.99.0}"
  export MOCK_ATTACH_MODE="${MOCK_ATTACH_MODE:-ok}"
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  jq -n '{issues: [], prs: [], comments: [], next_issue: 1, next_pr: 1, next_comment: 1}' > "$MOCK_GH_STATE"
  mkdir -p "$FIXTURE_DIR/work"
  cp "$GH_ROOT/scripts/actions/$action_name.sh" "$FIXTURE_DIR/scripts/actions/$action_name.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/$action_name.sh"
  write_mock_gh
  cd "$FIXTURE_DIR/work" || return 1
}

make_attachment() {
  printf 'attachment-%s' "$1" > "$FIXTURE_DIR/work/$1"
}

seed_issue() {
  local n="$1"
  local title="$2"
  local body="$3"
  jq -n \
    --argjson n "$n" --arg title "$title" --arg body "$body" \
    '{issues: [{id: $n, number: $n, title: $title, body: $body, state: "open",
                html_url: ("https://github.com/u7chan/agent-harness/issues/" + ($n|tostring)),
                user: {login: "u7chan"}, labels: [], assignees: [], milestone: null,
                created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z"}],
      prs: [], comments: [], next_issue: ($n + 1), next_pr: 1, next_comment: 1}' > "$MOCK_GH_STATE"
}

seed_pr() {
  local n="$1"
  local title="$2"
  local body="$3"
  jq -n \
    --argjson n "$n" --arg title "$title" --arg body "$body" \
    '{issues: [],
      prs: [{id: $n, number: $n, title: $title, body: $body, state: "open", draft: false,
             html_url: ("https://github.com/u7chan/agent-harness/pull/" + ($n|tostring)),
             user: {login: "u7chan"}, labels: [], assignees: [], milestone: null,
             maintainer_can_modify: true,
             created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
             head: {ref: "feat/x", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: "u7chan/agent-harness"}},
             base: {ref: "main", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", repo: {full_name: "u7chan/agent-harness"}}}],
      comments: [], next_issue: 1, next_pr: ($n + 1), next_comment: 1}' > "$MOCK_GH_STATE"
}

request_file() {
  printf '%s\n' "$FIXTURE_DIR/request.json"
}
# --- Dispatcher-level input validation -------------------------------------

test_attach_schema_type_mismatch() {
  setup_fixture
  trap teardown_fixture EXIT
  export GH_TEST_AUTH_RESULT=0

  local input_file output rc
  input_file="$(mktemp /tmp/gh-contract-input-XXXXXX)"
  printf '%s\n' '{"title":"t","attachments":"not-an-array","grant":"write"}' > "$input_file"
  output="$(fixture_gh issue.create "$input_file" 2>/dev/null)"
  rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.error.code' "TYPE_MISMATCH" || return 1
}

# --- Gates (ATTACH_UNSUPPORTED) ---------------------------------------------

test_attach_unsupported_version() (
  export MOCK_GH_VERSION=2.98.0
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n '{title: "t", body: "b", attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' ATTACH_UNSUPPORTED || return 1
  assert_contains "$output" "2.99.0" || return 1
)

test_attach_unsupported_host() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  cat > "$FIXTURE_DIR/scripts/common/auth.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
check_auth() { return 0; }
get_host() { echo "ghe.example.com"; }
EOF
  make_attachment shot.png

  jq -n '{title: "t", body: "b", attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' ATTACH_UNSUPPORTED || return 1
)

test_attach_too_many() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT

  # 51 items: the count gate fires before any path validation, so the files
  # do not need to exist.
  jq -nc '{title: "t", body: "b", grant: "write",
           attachments: [range(0; 51) | "a\(.).png"]}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_UNSUPPORTED || return 1
  assert_contains "$output" "50" || return 1
)

test_attach_max_count_boundary() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT

  # Exactly 50 passes the count gate; files are missing, so the failure must
  # be the per-item validation (ATTACH_INVALID), not the count gate.
  jq -nc '{title: "t", body: "b", grant: "write",
           attachments: [range(0; 50) | "a\(.).png"]}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
)

# --- Path validation (ATTACH_INVALID) ---------------------------------------

test_attach_invalid_extension() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment notes.txt

  jq -n '{title: "t", body: "b", attachments: ["notes.txt"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "extension" || return 1
)

test_attach_missing_file() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT

  jq -n '{title: "t", body: "b", attachments: ["nope.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "does not exist" || return 1
)

test_attach_empty_file() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  : > "$FIXTURE_DIR/work/empty.png"

  jq -n '{title: "t", body: "b", attachments: ["empty.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "empty" || return 1
)

test_attach_oversize_image() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  truncate -s 10485761 "$FIXTURE_DIR/work/big.png"

  jq -n '{title: "t", body: "b", attachments: ["big.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "10 MB" || return 1
)

test_attach_video_alt() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment clip.mp4

  jq -n '{title: "t", body: "b", attachments: ["clip.mp4#alt text"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "alt text" || return 1
)

test_attach_duplicate() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n '{title: "t", body: "b", attachments: ["shot.png", "shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "Duplicate" || return 1
)

# --- Happy paths: gh CLI split + post-write verification --------------------

test_attach_issue_create_referenced() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n --arg body "See ![the shot](./shot.png)." \
    '{title: "Bug report", body: $body, attachments: ["./shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_json_eq "$output" '.data.number' 1 || return 1
  assert_json_eq "$output" '.data.html_url' "https://github.com/u7chan/agent-harness/issues/1" || return 1
  assert_json_eq "$output" '.data.title' "Bug report" || return 1

  local stored
  stored="$(jq -r '.issues[0].body' "$MOCK_GH_STATE")"
  assert_contains "$stored" "https://attachments.example/0.png" || return 1
  case "$stored" in
    *"./shot.png"*)
      echo "  reference literal still present: $stored"
      return 1
      ;;
  esac
)

test_attach_issue_create_appended() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n --arg body "hello" \
    '{title: "t", body: $body, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  local stored
  stored="$(jq -r '.issues[0].body' "$MOCK_GH_STATE")"
  case "$stored" in
    "hello"*"https://attachments.example/0.png"*) ;;
    *)
      echo "  unexpected stored body: $stored"
      return 1
      ;;
  esac
)

test_attach_issue_create_video() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment clip.mp4

  jq -n --arg body "Walkthrough:" \
    '{title: "t", body: $body, attachments: ["clip.mp4"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  local stored
  stored="$(jq -r '.issues[0].body' "$MOCK_GH_STATE")"
  case "$stored" in
    "Walkthrough:"*"https://attachments.example/0.png"*) ;;
    *)
      echo "  unexpected stored body: $stored"
      return 1
      ;;
  esac
)

test_attach_issue_update_appended() (
  setup_attach_fixture issue.update
  trap teardown_fixture EXIT
  make_attachment shot.png
  seed_issue 1 "Old title" "Existing body"

  jq -n '{number: 1, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.update "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.title' "Old title" || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  local stored
  stored="$(jq -r '.issues[0].body' "$MOCK_GH_STATE")"
  case "$stored" in
    "Existing body"*"https://attachments.example/0.png"*) ;;
    *)
      echo "  unexpected stored body: $stored"
      return 1
      ;;
  esac
)

test_attach_pr_create_referenced() (
  setup_attach_fixture pr.create
  trap teardown_fixture EXIT
  make_attachment shot.png
  make_attachment extra.png

  jq -n --arg body "Shown ![before](./shot.png) here" \
    '{title: "PR title", body: $body, base: "main", head: "feat/gh-attach-test", attachments: ["./shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh pr.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_json_eq "$output" '.data.number' 1 || return 1
  assert_json_eq "$output" '.data.base.ref' main || return 1

  local stored
  stored="$(jq -r '.prs[0].body' "$MOCK_GH_STATE")"
  assert_contains "$stored" "https://attachments.example/0.png" || return 1
  case "$stored" in
    *"./shot.png"*)
      echo "  reference literal still present: $stored"
      return 1
      ;;
  esac
)

test_attach_pr_update_appended() (
  setup_attach_fixture pr.update
  trap teardown_fixture EXIT
  make_attachment shot.png
  seed_pr 1 "PR title" "Existing body"

  jq -n '{reference: "u7chan/agent-harness", number: 1, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh pr.update "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.title' "PR title" || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  local stored
  stored="$(jq -r '.prs[0].body' "$MOCK_GH_STATE")"
  case "$stored" in
    "Existing body"*"https://attachments.example/0.png"*) ;;
    *)
      echo "  unexpected stored body: $stored"
      return 1
      ;;
  esac
)

test_attach_comments_create_issue() (
  setup_attach_fixture comments.create
  trap teardown_fixture EXIT
  make_attachment shot.png
  seed_issue 1 "Title" "Body"

  jq -n --arg body "hello" \
    '{number: 1, body: $body, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh comments.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.id' 1 || return 1
  assert_json_eq "$output" '.target.parent.type' issue || return 1
  assert_json_eq "$output" '.target.url' "https://github.com/u7chan/agent-harness/issues/1#issuecomment-1" || return 1

  local stored
  stored="$(jq -r '.comments[0].body' "$MOCK_GH_STATE")"
  assert_contains "$stored" "https://attachments.example/0.png" || return 1
)

test_attach_comments_create_pr() (
  setup_attach_fixture comments.create
  trap teardown_fixture EXIT
  make_attachment shot.png
  seed_pr 5 "PR title" "Body"

  jq -n --arg body "hello" \
    '{number: 5, body: $body, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh comments.create "$(request_file)" 2>/dev/null)" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.id' 1 || return 1
  assert_json_eq "$output" '.target.parent.type' pull_request || return 1
  assert_json_eq "$output" '.target.url' "https://github.com/u7chan/agent-harness/pull/5#issuecomment-1" || return 1
)

# --- Verification failures (unknown_outcome) --------------------------------

test_attach_verify_no_rewrite() (
  export MOCK_ATTACH_MODE=norewrite
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n --arg body "See ![shot](./shot.png)" \
    '{title: "t", body: $body, attachments: ["./shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1
)

test_attach_verify_no_append() (
  export MOCK_ATTACH_MODE=noappend
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment shot.png

  jq -n --arg body "hello" \
    '{title: "t", body: $body, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1
)

test_attach_mixed_unknown_outcome() (
  setup_attach_fixture issue.create
  trap teardown_fixture EXIT
  make_attachment a.png
  make_attachment b.png

  # Mixing referenced and unreferenced attachments rewrites the body before
  # appending, so the exact-prefix check cannot hold; the result must be
  # unknown_outcome (safe), never a false ok.
  jq -n --arg body "A ![a](./a.png) B" \
    '{title: "t", body: $body, attachments: ["./a.png", "b.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh issue.create "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1
)

# --- Unsupported combinations ------------------------------------------------

test_attach_pr_update_maintainer_conflict() (
  setup_attach_fixture pr.update
  trap teardown_fixture EXIT
  make_attachment shot.png
  seed_pr 1 "PR title" "Existing body"

  jq -n '{reference: "u7chan/agent-harness", number: 1,
          maintainer_can_modify: false, attachments: ["shot.png"], grant: "write"}' > "$(request_file)"
  local output
  output="$(fixture_gh pr.update "$(request_file)" 2>/dev/null)" || true
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' ATTACH_INVALID || return 1
  assert_contains "$output" "maintainer_can_modify" || return 1
)

main() {
  echo "=== attach contract tests ==="

  run_test test_attach_schema_type_mismatch
  run_test test_attach_unsupported_version
  run_test test_attach_unsupported_host
  run_test test_attach_too_many
  run_test test_attach_max_count_boundary
  run_test test_attach_invalid_extension
  run_test test_attach_missing_file
  run_test test_attach_empty_file
  run_test test_attach_oversize_image
  run_test test_attach_video_alt
  run_test test_attach_duplicate
  run_test test_attach_issue_create_referenced
  run_test test_attach_issue_create_appended
  run_test test_attach_issue_create_video
  run_test test_attach_issue_update_appended
  run_test test_attach_pr_create_referenced
  run_test test_attach_pr_update_appended
  run_test test_attach_comments_create_issue
  run_test test_attach_comments_create_pr
  run_test test_attach_verify_no_rewrite
  run_test test_attach_verify_no_append
  run_test test_attach_mixed_unknown_outcome
  run_test test_attach_pr_update_maintainer_conflict

  print_summary
}

main
