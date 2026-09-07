#!/usr/bin/env bash
set -uo pipefail

# Contract tests for the labels.remove DELETE endpoint (Issue #175): the
# label name is a path element of
#   repos/{owner}/{repo}/issues/{number}/labels/{name}
# and must be percent-encoded so the API receives exactly one path element
# (kind/bug -> kind%2Fbug, "bug report" -> bug%20report, Japanese, %, # and
# ? names included). Plain names and the already-absent (already_applied)
# path keep their previous behavior. Fully offline: the mock gh serves the
# issue reads from a state file, applies the DELETE only when the endpoint
# carries a single correctly encoded path element, and logs every call.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Stateful mock gh for the labels.remove REST flow:
#   - GET    repos/u7chan/agent-harness/issues/1      -> the issue state
#   - DELETE repos/u7chan/agent-harness/issues/1/labels/{name}
#     only when {name} is a single percent-encoded path element naming a
#     label on the issue; removes it and persists the state so the action's
#     post-write re-fetch observes the removal. Anything else (raw slash,
#     raw space, raw %, raw #/?, unknown label) fails like the real API.
# Every invocation is logged to $MOCK_GH_CALLS.
write_labels_remove_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from urllib.parse import quote, unquote

state_file = os.environ["MOCK_GH_STATE"]
calls_file = os.environ.get("MOCK_GH_CALLS", "")


def output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


args = sys.argv[1:]
if not args:
    fail("unsupported mock command")

if args[0] == "repo" and args[1] == "view":
    if "--jq" in args:
        print("u7chan/agent-harness")
    else:
        output({"nameWithOwner": "u7chan/agent-harness"})
    sys.exit(0)

if args[0] != "api":
    fail("unsupported mock command")

with open(state_file, encoding="utf-8") as f:
    state = json.load(f)

method = "GET"
endpoint = ""
i = 1
while i < len(args):
    arg = args[i]
    if arg == "--method":
        method = args[i + 1]
        i += 2
    elif arg in ("-H", "-f", "-F"):
        i += 2
    elif arg.startswith("repos/"):
        endpoint = arg
        i += 1
    else:
        i += 1

if calls_file:
    with open(calls_file, "a", encoding="utf-8") as f:
        f.write(method + " " + endpoint + "\n")

issue_endpoint = "repos/u7chan/agent-harness/issues/1"
labels_prefix = issue_endpoint + "/labels/"

if method == "GET" and endpoint == issue_endpoint:
    output(state["issue"])
    sys.exit(0)

if method == "DELETE" and endpoint.startswith(labels_prefix):
    # Strict server view of the path: the segment must be canonical
    # percent-encoding of the label name. A raw slash, space, % or reserved
    # character means the caller interpolated the name unencoded and the
    # label cannot be found at that endpoint.
    segment = endpoint[len(labels_prefix):]
    if "/" in segment or quote(unquote(segment), safe="") != segment:
        fail("HTTP 404: label not found at this endpoint")
    name = unquote(segment)
    if not any(label["name"] == name for label in state["issue"]["labels"]):
        fail("HTTP 404: label not found on the issue")
    state["issue"]["labels"] = [
        label for label in state["issue"]["labels"] if label["name"] != name
    ]
    with open(state_file, "w", encoding="utf-8") as f:
        json.dump(state, f)
    sys.exit(0)

fail("unsupported endpoint: " + method + " " + endpoint)
PY
  chmod +x "$FIXTURE_DIR/bin/gh"
}

# Copies the real action under test into the fixture and wires the mock gh
# CLI, the issue state file and the invocation log.
setup_labels_remove_fixture() {
  setup_fixture
  cp "$GH_ROOT/scripts/actions/labels.remove.sh" \
    "$FIXTURE_DIR/scripts/actions/labels.remove.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/labels.remove.sh"
  write_labels_remove_mock_gh

  export PATH="$FIXTURE_DIR/bin:$PATH"
  export GH_TEST_AUTH_RESULT=0
  export MOCK_GH_STATE="$FIXTURE_DIR/state.json"
  export MOCK_GH_CALLS="$FIXTURE_DIR/calls.log"
  : > "$MOCK_GH_CALLS"
}

# seed_issue_with_label <name>: the issue carries a single label named $name.
seed_issue_with_label() {
  local name="$1"
  jq -n --arg name "$name" '{
    issue: {
      id: 1, number: 1, title: "labels.remove fixture issue",
      state: "open",
      html_url: "https://github.com/u7chan/agent-harness/issues/1",
      user: {login: "u7chan"},
      labels: [{id: 1, name: $name, color: "ededed", default: false, description: null}],
      assignees: [], milestone: null,
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z"
    }
  }' > "$MOCK_GH_STATE"
}

