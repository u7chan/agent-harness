#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_SCRIPT="$HERDR_DIR/scripts/parent-delegate-async.sh"
CHILD_SCRIPT="$HERDR_DIR/scripts/child-return-result.sh"
START_SCRIPT="$HERDR_DIR/scripts/worktree-team-start.sh"
GRANT_SCRIPT="$HERDR_DIR/scripts/scope-grant.sh"
TEST_TMP="$(mktemp -d /tmp/herdr-async-test-XXXXXX)"
TEST_TMP="$(cd "$TEST_TMP" && pwd -P)"
MOCK_BIN="$TEST_TMP/bin"
MOCK_LOG="$TEST_TMP/log"
mkdir -p "$MOCK_BIN" "$MOCK_LOG"
trap 'rm -rf "$TEST_TMP"' EXIT

# Repository fixtures behind the fake `herdr workspace list`. wG is the parent
# checkout of repo-alpha, wB and wC are its linked worktrees, wD is a second
# checkout of repo-alpha, wE is a different repository, and wF has no worktree
# information at all.
REPO_ALPHA="$TEST_TMP/repo-alpha"
REPO_BETA="$TEST_TMP/repo-beta"
WORKTREE_B="$TEST_TMP/worktrees/feat-b"
WORKTREE_C="$TEST_TMP/worktrees/feat-c"
ALPHA_COPY="$TEST_TMP/repo-alpha-copy"
mkdir -p "$REPO_ALPHA" "$REPO_BETA" "$WORKTREE_B" "$WORKTREE_C" "$ALPHA_COPY"

cat > "$TEST_TMP/workspaces.json" <<EOF
{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
{"workspace_id":"wG","label":"repo-alpha","worktree":{"checkout_path":"$REPO_ALPHA","is_linked_worktree":false,"repo_key":"$REPO_ALPHA/.git","repo_name":"repo-alpha","repo_root":"$REPO_ALPHA"}},
{"workspace_id":"wB","label":"feat-b","worktree":{"checkout_path":"$WORKTREE_B","is_linked_worktree":true,"repo_key":"$REPO_ALPHA/.git","repo_name":"repo-alpha","repo_root":"$REPO_ALPHA"}},
{"workspace_id":"wC","label":"feat-c","worktree":{"checkout_path":"$WORKTREE_C","is_linked_worktree":true,"repo_key":"$REPO_ALPHA/.git","repo_name":"repo-alpha","repo_root":"$REPO_ALPHA"}},
{"workspace_id":"wD","label":"repo-alpha-copy","worktree":{"checkout_path":"$ALPHA_COPY","is_linked_worktree":false,"repo_key":"$ALPHA_COPY/.git","repo_name":"repo-alpha","repo_root":"$REPO_ALPHA"}},
{"workspace_id":"wE","label":"repo-beta","worktree":{"checkout_path":"$REPO_BETA","is_linked_worktree":false,"repo_key":"$REPO_BETA/.git","repo_name":"repo-beta","repo_root":"$REPO_BETA"}},
{"workspace_id":"wF","label":"plain-workspace"}
]}}
EOF

