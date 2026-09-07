#!/usr/bin/env bash
set -uo pipefail

# Contract tests for the pre-create existing-PR search in pr.create (Issue
# #177). The search GET that guards against duplicate PRs must fail closed:
# a failed or non-array response means "unknown", never "no existing PR",
# so no POST / CLI create may run after a broken check. The head/base
# search values must also reach the query the way `gh api -f` sends them
# (percent-encoded), because branch names may contain +, & and #, which
# corrupt a hand-built pulls?head=...&base=... query.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Stateful mock gh for the pr.create REST and CLI (attachment) flows. It
# emulates how `gh api` builds a GET query from -f fields (Go url.Values:
# sorted keys, RFC 3986 percent-encoding, space as '+') and then parses the
# request target the way the GitHub server would (fragment stripped, query
# decoded) so the search answer and the recorded params match what a real
# request would deliver:
#   - MOCK_SEARCH_MODE=ok (default): answer the open PRs whose head
#     (owner:branch or branch), base and state=open match the decoded query
#   - MOCK_SEARCH_MODE=fail: fail the search GET (non-retryable 404)
#   - MOCK_SEARCH_MODE=invalid: answer a non-array JSON object
# Every api call and every CLI `pr create` is appended to $MOCK_GH_REQUESTS
# as JSON lines: {method, endpoint (request target incl. encoded query),
# params (server-decoded query), payload}.
write_search_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys
from urllib.parse import parse_qsl, urlsplit

state_file = os.environ["MOCK_GH_STATE"]
requests_log = os.environ.get("MOCK_GH_REQUESTS", "")
search_mode = os.environ.get("MOCK_SEARCH_MODE", "ok")
owner_repo = "u7chan/agent-harness"


def load():
    with open(state_file, encoding="utf-8") as f:
        return json.load(f)


