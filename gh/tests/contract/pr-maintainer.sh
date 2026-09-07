#!/usr/bin/env bash
set -uo pipefail

# Contract tests for maintainer_can_modify handling in pr.create / pr.update
# (Issue #173): an explicit false must survive input extraction, the REST
# payload and the CLI --no-maintainer-edit flag, and the diff / read-back
# verification must keep false / true / null / absent separated - a value
# missing from a re-fetched PR state is never treated as false.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Stateful mock gh for the pr.create / pr.update REST flows plus the gh pr
# create CLI subcommand (attachment route). REST behavior:
#   - GET  repos/{o}/{r}/git/ref/heads/{branch}  -> ref object
#   - GET  repos/{o}/{r}/pulls?head=...          -> [] (no open PR yet)
#   - POST repos/{o}/{r}/pulls                   -> creates a PR from the
#     --input payload; maintainer_can_modify follows the payload key; when
#     the key is absent the REST create default (false) applies.
#   - GET/PATCH repos/{o}/{r}/pulls/{n}          -> read back / apply the
#     --input payload to the stored PR.
# Every api call is appended to $MOCK_GH_REQUESTS as JSON lines so tests can
# assert the exact payload that reached the API.
# MOCK_MCM_UNSETTABLE=1 simulates an API that cannot represent
# maintainer_can_modify (the stored PR keeps no such value even when a PATCH
# tries to set it), for the missing-read-back fail-closed contract.
write_pr_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import re
import sys

state_file = os.environ["MOCK_GH_STATE"]
requests_log = os.environ.get("MOCK_GH_REQUESTS", "")
mcm_unsettable = os.environ.get("MOCK_MCM_UNSETTABLE") == "1"


def load():
    with open(state_file, encoding="utf-8") as f:
        return json.load(f)


