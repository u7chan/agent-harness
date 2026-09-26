#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_SCRIPT="$HERDR_DIR/scripts/parent-delegate-async.sh"
CHILD_SCRIPT="$HERDR_DIR/scripts/child-return-result.sh"
START_SCRIPT="$HERDR_DIR/scripts/worktree-team-start.sh"
GRANT_SCRIPT="$HERDR_DIR/scripts/scope-grant.sh"
LAYOUT_SCRIPT="$HERDR_DIR/scripts/pane-layout.sh"
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
# pane layout, pane split, and tab create are also recorded with their full
# argument list, so a test can assert the exact creation sequence.
case "${1:-} ${2:-}" in
  'pane layout'|'pane split'|'tab create') printf '%s\n' "$*" >> "$HERDR_TEST_LAYOUT_CALLS" ;;
esac
pane_field() { # $1=pane id $2=field number
  awk -F'|' -v pane="$1" -v field="$2" '$1 == pane { print $field; exit }' "$HERDR_TEST_STATE/panes"
}
pane_tab() { # $1=pane id
  awk -F'|' -v pane="$1" '$1 == pane { print $2; exit }' "$HERDR_TEST_STATE/panes"
}
tab_area() { # $1=tab id, prints area_x|area_y|area_w|area_h
  awk -F'|' -v tab="$1" '$1 == tab { print $3 "|" $4 "|" $5 "|" $6; exit }' "$HERDR_TEST_STATE/tabs"
}
next_id() {
  local next
  next="$(cat "$HERDR_TEST_STATE/next")"
  printf '%s\n' "$((next + 1))" > "$HERDR_TEST_STATE/next"
  printf '%s' "$next"
}
case "${1:-}" in
  pane)
    case "${2:-}" in
      get)
        [ "${3:-}" = "$HERDR_PANE_ID" ] || exit 95
        cat "$HERDR_TEST_PANE_JSON"
        ;;
      layout)
        [ "${3:-}" = --pane ] || exit 95
        tab_id="$(pane_tab "${4:-}")"
        [ -n "$tab_id" ] || exit 96
        IFS='|' read -r area_x area_y area_w area_h <<< "$(tab_area "$tab_id")"
        [ -n "$area_w" ] || exit 96
        panes_json=''
        separator=''
        while IFS='|' read -r pane_id pane_tab_id x y w h; do
          [ "$pane_tab_id" = "$tab_id" ] || continue
          # Once panes have been split, the reported rectangles can disagree
          # with the plan on purpose (HERDR_TEST_LAYOUT_SHIFT).
          skew=0
          [ ! -s "$HERDR_TEST_STATE/splits" ] || skew="${HERDR_TEST_LAYOUT_SHIFT:-0}"
          panes_json="${panes_json}${separator}{\"pane_id\":\"${pane_id}\",\"rect\":{\"x\":$((x + skew)),\"y\":$((y + skew)),\"width\":$((w + skew)),\"height\":$((h + skew))}}"
          separator=,
        done < "$HERDR_TEST_STATE/panes"
        printf '{"id":"cli:pane:layout","result":{"layout":{"area":{"x":%s,"y":%s,"width":%s,"height":%s},"panes":[%s],"tab_id":"%s","workspace_id":"%s","zoomed":false},"type":"pane_layout"}}\n' \
          "$area_x" "$area_y" "$area_w" "$area_h" "$panes_json" "$tab_id" "$HERDR_WORKSPACE_ID"
        ;;
      split)
        source_pane=''
        direction=''
        ratio=''
        shift 2
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --pane) source_pane="${2:-}"; shift 2 ;;
            --direction) direction="${2:-}"; shift 2 ;;
            --ratio) ratio="${2:-}"; shift 2 ;;
            --cwd) [ -d "${2:-}" ] || exit 97; shift 2 ;;
            --no-focus) shift ;;
            *) exit 92 ;;
          esac
        done
        [ -n "$source_pane" ] || exit 95
        [ "${HERDR_TEST_SPLIT_RC:-0}" = 0 ] || exit "${HERDR_TEST_SPLIT_RC}"
        tab_id="$(pane_tab "$source_pane")"
        [ -n "$tab_id" ] || exit 96
        x="$(pane_field "$source_pane" 3)"
        y="$(pane_field "$source_pane" 4)"
        w="$(pane_field "$source_pane" 5)"
        h="$(pane_field "$source_pane" 6)"
        if [ "$direction" = right ]; then
          keep="$(awk -v n="$w" -v r="$ratio" 'BEGIN { printf "%d", n * r + 0.5 }')"
          new_x=$((x + keep))
          new_y=$y
          new_w=$((w - keep))
          new_h=$h
          source_w=$keep
          source_h=$h
        elif [ "$direction" = down ]; then
          keep="$(awk -v n="$h" -v r="$ratio" 'BEGIN { printf "%d", n * r + 0.5 }')"
          new_x=$x
          new_y=$((y + keep))
          new_w=$w
          new_h=$((h - keep))
          source_w=$w
          source_h=$keep
        else
          exit 92
        fi
        awk -F'|' -v pane="$source_pane" -v x="$x" -v y="$y" -v w="$source_w" -v h="$source_h" \
          'BEGIN { OFS="|" } { if ($1 == pane) { $3=x; $4=y; $5=w; $6=h } print }' \
          "$HERDR_TEST_STATE/panes" > "$HERDR_TEST_STATE/panes.next"
        mv "$HERDR_TEST_STATE/panes.next" "$HERDR_TEST_STATE/panes"
        id="$(next_id)"
        pane_id="$HERDR_WORKSPACE_ID:p$id"
        printf '%s|%s|%s|%s|%s|%s\n' "$pane_id" "$tab_id" "$new_x" "$new_y" "$new_w" "$new_h" >> "$HERDR_TEST_STATE/panes"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$tab_id" "$direction" "$ratio" "$x" "$y" "$w" "$h" >> "$HERDR_TEST_STATE/splits"
        printf '{"id":"cli:pane:split","result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"},"type":"pane_split"}}\n' \
          "$pane_id" "$tab_id" "$HERDR_WORKSPACE_ID"
        ;;
      rename)
        printf '%s %s\n' "${3:-}" "${4:-}" >> "$HERDR_TEST_RENAMES"
        exit "${HERDR_TEST_RENAME_RC:-0}"
        ;;
      *) exit 94 ;;
    esac
    ;;
  tab)
    [ "${2:-}" = create ] || exit 93
    label=''
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workspace) [ "${2:-}" = "$HERDR_WORKSPACE_ID" ] || exit 92; shift 2 ;;
        --cwd) [ -d "${2:-}" ] || exit 97; shift 2 ;;
        --label) label="${2:-}"; shift 2 ;;
        --no-focus) shift ;;
        *) exit 92 ;;
      esac
    done
    IFS='x' read -r area_w area_h <<< "$HERDR_TEST_TAB_AREA"
    [ -n "$area_h" ] || exit 96
    id="$(next_id)"
    tab_id="$HERDR_WORKSPACE_ID:t$id"
    pane_id="$HERDR_WORKSPACE_ID:p$id"
    printf '%s|%s|0|0|%s|%s\n' "$tab_id" "$label" "$area_w" "$area_h" >> "$HERDR_TEST_STATE/tabs"
    printf '%s|%s|0|0|%s|%s\n' "$pane_id" "$tab_id" "$area_w" "$area_h" >> "$HERDR_TEST_STATE/panes"
    printf '{"id":"cli:tab:create","result":{"tab":{"tab_id":"%s","label":"%s","workspace_id":"%s"},"root_pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"},"type":"tab_create"}}\n' \
      "$tab_id" "$label" "$HERDR_WORKSPACE_ID" "$pane_id" "$tab_id" "$HERDR_WORKSPACE_ID"
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
# State behind the fake `herdr pane layout`, `pane split`, and `tab create`.
export HERDR_TEST_STATE="$TEST_TMP/layout-state"
export HERDR_TEST_LAYOUT_CALLS="$TEST_TMP/layout-calls"
export HERDR_TEST_TAB_AREA='247x47'
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