cat > "$MOCK_BIN/herdr" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s %s\n' "${1:-}" "${2:-}" "${3:-}" >> "$HERDR_TEST_CALLS"
case "${1:-}" in
  pane)
    case "${2:-}" in
      get)
        [ "${3:-}" = "$HERDR_PANE_ID" ] || exit 95
        cat "$HERDR_TEST_PANE_JSON"
        ;;
      rename)
        printf '%s %s\n' "${3:-}" "${4:-}" >> "$HERDR_TEST_RENAMES"
        exit "${HERDR_TEST_RENAME_RC:-0}"
        ;;
      *) exit 94 ;;
    esac
    ;;
  agent)
    case "${2:-}" in
      start)
        printf '%s\n' "$*" >> "$HERDR_TEST_STARTS"
        exit "${HERDR_TEST_START_RC:-0}"
        ;;
      wait)
        printf '%s\n' "$*" >> "$HERDR_TEST_WAITS"
        exit "${HERDR_TEST_WAIT_RC:-0}"
        ;;
      prompt)
        shift 2
        [ "$#" -eq 2 ] || exit 91
        printf '%s' "$1" > "$HERDR_TEST_TARGET"
        printf '%s' "$2" > "$HERDR_TEST_MESSAGE"
        for arg in "$@"; do [ "$arg" = --wait ] && exit 92; done
        exit "${HERDR_TEST_RC:-0}"
        ;;
      *) exit 96 ;;
    esac
    ;;
  workspace)
    [ "${2:-}" = list ] || exit 93
    [ -f "$HERDR_TEST_WORKSPACES" ] || exit "${HERDR_TEST_WORKSPACE_LIST_RC:-1}"
    cat "$HERDR_TEST_WORKSPACES"
    ;;
  *) exit 89 ;;
esac
MOCK
chmod +x "$MOCK_BIN/herdr"

export PATH="$MOCK_BIN:$PATH"
export HERDR_ENV=1
export HERDR_WORKSPACE_ID=wG
export HERDR_PANE_ID=wG:p1
export HERDR_TEST_TARGET="$MOCK_LOG/target"
export HERDR_TEST_MESSAGE="$MOCK_LOG/message"
export HERDR_TEST_PANE_JSON="$MOCK_LOG/pane.json"
export HERDR_TEST_CALLS="$MOCK_LOG/calls"
export HERDR_TEST_STARTS="$MOCK_LOG/starts"
export HERDR_TEST_WAITS="$MOCK_LOG/waits"
export HERDR_TEST_RENAMES="$MOCK_LOG/renames"
export HERDR_TEST_WORKSPACES="$TEST_TMP/workspaces.json"
export HERDR_SCOPE_FILE="$TEST_TMP/scope.json"
: > "$HERDR_TEST_CALLS"
: > "$HERDR_TEST_STARTS"
: > "$HERDR_TEST_WAITS"
: > "$HERDR_TEST_RENAMES"
rm -f "$HERDR_SCOPE_FILE"
printf '%s\n' \
  '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","label":"bob","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
  > "$HERDR_TEST_PANE_JSON"

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$1"
}

expect_rc() {
  local expected="$1"
  shift
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ]
}

expect_scope_reject() {
  local expected_reason="$1"
  shift
  local error actual
  set +e
  error="$("$@" 2>&1 >/dev/null)"
  actual=$?
  set -e
  if [ "$actual" -ne 3 ]; then
    printf 'expected exit 3 with scope-reject: %s, got %s: %s\n' \
      "$expected_reason" "$actual" "$error" >&2
    return 1
  fi
  case "$error" in
    *"scope-reject: $expected_reason"*) ;;
    *)
      printf 'expected scope-reject: %s, got: %s\n' "$expected_reason" "$error" >&2
      return 1
      ;;
  esac
}

assert_file_eq() {
  local expected="$1"
  local file="$2"
  [ "$(<"$file")" = "$expected" ]
}

reset_logs() {
  : > "$HERDR_TEST_CALLS"
  : > "$HERDR_TEST_STARTS"
  : > "$HERDR_TEST_WAITS"
  : > "$HERDR_TEST_RENAMES"
  rm -f "$HERDR_TEST_TARGET" "$HERDR_TEST_MESSAGE"
}