def save(state):
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def record(rec):
    if requests_log:
        with open(requests_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def go_query_escape(s):
    # gh api GET query values use Go url.QueryEscape: RFC 3986 unreserved
    # characters stay literal, space becomes '+', everything else is
    # percent-encoded with uppercase hex.
    out = []
    for b in s.encode("utf-8"):
        if 48 <= b <= 57 or 65 <= b <= 90 or 97 <= b <= 122 or b in (45, 46, 95, 126):
            out.append(chr(b))
        elif b == 32:
            out.append("+")
        else:
            out.append("%%%02X" % b)
    return "".join(out)


def build_query(fields):
    return "&".join(
        "%s=%s" % (go_query_escape(k), go_query_escape(v))
        for k, v in sorted(fields.items())
    )


def make_pr(n, repo, title, body, base, head, draft=False):
    return {
        "id": n, "number": n, "title": title, "body": body,
        "state": "open", "draft": draft,
        "html_url": "https://github.com/%s/pull/%d" % (repo, n),
        "user": {"login": "u7chan"},
        "labels": [], "assignees": [], "milestone": None,
        "created_at": "2026-09-01T00:00:00Z",
        "updated_at": "2026-09-01T00:00:00Z",
        "head": {"ref": head, "sha": "a" * 40, "repo": {"full_name": repo}},
        "base": {"ref": base, "sha": "b" * 40, "repo": {"full_name": repo}},
    }


def parse_api_args(args):
    # args are the tokens after the leading "api".
    method = "GET"
    endpoint = ""
    fields = {}
    payload = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--method" and i + 1 < len(args):
            method = args[i + 1]
            i += 2
        elif a in ("-f", "--field") and i + 1 < len(args):
            key, _, value = args[i + 1].partition("=")
            fields[key] = value
            i += 2
        elif a == "--input" and i + 1 < len(args):
            with open(args[i + 1], encoding="utf-8") as f:
                payload = json.load(f)
            i += 2
        elif a == "-H" and i + 1 < len(args):
            i += 2
        elif a.startswith("repos/"):
            endpoint = a
            i += 1
        else:
            i += 1
    return method, endpoint, fields, payload


def parse_cli_flags(args):
    flags = {}
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
            i += 1
    return flags


def one(flags, name, default=""):
    vals = flags.get(name, [])
    return vals[0] if vals else default


args = sys.argv[1:]
if not args:
    fail("unsupported mock command")

if args[0] == "--version":
    print("gh version 2.99.0 (mock)")
    sys.exit(0)

if args[0] == "repo" and args[1] == "view":
    if "--jq" in args:
        print(owner_repo)
    else:
        output({"nameWithOwner": owner_repo})
    sys.exit(0)

state = load()

if args[0] == "api":
    method, endpoint, fields, payload = parse_api_args(args[1:])
    target = endpoint
    if fields:
        target = endpoint + "?" + build_query(fields)
    # The server-side view of the request target: the fragment is never
    # sent and the query is decoded (+ as space, %XX as bytes).
    parts = urlsplit(target)
    params = {}
    if parts.query:
        params = dict(parse_qsl(parts.query, keep_blank_values=True))
    record({"method": method, "endpoint": target, "params": params, "payload": payload})

    if method == "GET" and "/git/ref/heads/" in endpoint:
        output({"ref": "refs/heads/" + endpoint.rsplit("/", 1)[1],
                "object": {"sha": "a" * 40}})
        sys.exit(0)

    path = parts.path
    if method == "GET" and path.endswith("/pulls"):
        if search_mode == "fail":
            fail("gh: Not Found (HTTP 404)")
        if search_mode == "invalid":
            output({"message": "mock non-array search response"})
            sys.exit(0)
        head = params.get("head")
        branch = head.split(":", 1)[1] if head and ":" in head else head
        base = params.get("base")
        matches = []
        if params.get("state") == "open" and branch is not None and base is not None:
            matches = [
                p for p in state.get("prs", [])
                if p["head"]["ref"] == branch and p["base"]["ref"] == base
                and p["state"] == "open"
            ]
        output(matches)
        sys.exit(0)
    if path.endswith("/pulls"):
        n = state["next_pr"]
        state["next_pr"] += 1
        repo = "/".join(path.split("/")[1:3])
        pr = make_pr(
            n, repo, payload.get("title", ""), payload.get("body", ""),
            payload.get("base", ""), payload.get("head", ""),
            bool(payload.get("draft", False)),
        )
        state.setdefault("prs", []).append(pr)
        save(state)
        output(pr)
        sys.exit(0)
    m = re.search(r"/pulls/(\d+)$", path)
    if m:
        n = int(m.group(1))
        for p in state.get("prs", []):
            if p["number"] == n:
                output(p)
                sys.exit(0)
        fail("pr not found")
    fail("unsupported endpoint: " + endpoint)

if args[0] == "pr" and args[1] == "create":
    flags = parse_cli_flags(args[2:])
    record({"method": "cli-pr-create"})
    repo = one(flags, "--repo")
    title = one(flags, "--title")
    base = one(flags, "--base")
    head = one(flags, "--head")
    body_file = one(flags, "--body-file")
    with open(body_file, encoding="utf-8") as f:
        body = f.read()
    # Unreferenced attachments are appended to the stored body (the real gh
    # CLI does this; pr.create's post-write verification relies on it).
    idx = 0
    for item in flags.get("--attach", []):
        name = os.path.basename(item.split("#", 1)[0])
        if body:
            body += "\n\n"
        body += "![%s](https://attachments.example/%d.png)" % (name, idx)
        idx += 1
    n = state["next_pr"]
    state["next_pr"] += 1
    pr = make_pr(n, repo, title, body, base, head, "--draft" in flags)
    state.setdefault("prs", []).append(pr)
    save(state)
    print(pr["html_url"])
    sys.exit(0)

fail("unsupported mock command: " + " ".join(args))
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# Fixture with the stateful mock on PATH, a fresh empty state + request log
# and the worktree's pr.create.sh copied into the fixture dispatcher.
setup_search_fixture() {
  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_REQUESTS="$FIXTURE_DIR/requests.log"
  : > "$MOCK_GH_REQUESTS"
  jq -n '{prs: [], next_pr: 1}' > "$MOCK_GH_STATE"
  cp "$GH_ROOT/scripts/actions/pr.create.sh" \
    "$FIXTURE_DIR/scripts/actions/pr.create.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/pr.create.sh"
  write_search_mock_gh
}

# An existing open PR (same repository) whose head/base branches and PR
# shape mirror the mock's created PRs.
seed_existing_pr() {
  local n="$1"
  local head="$2"
  local base="$3"

  jq -n \
    --argjson n "$n" --arg head "$head" --arg base "$base" \
    '{prs: [{id: $n, number: $n, title: "Existing PR", body: "existing body",
            state: "open", draft: false,
            html_url: ("https://github.com/u7chan/agent-harness/pull/" + ($n|tostring)),
            user: {login: "u7chan"}, labels: [], assignees: [], milestone: null,
            created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
            head: {ref: $head, sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                   repo: {full_name: "u7chan/agent-harness"}},
            base: {ref: $base, sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                   repo: {full_name: "u7chan/agent-harness"}}}],
      next_pr: ($n + 1)}' > "$MOCK_GH_STATE"
}