# ---------------------------------------------------------------------------
# Pane layout: fixtures and projections for herdr/scripts/pane-layout.sh.
# Every layout test runs against the mock herdr in $MOCK_BIN; the script never
# reaches a real server.
# ---------------------------------------------------------------------------

# reset_layout_state <tab area WxH> <caller x> <caller y> <caller w> <caller h>
reset_layout_state() {
  rm -rf "$HERDR_TEST_STATE"
  mkdir -p "$HERDR_TEST_STATE"
  printf '%s|1|0|0|%s|%s\n' "$HERDR_WORKSPACE_ID:t1" "${1%x*}" "${1#*x}" \
    > "$HERDR_TEST_STATE/tabs"
  printf '%s|%s:t1|%s|%s|%s|%s\n' "$HERDR_PANE_ID" "$HERDR_WORKSPACE_ID" "$2" "$3" "$4" "$5" \
    > "$HERDR_TEST_STATE/panes"
  : > "$HERDR_TEST_STATE/splits"
  printf '9\n' > "$HERDR_TEST_STATE/next"
  : > "$HERDR_TEST_LAYOUT_CALLS"
}

plan_json() { # <area WxH> <count> [extra plan arguments]
  local area="$1" count="$2"
  shift 2
  "$LAYOUT_SCRIPT" plan --area "$area" --count "$count" "$@"
}