parent_success() {
  local prompt=$'run the child\nwith this prompt'
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 "$prompt"
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  local message
  message="$(<"$HERDR_TEST_MESSAGE")"
  case "$message" in
    "$prompt"*) ;;
    *) return 1 ;;
  esac
  [[ "$message" == *'Direct parent pane for result return: wG:p1 (bob)'* ]]
  local return_command="\"${CHILD_SCRIPT}\" \"wG:p1\" <completed|blocked> \"<body>\""
  [[ "$CHILD_SCRIPT" = /* ]]
  [[ "$message" == *"$return_command"* ]]
}

child_success() {
  local body=$'summary line\nsecond line'
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wG:p2 completed "$body"
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  assert_file_eq $'status: completed\nbody:\nsummary line\nsecond line' "$HERDR_TEST_MESSAGE"
}

child_blocked() {
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wG:p2 blocked 'needs parent input'
  assert_file_eq $'status: blocked\nbody:\nneeds parent input' "$HERDR_TEST_MESSAGE"
}

invalid_arguments() {
  expect_rc 2 "$PARENT_SCRIPT" --wait 'prompt'
  expect_rc 2 "$PARENT_SCRIPT" child-agent 'prompt'
  expect_rc 2 "$PARENT_SCRIPT" wG:p2 ''
  expect_rc 2 "$CHILD_SCRIPT" wG:p1 pending 'body'
  expect_rc 2 "$CHILD_SCRIPT" invalid-parent completed 'body'
  expect_rc 2 "$CHILD_SCRIPT" wG:p1 completed ''
}

preflight_failures() {
  expect_rc 1 env -u HERDR_ENV HERDR_PANE_ID=wG:p1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env -u HERDR_PANE_ID HERDR_ENV=1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env -u HERDR_WORKSPACE_ID HERDR_ENV=1 HERDR_PANE_ID=wG:p1 PATH="$PATH" \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env HERDR_WORKSPACE_ID=wG HERDR_PANE_ID=wJ:p1 \
    "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wG:p1 PATH="$TEST_TMP/empty:/usr/bin:/bin" \
    "$CHILD_SCRIPT" wG:p2 completed body
}

worktree_team_edges_are_allowed() {
  local prompt='run in the worktree team'
  # Parent checkout to linked worktree.
  reset_logs
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wB:p2 "$prompt"
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  grep -Fq 'Direct parent pane for result return: wG:p1 (bob)' "$HERDR_TEST_MESSAGE"
  # Linked worktree back to the parent checkout.
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wG:p2 "$prompt"
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  # Result return in both directions.
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$CHILD_SCRIPT" wG:p2 completed 'worktree team done'
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  reset_logs
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wB:p2 completed 'parent done'
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  # The edge was classified from live workspace state.
  grep -q '^workspace list' "$HERDR_TEST_CALLS"
}

cross_repo_edges_are_rejected() {
  reset_logs
  # Parent delegation into a different repository.
  expect_scope_reject repo-mismatch "$PARENT_SCRIPT" wE:p2 'prompt'
  # Result return into a different repository.
  expect_scope_reject repo-mismatch "$CHILD_SCRIPT" wE:p2 completed 'body'
  # A workspace the server does not report.
  expect_scope_reject unknown-workspace "$PARENT_SCRIPT" wJ:p2 'prompt'
  # A workspace without repository information.
  expect_scope_reject repo-mismatch "$PARENT_SCRIPT" wF:p2 'prompt'
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^agent prompt' "$HERDR_TEST_CALLS"
}

sibling_edges_are_rejected() {
  reset_logs
  # Two linked worktrees of one repository.
  expect_scope_reject sibling-worktrees env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wC:p2 'prompt'
  expect_scope_reject sibling-worktrees env HERDR_WORKSPACE_ID=wC HERDR_PANE_ID=wC:p1 \
    "$CHILD_SCRIPT" wB:p2 completed 'body'
  # Two parent checkouts of one repository.
  expect_scope_reject duplicate-checkout "$PARENT_SCRIPT" wD:p2 'prompt'
  expect_scope_reject duplicate-checkout env HERDR_WORKSPACE_ID=wD HERDR_PANE_ID=wD:p1 \
    "$CHILD_SCRIPT" wG:p2 completed 'body'
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^agent prompt' "$HERDR_TEST_CALLS"
}

write_expired_grant() {
  local source="$1" target="$2"
  python3 - "$HERDR_SCOPE_FILE" "$source" "$target" <<'PY'
import json, sys

path, source, target = sys.argv[1:4]
document = {
    "version": 1,
    "grants": [
        {
            "id": "g-expired",
            "source_workspace": source,
            "target_workspace": target,
            "task": "expired fixture",
            "granted_by": "reviewer",
            "created_at": "2020-01-01T00:00:00Z",
            "expires_at": "2020-01-02T00:00:00Z",
        }
    ],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
PY
}

grants_allow_undecidable_edges() {
  local id
  rm -f "$HERDR_SCOPE_FILE"
  reset_logs
  # Same-workspace delegation is allowed without any recorded grant.
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'no grant needed'
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"

  # A human-recorded grant covers a sibling-worktree edge in both directions.
  id="$("$GRANT_SCRIPT" grant --source wB --target wC --by reviewer --task '#210' | awk '{print $2}')"
  [ -n "$id" ]
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wC:p2 'granted delegation'
  assert_file_eq wC:p2 "$HERDR_TEST_TARGET"
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wC HERDR_PANE_ID=wC:p1 \
    "$CHILD_SCRIPT" wB:p2 completed 'granted return'
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"

  # An expired grant is not authorization.
  "$GRANT_SCRIPT" revoke "$id" >/dev/null
  write_expired_grant wB wC
  expect_scope_reject grant-expired env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wC:p2 'prompt'

  # A target-repo grant covers any workspace of that repository, and only the
  # granted source workspace may use it.
  rm -f "$HERDR_SCOPE_FILE"
  "$GRANT_SCRIPT" grant --source wB --target-repo "$REPO_ALPHA" --by reviewer >/dev/null
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wC:p2 'repo grant'
  assert_file_eq wC:p2 "$HERDR_TEST_TARGET"
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wC HERDR_PANE_ID=wC:p1 \
    "$CHILD_SCRIPT" wB:p2 completed 'repo grant return'
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  expect_scope_reject duplicate-checkout "$PARENT_SCRIPT" wD:p2 'prompt'

  # The same repository edge becomes allowed once its source is granted.
  "$GRANT_SCRIPT" grant --source wG --target-repo "$REPO_ALPHA" --by reviewer >/dev/null
  reset_logs
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wD:p2 'repo grant for wG'
  assert_file_eq wD:p2 "$HERDR_TEST_TARGET"

  # A malformed scope file fails closed instead of falling back to a shape.
  printf 'not json' > "$HERDR_SCOPE_FILE"
  expect_scope_reject scope-file-invalid "$PARENT_SCRIPT" wD:p2 'prompt'
  # ... and it never breaks same-workspace delegation.
  reset_logs
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'same workspace with a bad scope file'
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"
  rm -f "$HERDR_SCOPE_FILE"
}

workspace_list_failure_is_rejected() {
  reset_logs
  # `herdr workspace list` fails.
  expect_scope_reject workspace-list-failed \
    env HERDR_TEST_WORKSPACES="$TEST_TMP/no-such-workspaces.json" \
    "$PARENT_SCRIPT" wB:p2 'prompt'
  # The command succeeds but the payload is not usable state.
  printf '%s\n' '{not json' > "$TEST_TMP/broken-workspaces.json"
  expect_scope_reject workspace-list-invalid-json \
    env HERDR_TEST_WORKSPACES="$TEST_TMP/broken-workspaces.json" \
    "$PARENT_SCRIPT" wB:p2 'prompt'
  printf '%s\n' '{"result":{"type":"workspace_list"}}' > "$TEST_TMP/shapeless-workspaces.json"
  expect_scope_reject workspace-list-invalid-json \
    env HERDR_TEST_WORKSPACES="$TEST_TMP/shapeless-workspaces.json" \
    "$CHILD_SCRIPT" wB:p2 completed 'body'
  # The return path fails closed the same way.
  expect_scope_reject workspace-list-failed \
    env HERDR_TEST_WORKSPACES="$TEST_TMP/no-such-workspaces.json" \
    "$CHILD_SCRIPT" wB:p2 completed 'body'
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^agent prompt' "$HERDR_TEST_CALLS"
}

self_targets_are_rejected() {
  reset_logs
  expect_scope_reject self-pane "$PARENT_SCRIPT" wG:p1 'prompt'
  expect_scope_reject self-pane "$CHILD_SCRIPT" wG:p1 completed 'body'
  # A self target stays a self target inside a linked worktree.
  expect_scope_reject self-pane env HERDR_WORKSPACE_ID=wB HERDR_PANE_ID=wB:p1 \
    "$PARENT_SCRIPT" wB:p1 'prompt'
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^agent prompt' "$HERDR_TEST_CALLS"
}

scope_grant_cli() {
  local id
  rm -f "$HERDR_SCOPE_FILE"

  # Usage and validation errors.
  expect_rc 2 "$GRANT_SCRIPT"
  expect_rc 2 "$GRANT_SCRIPT" unknown
  expect_rc 2 "$GRANT_SCRIPT" list extra
  expect_rc 2 "$GRANT_SCRIPT" revoke
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --target wC
  expect_rc 1 "$GRANT_SCRIPT" grant --target wC --by reviewer
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --by reviewer
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --target wC --target-repo "$REPO_ALPHA" --by reviewer
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --target wC --by reviewer --ttl 0
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --target-repo relative/path --by reviewer
  expect_rc 1 "$GRANT_SCRIPT" revoke missing-grant
  [ ! -e "$HERDR_SCOPE_FILE" ]

  # A grant is recorded with mode 0600 and the documented fields.
  id="$("$GRANT_SCRIPT" grant --source wB --target wC --by reviewer --task 'Issue #210' --ttl 3600 | awk '{print $2}')"
  [ -n "$id" ]
  [ "$(stat -c '%a' "$HERDR_SCOPE_FILE")" = 600 ]
  python3 - "$HERDR_SCOPE_FILE" "$id" <<'PY'
import json, sys

path, grant_id = sys.argv[1:3]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
assert document["version"] == 1, document
grants = [grant for grant in document["grants"] if grant.get("id") == grant_id]
assert len(grants) == 1, grants
grant = grants[0]
for field in ("id", "source_workspace", "target_workspace", "task", "granted_by", "created_at", "expires_at"):
    assert field in grant, field
assert grant["source_workspace"] == "wB"
assert grant["target_workspace"] == "wC"
assert grant["task"] == "Issue #210"
assert grant["granted_by"] == "reviewer"
assert "target_repo_root" not in grant
assert grant["expires_at"] is not None
assert grant["expires_at"] > grant["created_at"]
PY
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $1}')" = "$id" ]
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $3}')" = 'workspace:wC' ]
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $4}')" = 'active' ]
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $7}')" = 'reviewer' ]

  # revoke removes exactly that record.
  "$GRANT_SCRIPT" revoke "$id" | grep -Fq "revoked $id"
  [ -z "$("$GRANT_SCRIPT" list)" ]
  expect_rc 1 "$GRANT_SCRIPT" revoke "$id"

  # A target-repo grant records the resolved repository path, not a workspace.
  id="$("$GRANT_SCRIPT" grant --source wB --target-repo "$REPO_ALPHA/" --by reviewer | awk '{print $2}')"
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $3}')" = "repo:$REPO_ALPHA" ]
  [ "$("$GRANT_SCRIPT" list | awk -F'\t' '{print $5}')" = 'never' ]
  "$GRANT_SCRIPT" revoke "$id" >/dev/null

  # Without HERDR_SCOPE_FILE, the documented default path is used.
  rm -rf "$TEST_TMP/xdg"
  env -u HERDR_SCOPE_FILE XDG_CONFIG_HOME="$TEST_TMP/xdg" \
    "$GRANT_SCRIPT" grant --source wG --target wB --by reviewer >/dev/null
  [ -f "$TEST_TMP/xdg/herdr/delegation-scope.json" ]
  [ "$(stat -c '%a' "$TEST_TMP/xdg/herdr/delegation-scope.json")" = 600 ]

  # A malformed file is reported, never rewritten.
  printf 'not json' > "$HERDR_SCOPE_FILE"
  expect_rc 1 "$GRANT_SCRIPT" grant --source wB --target wC --by reviewer
  expect_rc 1 "$GRANT_SCRIPT" list
  [ "$(<"$HERDR_SCOPE_FILE")" = 'not json' ]
  rm -f "$HERDR_SCOPE_FILE"
}

worktree_team_start_flow() {
  local task_file="$TEST_TMP/task.md"
  printf '%s\n' 'Goal: implement the delegated work' 'Acceptance: tests pass' > "$task_file"

  # The scope check runs before anything is started or written.
  reset_logs
  expect_scope_reject repo-mismatch "$START_SCRIPT" wE:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # A worktree-team edge runs start, bounded wait, rename, then the wrapper.
  reset_logs
  HERDR_TEST_RC=0 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  [ "$(wc -l < "$HERDR_TEST_STARTS")" -eq 1 ]
  grep -Fqx 'agent start impl --kind pi --pane wB:p2 --timeout 60000 -- --provider anthropic --model claude-sonnet-4-5 --thinking high' "$HERDR_TEST_STARTS"
  [ "$(wc -l < "$HERDR_TEST_WAITS")" -eq 1 ]
  grep -Fqx 'agent wait wB:p2 --until idle --until done --until blocked --timeout 60000' "$HERDR_TEST_WAITS"
  grep -Fqx 'wB:p2 impl' "$HERDR_TEST_RENAMES"
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  grep -Fq 'Goal: implement the delegated work' "$HERDR_TEST_MESSAGE"
  grep -Fq 'Direct parent pane for result return: wG:p1 (bob)' "$HERDR_TEST_MESSAGE"

  # A readiness failure stops before the prompt call.
  reset_logs
  expect_rc 1 env HERDR_TEST_WAIT_RC=1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  [ -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # Validation failures happen before any herdr write.
  reset_logs
  expect_rc 1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking extreme "$task_file"
  expect_rc 1 "$START_SCRIPT" wB:p2 impl \
    --provider $'bad\nprovider' --model claude-sonnet-4-5 --thinking high "$task_file"
  expect_rc 1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$TEST_TMP/missing-task.md"
  : > "$task_file"
  expect_rc 1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider anthropic --model claude-sonnet-4-5
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]
}

cli_failure_is_propagated() {
  expect_rc 17 env HERDR_TEST_RC=17 "$PARENT_SCRIPT" wG:p2 prompt
  expect_rc 17 env HERDR_TEST_RC=17 "$CHILD_SCRIPT" wG:p2 completed body
}

parent_display_name_fallbacks() {
  local prompt='run the child'
  printf '%s\n' \
    '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
    > "$HERDR_TEST_PANE_JSON"
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 "$prompt"
  grep -Fqx 'Direct parent pane for result return: wG:p1 (pi)' "$HERDR_TEST_MESSAGE"
  HERDR_TEST_PANE_JSON="$TEST_TMP/missing.json" HERDR_TEST_RC=0 \
    "$PARENT_SCRIPT" wG:p2 "$prompt"
  grep -Fqx 'Direct parent pane for result return: wG:p1' "$HERDR_TEST_MESSAGE"
}

python3_isolation() {
  printf '%s\n' \
    '{"id":"cli:pane:get","result":{"pane":{"agent":"pi","label":"bob","pane_id":"wG:p1","workspace_id":"wG"}},"type":"pane_info"}' \
    > "$HERDR_TEST_PANE_JSON"
  local hostile="$TEST_TMP/hostile-cwd"
  local marker="$TEST_TMP/jsonpy-executed"
  mkdir -p "$hostile"
  printf '%s\n' \
    'import os' \
    "os.system(\"touch $marker\")" \
    'print("pwned")' > "$hostile/json.py"
  (cd "$hostile" && HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'run the child')
  [ ! -e "$marker" ]
  grep -Fqx 'Direct parent pane for result return: wG:p1 (bob)' "$HERDR_TEST_MESSAGE"
}

call_counts_are_exactly_once() {
  [ "$(grep -Ec '^pane ' "$HERDR_TEST_CALLS")" -eq 1 ]
  grep -Fqx 'pane get wG:p1' "$HERDR_TEST_CALLS"
  [ "$(grep -Ec '^agent prompt ' "$HERDR_TEST_CALLS")" -eq 1 ]
  grep -Fqx 'agent prompt wG:p2' "$HERDR_TEST_CALLS"
}

wrappers_are_thin() {
  ! grep -Eq -- '--wait|herdr (workspace|worktree|agent (get|read))' \
    "$PARENT_SCRIPT" "$CHILD_SCRIPT"
  ! grep -Eq -- 'herdr (pane|workspace|worktree|agent (get|read))' \
    "$CHILD_SCRIPT"
  # The parent may resolve the display name with exactly one read-only lookup.
  grep -Eq 'herdr pane get' "$PARENT_SCRIPT"
  ! grep -Eo 'herdr pane [[:alnum:]_-]+' "$PARENT_SCRIPT" | grep -Fxv 'herdr pane get'
  # Success path: one pane get and one agent prompt, no duplicates.
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'run the child'
  call_counts_are_exactly_once
  # Lookup failure path: still one pane get and one agent prompt, no retries.
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_PANE_JSON="$TEST_TMP/missing.json" HERDR_TEST_RC=0 \
    "$PARENT_SCRIPT" wG:p2 'run the child'
  call_counts_are_exactly_once
  # Same-workspace delegation never consults workspace state.
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wG:p2 'run the child'
  ! grep -q '^workspace ' "$HERDR_TEST_CALLS"
  : > "$HERDR_TEST_CALLS"
  HERDR_TEST_RC=0 "$CHILD_SCRIPT" wG:p2 completed 'body'
  ! grep -q '^workspace ' "$HERDR_TEST_CALLS"
}

markdown_links_resolve() {
  local file link target dir checked=0
  for file in "$HERDR_DIR"/*.md "$HERDR_DIR"/references/*.md; do
    dir="$(dirname "$file")"
    while IFS= read -r link; do
      case "$link" in
        http://*|https://*|mailto:*|'#'*) continue ;;
      esac
      target="${link%%#*}"
      target="${target%%[[:space:]]*}"
      target="${target#<}"
      target="${target%>}"
      [ -n "$target" ] || continue
      if [ ! -f "$dir/$target" ]; then
        printf 'FAIL: %s: relative link does not resolve: %s\n' "$file" "$link" >&2
        return 1
      fi
      checked=$((checked + 1))
    done < <(grep -oE '\]\([^)]*\)' "$file" | sed -e 's/^](//' -e 's/)$//')
  done
  # Guard against a parser that silently matches nothing.
  [ "$checked" -gt 0 ]
}

run_test() {
  local test_name="$1"
  "$test_name"
  pass "$test_name"
}

expected_count=18

run_test parent_success
run_test child_success
run_test child_blocked
run_test invalid_arguments
run_test preflight_failures
run_test worktree_team_edges_are_allowed
run_test cross_repo_edges_are_rejected
run_test sibling_edges_are_rejected
run_test grants_allow_undecidable_edges
run_test workspace_list_failure_is_rejected
run_test self_targets_are_rejected
run_test scope_grant_cli
run_test worktree_team_start_flow
run_test cli_failure_is_propagated
run_test parent_display_name_fallbacks
run_test python3_isolation
run_test wrappers_are_thin
run_test markdown_links_resolve

[ "$pass_count" -eq "$expected_count" ] || {
  printf 'FAIL: expected %s tests, got %s\n' "$expected_count" "$pass_count" >&2
  exit 1
}

printf 'PASS: %s Herdr async wrapper tests\n' "$pass_count"