def save(state):
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def record(method, endpoint, payload):
    if requests_log:
        rec = {"method": method, "endpoint": endpoint, "payload": payload}
        with open(requests_log, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def make_pr(n, repo, title, body, base, head, draft, mcm, mcm_present):
    pr = {
        "id": n, "number": n, "title": title, "body": body,
        "state": "open", "draft": draft,
        "html_url": "https://github.com/%s/pull/%d" % (repo, n),
        "user": {"login": "u7chan"},
        "labels": [], "assignees": [], "milestone": None,
        "created_at": "2026-09-01T00:00:00Z",
        "updated_at": "2026-09-01T00:00:00Z",
        "head": {"ref": head, "sha": "a" * 40,
                 "repo": {"full_name": repo}},
        "base": {"ref": base, "sha": "b" * 40,
                 "repo": {"full_name": repo}},
    }
    if mcm_present:
        pr["maintainer_can_modify"] = mcm
    return pr


def parse_flags(args):
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
    # Mirrors gh api: -f fields of a GET become the query string built with
    # url.Values (keys sorted, values percent-encoded).
    return "&".join(
        "%s=%s" % (go_query_escape(k), go_query_escape(v))
        for k, v in sorted(fields.items())
    )


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
        print("u7chan/agent-harness")
    else:
        output({"nameWithOwner": "u7chan/agent-harness"})
    sys.exit(0)

state = load()

if args[0] == "api":
    method = "GET"
    if "--method" in args:
        method = args[args.index("--method") + 1]
    endpoint = next((a for a in args if a.startswith("repos/")), "")
    if not endpoint:
        fail("unsupported api call")
    payload = None
    if "--input" in args:
        with open(args[args.index("--input") + 1], encoding="utf-8") as f:
            payload = json.load(f)
    # A GET search now arrives as -f fields (pr.create #177): reconstruct
    # the endpoint with the query exactly as the real gh api would send it.
    search_fields = {}
    idx = 0
    while idx < len(args):
        if args[idx] in ("-f", "--field") and idx + 1 < len(args):
            key, _, value = args[idx + 1].partition("=")
            search_fields[key] = value
            idx += 2
        else:
            idx += 1
    if search_fields:
        endpoint = endpoint + "?" + build_query(search_fields)
    record(method, endpoint, payload)

    if method == "GET" and "/git/ref/heads/" in endpoint:
        output({"ref": "refs/heads/" + endpoint.rsplit("/", 1)[1],
                "object": {"sha": "a" * 40}})
        sys.exit(0)
    if method == "GET" and "pulls?" in endpoint:
        output([])
        sys.exit(0)

    m = re.search(r"/pulls/(\d+)$", endpoint)
    if endpoint.endswith("/pulls"):
        n = state["next_pr"]
        state["next_pr"] += 1
        repo = "/".join(endpoint.split("/")[1:3])
        mcm_present = not mcm_unsettable
        mcm_value = payload.get("maintainer_can_modify")
        if mcm_present:
            if "maintainer_can_modify" in payload:
                mcm_value = payload["maintainer_can_modify"]
            else:
                mcm_value = False  # REST create route default
        pr = make_pr(
            n, repo, payload.get("title", ""), payload.get("body", ""),
            payload.get("base", ""), payload.get("head", ""),
            bool(payload.get("draft", False)), mcm_value, mcm_present,
        )
        state.setdefault("prs", []).append(pr)
        save(state)
        output(pr)
        sys.exit(0)
    if m and method in ("GET", "PATCH"):
        n = int(m.group(1))
        pr = next((p for p in state.get("prs", []) if p["number"] == n), None)
        if pr is None:
            fail("pr not found")
        if method == "PATCH":
            if "title" in payload:
                pr["title"] = payload["title"]
            if "body" in payload:
                pr["body"] = payload["body"]
            if "base" in payload:
                pr["base"]["ref"] = payload["base"]
            if "maintainer_can_modify" in payload and not mcm_unsettable:
                pr["maintainer_can_modify"] = payload["maintainer_can_modify"]
            save(state)
        output(pr)
        sys.exit(0)
    fail("unsupported endpoint: " + endpoint)

if args[0] == "pr" and args[1] == "create":
    flags = parse_flags(args[2:])
    repo = one(flags, "--repo")
    title = one(flags, "--title")
    base = one(flags, "--base")
    head = one(flags, "--head")
    body_file = one(flags, "--body-file")
    with open(body_file, encoding="utf-8") as f:
        body = f.read()
    # Unreferenced attachments are appended to the stored body (the real gh
    # CLI does this; the post-write verification relies on it).
    attaches = flags.get("--attach", [])
    idx = 0
    for item in attaches:
        path = item.split("#", 1)[0]
        name = os.path.basename(path)
        if body:
            body += "\n\n"
        body += "![%s](https://attachments.example/%d.png)" % (name, idx)
        idx += 1
    n = state["next_pr"]
    state["next_pr"] += 1
    no_maintainer_edit = "--no-maintainer-edit" in flags
    pr = make_pr(
        n, repo, title, body, base, head,
        "--draft" in flags, not no_maintainer_edit, True,
    )
    state.setdefault("prs", []).append(pr)
    save(state)
    print(pr["html_url"])
    sys.exit(0)

fail("unsupported mock command: " + " ".join(args))
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# setup_pr_fixture <action-name>
# Fixture with the stateful mock on PATH and a fresh empty state + request log.
setup_pr_fixture() {
  local action_name="$1"

  setup_fixture
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_REQUESTS="$FIXTURE_DIR/requests.log"
  : > "$MOCK_GH_REQUESTS"
  jq -n '{prs: [], next_pr: 1}' > "$MOCK_GH_STATE"
  cp "$GH_ROOT/scripts/actions/$action_name.sh" \
    "$FIXTURE_DIR/scripts/actions/$action_name.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/$action_name.sh"
  write_pr_mock_gh
}

seed_pr_mcm() {
  local n="$1"
  local title="$2"
  local body="$3"
  local mcm="$4"  # true | false

  jq -n \
    --argjson n "$n" --arg title "$title" --arg body "$body" --argjson mcm "$mcm" \
    '{prs: [{id: $n, number: $n, title: $title, body: $body, state: "open",
            draft: false,
            html_url: ("https://github.com/u7chan/agent-harness/pull/" + ($n|tostring)),
            user: {login: "u7chan"}, labels: [], assignees: [], milestone: null,
            maintainer_can_modify: $mcm,
            created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
            head: {ref: "feat/x", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: "u7chan/agent-harness"}},
            base: {ref: "main", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", repo: {full_name: "u7chan/agent-harness"}}}],
      next_pr: ($n + 1)}' > "$MOCK_GH_STATE"
}