# Projections of a plan or apply document, read from stdin.
plan_grid_json() {
  python3 -c '
import json
import sys

plan = json.load(sys.stdin)
print(json.dumps([plan["rows"], plan["cols"], len(plan["tabs"][0]["cells"])], separators=(",", ":")))
'
}

plan_tabs_json() {
  python3 -c '
import json
import sys

plan = json.load(sys.stdin)
print(json.dumps([[tab["rows"], tab["cols"], len(tab["cells"]), tab["label"]]
                  for tab in plan["tabs"]], separators=(",", ":")))
'
}

plan_cells_json() { # cells of the first (or only) tab
  python3 -c '
import json
import sys

tab = json.load(sys.stdin)["tabs"][0]
print(json.dumps([[cell["index"], cell["row"], cell["col"], cell["x"], cell["y"],
                   cell["width"], cell["height"], cell["source"]] for cell in tab["cells"]],
                 separators=(",", ":")))
'
}

plan_splits_json() {
  python3 -c '
import json
import sys

plan = json.load(sys.stdin)
print(json.dumps([[split["tab"], split["source_cell"], split["target_cell"],
                   split["direction"], split["ratio"]] for split in plan["splits"]],
                 separators=(",", ":")))
'
}

assert_json_field() { # <field path> <expected JSON value>; document on stdin
  python3 -c '
import json
import sys

value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[int(key)] if isinstance(value, list) else value[key]
if value != json.loads(sys.argv[2]):
    sys.stderr.write("expected %s = %s, got %s\n" % (sys.argv[1], sys.argv[2], json.dumps(value)))
    sys.exit(1)
' "$1" "$2"
}

# expect_plan <area> <count> <projection> <expected JSON> [extra plan arguments]
# The grid for a cell count M is asserted through M = --count + 1: in the
# current-tab policy the caller pane occupies cell 0.
expect_plan() {
  local area="$1" count="$2" projection="$3" expected="$4" actual
  shift 4
  actual="$(plan_json "$area" "$count" "$@" | "$projection")" || return 1
  [ "$actual" = "$expected" ] || {
    printf 'plan %s --count %s: expected %s, got %s\n' \
      "$area" "$count" "$expected" "$actual" >&2
    return 1
  }
}

expect_plan_field() { # <area> <count> <path> <expected JSON> [extra plan arguments]
  local area="$1" count="$2" path="$3" expected="$4"
  shift 4
  plan_json "$area" "$count" "$@" | assert_json_field "$path" "$expected"
}

expect_plan_error() { # <area> <count> <message substring>
  local error status
  set +e
  error="$(plan_json "$1" "$2" 2>&1 >/dev/null)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf 'expected plan %s --count %s to fail\n' "$1" "$2" >&2
    return 1
  fi
  case "$error" in
    *"$3"*) ;;
    *)
      printf 'expected a message containing "%s", got: %s\n' "$3" "$error" >&2
      return 1
      ;;
  esac
}