request_file() {
  printf '%s\n' "$FIXTURE_DIR/request.json"
}

run_pr_create() {
  local payload="$1"
  printf '%s\n' "$payload" > "$(request_file)"
  fixture_gh pr.create "$(request_file)"
}

count_requests() {
  jq -s "[.[] | select($1)] | length" "$MOCK_GH_REQUESTS" 2>/dev/null || echo 0
}

first_search_endpoint() {
  jq -s -c '[.[] | select(.method == "GET" and (.endpoint | startswith("repos/u7chan/agent-harness/pulls?")))] | first | .endpoint' "$MOCK_GH_REQUESTS" 2>/dev/null
}

first_search_params() {
  jq -s -c '[.[] | select(.method == "GET" and (.endpoint | startswith("repos/u7chan/agent-harness/pulls?")))] | first | .params' "$MOCK_GH_REQUESTS" 2>/dev/null
}

# --- fail-closed search (Issue #177) --------------------------------------

# A failing existing-PR search must stop before any create: failed envelope,
# zero POSTs. The old code masked the failure with || existing="[]" and
# created the duplicate PR.
test_create_search_fail_fails_closed() (
  setup_search_fixture
  trap teardown_fixture EXIT
  export MOCK_SEARCH_MODE=fail

  local output rc
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "main", "head": "feat/x", "grant": "write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "0" || return 1
  # One search attempt: the 404-style failure is not retryable, so the
  # mock must not be polled again (no retry sleeps in tests).
  assert_eq "$(count_requests '.method == "GET" and (.endpoint | startswith("repos/u7chan/agent-harness/pulls?"))')" "1" || return 1
)

# A non-array (invalid) search response must fail the same way: the old code
# ran jq 'length' / '.[0]' on it and aborted under set -e without an
# envelope (or, for {}-shaped bodies, treated it as "no existing PR").
test_create_search_invalid_fails_closed() (
  setup_search_fixture
  trap teardown_fixture EXIT
  export MOCK_SEARCH_MODE=invalid

  local output rc
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "main", "head": "feat/x", "grant": "write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "0" || return 1
)

# --- existing / none coverage ---------------------------------------------

# An existing open PR is reported already_applied with no POST at all
# (regression guard for the already_applied contract).
test_create_search_existing_already_applied() (
  setup_search_fixture
  trap teardown_fixture EXIT
  seed_existing_pr 1 "feat/x" "main"

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "main", "head": "feat/x", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_json_eq "$output" '.data.number' 1 || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "0" || return 1
)

# No existing PR keeps the normal create flow working.
test_create_search_none_creates() (
  setup_search_fixture
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "main", "head": "feat/x", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "1" || return 1
)

# --- query encoding --------------------------------------------------------