# A PR whose re-fetched state carries no maintainer_can_modify at all
# (same-repository PRs cannot represent the flag).
seed_pr_without_mcm() {
  local n="$1"
  local title="$2"
  local body="$3"

  jq -n \
    --argjson n "$n" --arg title "$title" --arg body "$body" \
    '{prs: [{id: $n, number: $n, title: $title, body: $body, state: "open",
            draft: false,
            html_url: ("https://github.com/u7chan/agent-harness/pull/" + ($n|tostring)),
            user: {login: "u7chan"}, labels: [], assignees: [], milestone: null,
            created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
            head: {ref: "feat/x", sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", repo: {full_name: "u7chan/agent-harness"}},
            base: {ref: "main", sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", repo: {full_name: "u7chan/agent-harness"}}}],
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

run_pr_update() {
  local payload="$1"
  printf '%s\n' "$payload" > "$(request_file)"
  fixture_gh pr.update "$(request_file)"
}

# --- pr.create REST route payload -------------------------------------------

# The payload that reached the API must carry the explicit false (Issue #173:
# jq's // null swallowed it and the key was dropped).
test_create_rest_mcm_false() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "base": "main", "head": "feat/x", "maintainer_can_modify": false, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "POST" and (.endpoint | endswith("/pulls")))) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" 'has("maintainer_can_modify") | tostring' true || return 1
  assert_json_eq "$payload" '.maintainer_can_modify | tostring' false || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' false || return 1
)

test_create_rest_mcm_true() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "base": "main", "head": "feat/x", "maintainer_can_modify": true, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "POST" and (.endpoint | endswith("/pulls")))) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" 'has("maintainer_can_modify") | tostring' true || return 1
  assert_json_eq "$payload" '.maintainer_can_modify | tostring' true || return 1
)

# Absent means "use the route default": the key must not reach the payload.
test_create_rest_mcm_absent_omitted() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "base": "main", "head": "feat/x", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "POST" and (.endpoint | endswith("/pulls")))) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" 'has("maintainer_can_modify") | tostring' false || return 1
)

# Explicit null on create is separated from false/true: like absent, it falls
# back to the route default and never sends maintainer_can_modify: false.
test_create_rest_mcm_null_omitted() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT

  local output
  output="$(run_pr_create '{"title": "PR title", "base": "main", "head": "feat/x", "maintainer_can_modify": null, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "POST" and (.endpoint | endswith("/pulls")))) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" 'has("maintainer_can_modify") | tostring' false || return 1
)

# --- pr.create attachment (CLI) route --------------------------------------

# The CLI route must translate explicit false into --no-maintainer-edit; the
# created PR then reports maintainer_can_modify false (gh pr create's default
# would be true).
test_create_cli_mcm_false_flag() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT
  mkdir -p "$FIXTURE_DIR/work"
  printf 'attachment-shot' > "$FIXTURE_DIR/work/shot.png"
  cd "$FIXTURE_DIR/work" || return 1

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "", "base": "main", "head": "feat/x", "maintainer_can_modify": false, "attachments": ["shot.png"], "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.target.number' 1 || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' false || return 1
)

test_create_cli_mcm_true_no_flag() (
  setup_pr_fixture pr.create
  trap teardown_fixture EXIT
  mkdir -p "$FIXTURE_DIR/work"
  printf 'attachment-shot' > "$FIXTURE_DIR/work/shot.png"
  cd "$FIXTURE_DIR/work" || return 1

  local output
  output="$(run_pr_create '{"title": "PR title", "body": "", "base": "main", "head": "feat/x", "maintainer_can_modify": true, "attachments": ["shot.png"], "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' true || return 1
)