assert_layout_calls() { # <expected full creation call sequence>
  local actual
  actual="$(<"$HERDR_TEST_LAYOUT_CALLS")"
  [ "$actual" = "$1" ] || {
    printf 'unexpected herdr creation calls:\n%s\nexpected:\n%s\n' "$actual" "$1" >&2
    return 1
  }
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
  # The child wrapper pins its own pane the same way, in both directions.
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wJ:p1 PATH="$PATH" \
    "$CHILD_SCRIPT" wG:p2 completed body
  expect_rc 1 env -u HERDR_WORKSPACE_ID HERDR_ENV=1 HERDR_PANE_ID=wG:p1 PATH="$PATH" \
    "$CHILD_SCRIPT" wG:p2 completed body
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
  [ "$(wc -l < "$HERDR_TEST_WAITS")" -eq 1 ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # A failed start stops before the wait and the prompt.
  reset_logs
  expect_rc 1 env HERDR_TEST_START_RC=1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  [ -s "$HERDR_TEST_STARTS" ]
  [ ! -s "$HERDR_TEST_WAITS" ]
  [ ! -s "$HERDR_TEST_RENAMES" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # A failed rename stops before the prompt.
  reset_logs
  expect_rc 1 env HERDR_TEST_RENAME_RC=1 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file"
  [ -s "$HERDR_TEST_STARTS" ]
  grep -Fqx 'wB:p2 impl' "$HERDR_TEST_RENAMES"
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

pane_layout_plan_grids() {
  # Grids from the acceptance list of Issue #217, indexed by the cell count M
  # of the planned layout: 3 -> 3 columns, 4 -> 2x2, 8 -> 4x2, 9 -> 3x3,
  # 12 -> 4x3, 16 -> two tabs. In the current-tab policy the caller pane is
  # cell 0, so M = --count + 1 and `apply` creates exactly `--count` panes.
  expect_plan 247x47 2 plan_grid_json '[1,3,3]'
  expect_plan 247x47 3 plan_grid_json '[2,2,4]'
  expect_plan 247x47 7 plan_grid_json '[2,4,8]'
  expect_plan 247x47 8 plan_grid_json '[3,3,9]'
  expect_plan 247x47 11 plan_grid_json '[3,4,12]'
  expect_plan_field 247x47 2 tab_policy '"current"'
  expect_plan_field 247x47 2 capacity 12
  expect_plan_field 247x47 2 region '{"width":247,"height":47}'
  expect_plan_field 247x47 11 rows 3
  expect_plan_field 247x47 11 cols 4
  # M = 16 exceeds the 12-pane capacity of the tab, so the team goes to new
  # tabs instead: 15 panes become 8 and 7, 16 panes become two tabs of 8.
  expect_plan 247x47 15 plan_tabs_json '[[2,4,8,null],[2,4,7,null]]'
  expect_plan_field 247x47 15 tab_policy '"new"'
  expect_plan 247x47 16 plan_tabs_json '[[2,4,8,null],[2,4,8,null]]'
  # A second region, derived with the same rules:
  #   M=4  -> 2x2: the only grid of this area without an empty slot
  #   M=5  -> 3x2: 2x3 and 3x2 both leave one slot; the wider cell of 2x3 wins
  #           on fill (min(100/55, 20/14) > min(200/3/55, 30/14))
  #   M=9  -> 3x3: four columns would need 220 cells of width
  #   M=12 -> 3x4, the largest grid this area can hold
  expect_plan 200x60 3 plan_grid_json '[2,2,4]'
  expect_plan 200x60 4 plan_grid_json '[3,2,5]'
  expect_plan 200x60 8 plan_grid_json '[3,3,9]'
  expect_plan 200x60 11 plan_grid_json '[4,3,12]'
  expect_plan_field 200x60 3 capacity 12
  expect_plan 300x60 5 plan_grid_json '[2,3,6]'
  expect_plan 300x60 19 plan_grid_json '[4,5,20]'
  expect_plan_field 300x60 19 capacity 20
}

pane_layout_plan_new_tabs() {
  # 120x40 holds 4 panes in one tab, so a 5-pane team is split over two tabs,
  # as evenly as possible with the larger tab first, and labelled with the
  # team label and its -2 suffix.
  expect_plan 120x40 5 plan_tabs_json '[[2,2,3,"crew"],[1,2,2,"crew-2"]]' --label crew
  expect_plan_field 120x40 5 tab_policy '"new"'
  expect_plan_field 120x40 5 capacity 4
  expect_plan_field 120x40 5 label '"crew"' --label crew
  expect_plan_field 120x40 5 rows null
  expect_plan_field 120x40 5 cols null
  expect_plan 120x40 5 plan_tabs_json '[[2,2,3,null],[1,2,2,null]]'
  # A team that fills a tab exactly still needs its own tab.
  expect_plan 300x60 20 plan_tabs_json '[[4,5,20,null]]'
  expect_plan_field 300x60 20 tab_policy '"new"'
  # Three tabs, evenly sized and larger first, labelled with the -2 and -3
  # suffixes after the first tab takes the plain team label.
  expect_plan 300x60 42 plan_tabs_json \
    '[[3,5,14,null],[3,5,14,null],[3,5,14,null]]'
  expect_plan 300x60 60 plan_tabs_json \
    '[[4,5,20,null],[4,5,20,null],[4,5,20,null]]'
  expect_plan 300x60 42 plan_tabs_json \
    '[[3,5,14,"squad"],[3,5,14,"squad-2"],[3,5,14,"squad-3"]]' --label squad
}

pane_layout_plan_geometry() {
  # M = 3 in the current tab: one row of three 82/82/83 cell panes.
  expect_plan 247x47 2 plan_cells_json \
    '[[0,0,0,0,0,82,47,true],[1,0,1,82,0,82,47,false],[2,0,2,164,0,83,47,false]]'
  expect_plan 247x47 2 plan_splits_json '[[0,0,1,"right",0.331984],[0,1,2,"right",0.49697]]'
  # M = 7: the row cut runs first, then each row left to right, and the
  # three-cell last row spreads its panes over the full width.
  expect_plan 247x47 6 plan_cells_json \
    '[[0,0,0,0,0,61,23,true],[1,0,1,61,0,62,23,false],[2,0,2,123,0,62,23,false],[3,0,3,185,0,62,23,false],[4,1,0,0,23,82,24,false],[5,1,1,82,23,82,24,false],[6,1,2,164,23,83,24,false]]'
  expect_plan 247x47 6 plan_splits_json \
    '[[0,0,4,"down",0.489362],[0,0,1,"right",0.246964],[0,1,2,"right",0.333333],[0,2,3,"right",0.5],[0,4,5,"right",0.331984],[0,5,6,"right",0.49697]]'
  # A three-row grid with a partly filled last row: the row cut chain runs
  # first, then each row, so every row pane spans the full width when cut.
  expect_plan 200x60 4 plan_splits_json \
    '[[0,0,2,"down",0.333333],[0,2,4,"down",0.5],[0,0,1,"right",0.5],[0,2,3,"right",0.5]]'
  # Only the top-left cell is the pane the plan starts from.
  expect_plan 200x60 4 plan_cells_json \
    '[[0,0,0,0,0,100,20,true],[1,0,1,100,0,100,20,false],[2,1,0,0,20,100,20,false],[3,1,1,100,20,100,20,false],[4,2,0,0,40,200,20,false]]'
}

pane_layout_plan_is_pure() {
  reset_layout_state 247x47 0 0 247 47
  reset_logs
  expect_plan 247x47 3 plan_grid_json '[2,2,4]'
  # plan makes no herdr call at all, so it needs neither a server nor herdr.
  [ ! -s "$HERDR_TEST_LAYOUT_CALLS" ]
  [ ! -s "$HERDR_TEST_CALLS" ]
  env -u HERDR_ENV PATH='/usr/bin:/bin' "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 |
    plan_grid_json | grep -Fqx '[1,3,3]'
  env -u HERDR_ENV PATH='/usr/bin:/bin' "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 |
    assert_json_field mode '"plan"'
}

pane_layout_plan_rejects_bad_input() {
  # Neither of these areas can hold one pane inside the aspect window.
  expect_plan_error 40x10 3 'no feasible pane grid'
  expect_plan_error 100x14 3 'no feasible pane grid'
  # Usage errors.
  expect_rc 2 "$LAYOUT_SCRIPT"
  expect_rc 2 "$LAYOUT_SCRIPT" plan
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2
  expect_rc 2 "$LAYOUT_SCRIPT" plan --area 247x47
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count two --area 247x47
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2 --area 247
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 --pane wG:p1
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 --cwd "$TEST_TMP"
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 extra
  expect_rc 2 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 --unknown
  expect_rc 2 "$LAYOUT_SCRIPT" apply --count 2 --area 247x47
  expect_rc 2 "$LAYOUT_SCRIPT" unknown --count 2
  # Value errors.
  expect_rc 1 "$LAYOUT_SCRIPT" plan --count 1 --area 247x47
  expect_rc 1 "$LAYOUT_SCRIPT" plan --count 2 --area 0x47
  expect_rc 1 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 --label 'bad|label'
  expect_rc 1 "$LAYOUT_SCRIPT" plan --count 2 --area 247x47 --label $'bad\nlabel'
  # apply preflight.
  expect_rc 1 env -u HERDR_ENV "$LAYOUT_SCRIPT" apply --count 2
  expect_rc 1 env HERDR_ENV=0 HERDR_PANE_ID=wG:p1 "$LAYOUT_SCRIPT" apply --count 2
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wG:p1 "$LAYOUT_SCRIPT" apply --count 2 --cwd relative
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wG:p1 \
    "$LAYOUT_SCRIPT" apply --count 2 --cwd "$TEST_TMP/missing"
  expect_rc 1 env HERDR_ENV=1 HERDR_PANE_ID=wG:p1 \
    "$LAYOUT_SCRIPT" apply --count 2 --cwd "$TEST_TMP" --pane nope
}

pane_layout_apply_current_tab() {
  local result expected
  reset_layout_state 247x47 0 0 247 47
  result="$(HERDR_TEST_TAB_AREA=247x47 "$LAYOUT_SCRIPT" apply --count 3 --label team --cwd "$TEST_TMP")"
  printf '%s' "$result" | assert_json_field tab_policy '"current"'
  printf '%s' "$result" | assert_json_field rows 2
  printf '%s' "$result" | assert_json_field cols 2
  printf '%s' "$result" | assert_json_field count 3
  printf '%s' "$result" | assert_json_field label '"team"'
  printf '%s' "$result" | assert_json_field mode '"apply"'
  # Created pane IDs are reported in cell (row-major) order, not in creation
  # order: the row cut creates wG:p9 first, but that pane is cell 2.
  printf '%s' "$result" | assert_json_field created_panes '["wG:p10","wG:p9","wG:p11"]'
  printf '%s' "$result" | assert_json_field tabs.0.tab_id '"wG:t1"'
  printf '%s' "$result" | assert_json_field tabs.0.cells.0.pane_id '"wG:p1"'
  printf '%s' "$result" | assert_json_field tabs.0.cells.3.pane_id '"wG:p11"'
  printf '%s' "$result" | assert_json_field tabs.0.cells.3.width 124
  # No tab is created, and every creation keeps cwd and focus.
  expected="$(cat <<EOF
pane layout --pane wG:p1
pane split --pane wG:p1 --direction down --ratio 0.489362 --cwd $TEST_TMP --no-focus
pane split --pane wG:p1 --direction right --ratio 0.497976 --cwd $TEST_TMP --no-focus
pane split --pane wG:p9 --direction right --ratio 0.497976 --cwd $TEST_TMP --no-focus
pane layout --pane wG:p1
EOF
)"
  assert_layout_calls "$expected"
  ! grep -q '^tab create' "$HERDR_TEST_LAYOUT_CALLS"
}

pane_layout_apply_new_tabs() {
  local result expected
  # The caller's 60x20 pane cannot hold a four-cell grid, so the whole team
  # goes to one new tab in the same workspace and the caller is untouched.
  reset_layout_state 247x47 30 0 60 20
  result="$(HERDR_TEST_TAB_AREA=247x47 "$LAYOUT_SCRIPT" apply --count 3 --label team --cwd "$TEST_TMP")"
  printf '%s' "$result" | assert_json_field tab_policy '"new"'
  printf '%s' "$result" | assert_json_field created_panes '["wG:p9","wG:p10","wG:p11"]'
  printf '%s' "$result" | assert_json_field tabs.0.tab_id '"wG:t9"'
  printf '%s' "$result" | assert_json_field tabs.0.label '"team"'
  printf '%s' "$result" | assert_json_field tabs.0.rows 1
  printf '%s' "$result" | assert_json_field tabs.0.cols 3
  expected="$(cat <<EOF
pane layout --pane wG:p1
tab create --label team --workspace wG --cwd $TEST_TMP --no-focus
pane split --pane wG:p9 --direction right --ratio 0.331984 --cwd $TEST_TMP --no-focus
pane split --pane wG:p10 --direction right --ratio 0.496970 --cwd $TEST_TMP --no-focus
pane layout --pane wG:p9
EOF
)"
  assert_layout_calls "$expected"
  # The caller pane is never split or resized.
  ! grep -q 'wG:p1' "$HERDR_TEST_STATE/splits"

  # A larger team uses two tabs, labelled with the -2 suffix, larger first.
  reset_layout_state 300x60 0 0 300 60
  result="$(HERDR_TEST_TAB_AREA=300x60 "$LAYOUT_SCRIPT" apply --count 21 --label squad --cwd "$TEST_TMP")"
  printf '%s' "$result" | assert_json_field tab_policy '"new"'
  printf '%s' "$result" | assert_json_field tabs.0.label '"squad"'
  printf '%s' "$result" | assert_json_field tabs.1.label '"squad-2"'
  printf '%s' "$result" | assert_json_field tabs.0.rows 3
  printf '%s' "$result" | assert_json_field tabs.0.cols 4
  printf '%s' "$result" | assert_json_field tabs.1.rows 2
  printf '%s' "$result" | assert_json_field tabs.1.cols 5
  [ "$(grep -c '^tab create ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 2 ]
  grep -Fqx "tab create --label squad --workspace wG --cwd $TEST_TMP --no-focus" \
    "$HERDR_TEST_LAYOUT_CALLS"
  grep -Fqx "tab create --label squad-2 --workspace wG --cwd $TEST_TMP --no-focus" \
    "$HERDR_TEST_LAYOUT_CALLS"
  # 21 created panes: 10 splits in the first tab, 9 in the second.
  [ "$(grep -c '^pane split ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 19 ]
  [ "$(grep -c '^pane layout ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 3 ]
}

pane_layout_apply_stops_on_mismatch() {
  local error status
  # The library reports rectangles that disagree with the plan by five cells.
  reset_layout_state 247x47 0 0 247 47
  set +e
  error="$(HERDR_TEST_LAYOUT_SHIFT=5 "$LAYOUT_SCRIPT" apply --count 3 --cwd "$TEST_TMP" 2>&1 >/dev/null)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || {
    printf 'expected a non-zero exit for a mismatching layout\n' >&2
    return 1
  }
  case "$error" in
    *'does not match the plan'*) ;;
    *)
      printf 'expected a mismatch report, got: %s\n' "$error" >&2
      return 1
      ;;
  esac
  # It stops after building the tab once: no repair, resize, or retry.
  [ "$(grep -c '^pane split ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 3 ]
  [ "$(grep -c '^pane layout ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 2 ]

  # A rejected split stops the run immediately and names the operation.
  reset_layout_state 247x47 0 0 247 47
  set +e
  error="$(HERDR_TEST_SPLIT_RC=9 "$LAYOUT_SCRIPT" apply --count 3 --cwd "$TEST_TMP" 2>&1 >/dev/null)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || {
    printf 'expected a non-zero exit for a rejected split\n' >&2
    return 1
  }
  case "$error" in
    *'pane split failed'*) ;;
    *)
      printf 'expected a split failure report, got: %s\n' "$error" >&2
      return 1
      ;;
  esac
  [ "$(grep -c '^pane split ' "$HERDR_TEST_LAYOUT_CALLS")" -eq 1 ]
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

expected_count=26

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
run_test pane_layout_plan_grids
run_test pane_layout_plan_new_tabs
run_test pane_layout_plan_geometry
run_test pane_layout_plan_is_pure
run_test pane_layout_plan_rejects_bad_input
run_test pane_layout_apply_current_tab
run_test pane_layout_apply_new_tabs
run_test pane_layout_apply_stops_on_mismatch
run_test markdown_links_resolve

[ "$pass_count" -eq "$expected_count" ] || {
  printf 'FAIL: expected %s tests, got %s\n' "$expected_count" "$pass_count" >&2
  exit 1
}

printf 'PASS: %s Herdr async wrapper tests\n' "$pass_count"