# seed_issue_without_label <name>: the issue carries no label at all.
seed_issue_without_label() {
  jq -n '{
    issue: {
      id: 1, number: 1, title: "labels.remove fixture issue",
      state: "open",
      html_url: "https://github.com/u7chan/agent-harness/issues/1",
      user: {login: "u7chan"},
      labels: [], assignees: [], milestone: null,
      created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z"
    }
  }' > "$MOCK_GH_STATE"
}

run_remove() {
  local name="$1"
  local input_file
  local rc

  input_file="$(mktemp /tmp/gh-labels-remove-input-XXXXXX)"
  jq -n --arg name "$name" \
    '{number: 1, name: $name, grant: "sensitive-write"}' > "$input_file"
  fixture_gh labels.remove "$input_file" 2>&1
  rc=$?
  rm -f "$input_file"
  return "$rc"
}

issue_get_count() {
  grep -c '^GET repos/u7chan/agent-harness/issues/1$' "$MOCK_GH_CALLS" 2>/dev/null || true
}

delete_count() {
  grep -c '^DELETE ' "$MOCK_GH_CALLS" 2>/dev/null || true
}

# run_remove_case <name> <expected-encoded-suffix>: remove the label $name
# and pin the DELETE endpoint to .../labels/$expected-encoded-suffix as one
# path element, with the removal confirmed by the post-write re-fetch.
run_remove_case() {
  local name="$1"
  local expected_suffix="$2"
  local expected_line="DELETE repos/u7chan/agent-harness/issues/1/labels/$expected_suffix"
  local output rc

  seed_issue_with_label "$name"
  : > "$MOCK_GH_CALLS"

  output="$(run_remove "$name")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "case name='$name': expected exit 0, got $rc"
    echo "$output"
    return 1
  fi

  assert_json_eq "$output" '.status' "ok" || return 1
  assert_json_eq "$output" '.data.labels | length' "0" || return 1
  # The DELETE endpoint carries the label as one encoded path element.
  assert_eq "$(grep -cF "$expected_line" "$MOCK_GH_CALLS" || true)" "1" \
    || { echo "DELETE endpoint not exactly '$expected_line':"; cat "$MOCK_GH_CALLS"; return 1; }
  assert_eq "$(delete_count)" "1" || return 1
  # Before-read + post-write re-fetch, and the stored issue no longer has
  # the label (the re-fetch verified the removal server-side).
  assert_eq "$(issue_get_count)" "2" || return 1
  assert_json_eq "$(cat "$MOCK_GH_STATE")" '.issue.labels | length' "0" || return 1
}

# run_already_absent_case <name>: a label that is not on the issue stays
# already_applied with a single read and no DELETE.
run_already_absent_case() {
  local name="$1"
  local output rc

  seed_issue_without_label
  : > "$MOCK_GH_CALLS"

  output="$(run_remove "$name")"
  rc=$?
  assert_eq "$rc" "0" || return 1
  assert_json_eq "$output" '.status' "already_applied" || return 1
  assert_json_eq "$output" '.data.labels | length' "0" || return 1
  assert_eq "$(issue_get_count)" "1" || return 1
  assert_eq "$(delete_count)" "0" || return 1
}

# Plain names keep their previous behavior (no encoding applied).
test_remove_plain_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "bug" "bug"
)

# Issue #175: a "/" inside the name must not split the path element.
test_remove_slash_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "kind/bug" "kind%2Fbug"
)

# Issue #175: a space inside the name must be encoded.
test_remove_space_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "bug report" "bug%20report"
)

# Issue #175: a Japanese name must be encoded as UTF-8 percent-encoding.
test_remove_japanese_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "日本語ラベル" "%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%83%A9%E3%83%99%E3%83%AB"
)

# Issue #175: a literal % must itself be encoded.
test_remove_percent_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "50%off" "50%25off"
)

# Issue #175: # and ? are fragment/query markers and must be encoded.
test_remove_hash_question_name_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_remove_case "urgent#1?" "urgent%231%3F"
)

# An already removed plain label keeps the already_applied result.
test_remove_already_absent_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_already_absent_case "bug"
)

# An already removed name with special characters behaves the same: the
# absence check runs on the raw name and never reaches the API.
test_remove_special_name_already_absent_ok() (
  setup_labels_remove_fixture
  trap teardown_fixture EXIT
  run_already_absent_case "kind/bug"
)

main() {
  echo "=== labels.remove contract tests ==="

  run_test test_remove_plain_name_ok
  run_test test_remove_slash_name_ok
  run_test test_remove_space_name_ok
  run_test test_remove_japanese_name_ok
  run_test test_remove_percent_name_ok
  run_test test_remove_hash_question_name_ok
  run_test test_remove_already_absent_ok
  run_test test_remove_special_name_already_absent_ok

  print_summary
}

main