# --- pr.update transitions --------------------------------------------------

test_update_mcm_true_to_false() (
  setup_pr_fixture pr.update
  trap teardown_fixture EXIT
  seed_pr_mcm 1 "PR title" "Body" true

  local output
  output="$(run_pr_update '{"reference": "u7chan/agent-harness", "number": 1, "maintainer_can_modify": false, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.title' "PR title" || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "PATCH")) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" '.maintainer_can_modify | tostring' false || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' false || return 1
)

test_update_mcm_false_to_true() (
  setup_pr_fixture pr.update
  trap teardown_fixture EXIT
  seed_pr_mcm 1 "PR title" "Body" false

  local output
  output="$(run_pr_update '{"reference": "u7chan/agent-harness", "number": 1, "maintainer_can_modify": true, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "PATCH")) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" '.maintainer_can_modify | tostring' true || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' true || return 1
)

test_update_mcm_false_to_false_already_applied() (
  setup_pr_fixture pr.update
  trap teardown_fixture EXIT
  seed_pr_mcm 1 "PR title" "Body" false

  local output
  output="$(run_pr_update '{"reference": "u7chan/agent-harness", "number": 1, "maintainer_can_modify": false, "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' already_applied || return 1

  local patch_count
  patch_count="$(jq -s 'map(select(.method == "PATCH")) | length' "$MOCK_GH_REQUESTS")"
  assert_eq "$patch_count" "0" || return 1
)

# Absent keeps the current value: a PATCH that changes another field must not
# carry maintainer_can_modify at all.
test_update_mcm_absent_keeps_current_false() (
  setup_pr_fixture pr.update
  trap teardown_fixture EXIT
  seed_pr_mcm 1 "PR title" "Body" false

  local output
  output="$(run_pr_update '{"reference": "u7chan/agent-harness", "number": 1, "title": "New title", "grant": "write"}')" || return 1
  assert_json_eq "$output" '.status' ok || return 1
  assert_json_eq "$output" '.data.title' "New title" || return 1

  local payload
  payload="$(jq -s -c 'map(select(.method == "PATCH")) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" 'has("maintainer_can_modify") | tostring' false || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.prs[0].maintainer_can_modify | tostring' false || return 1
)

# A maintainer_can_modify value missing from the re-fetched state must never
# be treated as the requested false: the update result is unknown, not ok.
test_update_readback_missing_mcm_unknown() (
  export MOCK_MCM_UNSETTABLE=1
  setup_pr_fixture pr.update
  trap teardown_fixture EXIT
  seed_pr_without_mcm 1 "PR title" "Body"

  local output
  output="$(run_pr_update '{"reference": "u7chan/agent-harness", "number": 1, "maintainer_can_modify": false, "grant": "write"}')" || true
  assert_json_eq "$output" '.status' unknown_outcome || return 1

  # The request still went out with the explicit false (no silent dropping).
  local payload
  payload="$(jq -s -c 'map(select(.method == "PATCH")) | last | .payload' "$MOCK_GH_REQUESTS")"
  assert_json_eq "$payload" '.maintainer_can_modify | tostring' false || return 1
)

main() {
  echo "=== pr maintainer_can_modify contract tests ==="

  run_test test_create_rest_mcm_false
  run_test test_create_rest_mcm_true
  run_test test_create_rest_mcm_absent_omitted
  run_test test_create_rest_mcm_null_omitted
  run_test test_create_cli_mcm_false_flag
  run_test test_create_cli_mcm_true_no_flag
  run_test test_update_mcm_true_to_false
  run_test test_update_mcm_false_to_true
  run_test test_update_mcm_false_to_false_already_applied
  run_test test_update_mcm_absent_keeps_current_false
  run_test test_update_readback_missing_mcm_unknown

  print_summary
}

main