# A head branch containing + & # must reach the search query percent-encoded
# (gh api -f semantics) so the existing PR is found. The old inline
# string concatenation let +, & and # corrupt the query (head=...&base=...
# &state=open), the search came back empty and a duplicate PR was created.
test_create_search_special_encoded_already_applied() (
  setup_search_fixture
  trap teardown_fixture EXIT
  seed_existing_pr 1 "feat/ci+check#1&more" "main"

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "main", "head": "feat/ci+check#1&more", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "0" || return 1

  # The recorded search target carries the gh CLI-equivalent encoding:
  # sorted keys, values percent-encoded (%3A for ':', %2F for '/', %2B for
  # '+', %23 for '#', %26 for '&').
  assert_eq "$(first_search_endpoint)" '"repos/u7chan/agent-harness/pulls?base=main&head=u7chan%3Afeat%2Fci%2Bcheck%231%26more&state=open"' || return 1
  assert_eq "$(first_search_params)" '{"base":"main","head":"u7chan:feat/ci+check#1&more","state":"open"}' || return 1
)

# Wire-format guard for head and base with no existing PR: the decoded
# params must arrive intact even though nothing matches, and the create
# still succeeds. The old head sent head=...a+b and base=c#d&e raw, which
# decode to different values ('+' as space, '#' fragment cut, '&' splitting
# the parameter list).
test_create_search_special_wire_format() (
  setup_search_fixture
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "Body", "base": "c#d&e", "head": "feat/a+b", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  assert_eq "$(first_search_endpoint)" '"repos/u7chan/agent-harness/pulls?base=c%23d%26e&head=u7chan%3Afeat%2Fa%2Bb&state=open"' || return 1
  assert_eq "$(first_search_params)" '{"base":"c#d&e","head":"u7chan:feat/a+b","state":"open"}' || return 1
  assert_eq "$(count_requests '.method == "POST" and (.endpoint | endswith("/pulls"))')" "1" || return 1
  # The created PR stores the branch names verbatim (payload, not URL).
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].head.ref' 'feat/a+b' || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].base.ref' 'c#d&e' || return 1
)

# --- CLI (attachment) route ------------------------------------------------

# The attachment route must also fail closed: a failing search means the gh
# pr create CLI is never invoked.
test_create_cli_search_fail_fails_closed() (
  setup_search_fixture
  trap teardown_fixture EXIT
  export MOCK_SEARCH_MODE=fail
  mkdir -p "$FIXTURE_DIR/work"
  printf 'attachment-shot' > "$FIXTURE_DIR/work/shot.png"
  cd "$FIXTURE_DIR/work" || return 1

  local output rc
  output="$(run_pr_create '{"title": "PR title", "body": "", "base": "main", "head": "feat/x", "attachments": ["shot.png"], "grant": "write"}')"
  rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' failed || return 1
  assert_json_eq "$output" '.error.code' API_ERROR || return 1
  assert_eq "$(count_requests '.method == "cli-pr-create"')" "0" || return 1
)

# On the attachment route the encoded search still finds the existing PR and
# reports already_applied without invoking the gh pr create CLI.
test_create_cli_search_existing_special_already_applied() (
  setup_search_fixture
  trap teardown_fixture EXIT
  seed_existing_pr 1 "feat/ci+check#1&more" "main"
  mkdir -p "$FIXTURE_DIR/work"
  printf 'attachment-shot' > "$FIXTURE_DIR/work/shot.png"
  cd "$FIXTURE_DIR/work" || return 1

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "", "base": "main", "head": "feat/ci+check#1&more", "attachments": ["shot.png"], "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_eq "$(count_requests '.method == "cli-pr-create"')" "0" || return 1
)

main() {
  echo "=== pr existing-PR search contract tests ==="

  run_test test_create_search_fail_fails_closed
  run_test test_create_search_invalid_fails_closed
  run_test test_create_search_existing_already_applied
  run_test test_create_search_none_creates
  run_test test_create_search_special_encoded_already_applied
  run_test test_create_search_special_wire_format
  run_test test_create_cli_search_fail_fails_closed
  run_test test_create_cli_search_existing_special_already_applied

  print_summary
}

main
