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
write_pi_session() { # path mode provider model thinking
  local session_path="$1" session_mode="$2" provider="$3" model="$4" thinking="$5"
  local record_provider record_model record_thinking
  case "$session_mode" in
    provider-mismatch) record_provider='other-provider'; record_model="$model"; record_thinking="$thinking" ;;
    model-mismatch) record_provider="$provider"; record_model='other-model'; record_thinking="$thinking" ;;
    thinking-mismatch) record_provider="$provider"; record_model="$model"; record_thinking='low' ;;
    first-mismatch-later-match) record_provider='other-provider'; record_model="$model"; record_thinking="$thinking" ;;
    first-thinking-mismatch-later-match) record_provider="$provider"; record_model="$model"; record_thinking='low' ;;
    *) record_provider="$provider"; record_model="$model"; record_thinking="$thinking" ;;
  esac
  case "$session_mode" in
    empty) : > "$session_path"; return 0 ;;
    invalid) printf 'not json\n' > "$session_path"; return 0 ;;
    broken-initial)
      printf '{"type":"session"}\n{"type":"model_change","provider":"%s"\n{"type":"thinking_level_change","thinkingLevel":"%s"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n' \
        "$provider" "$thinking" "$provider" "$model" > "$session_path"
      return 0
      ;;
    multi-value)
      printf '{"type":"session"}\n{"type":"model_change","provider":"other-provider","modelId":"other-model"}{"type":"model_change","provider":"other-provider","modelId":"other-model"}\n{"type":"thinking_level_change","thinkingLevel":"%s"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n' \
        "$thinking" "$provider" "$model" > "$session_path"
      return 0
      ;;
    initial-then-message)
      printf '{"type":"session"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n{"type":"message","text":"conversation"}\n{"type":"thinking_level_change","thinkingLevel":"%s"}\n' \
        "$provider" "$model" "$thinking" > "$session_path"
      return 0
      ;;
    initial-then-custom-message)
      printf '{"type":"session"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n{"type":"custom_message","content":"conversation"}\n{"type":"thinking_level_change","thinkingLevel":"%s"}\n' \
        "$provider" "$model" "$thinking" > "$session_path"
      return 0
      ;;
    partial)
      printf '{"type":"session"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n' \
        "$record_provider" "$record_model" > "$session_path"
      return 0
      ;;
    no-write) return 0 ;;
  esac
  printf '{"type":"session"}\n{"type":"model_change","provider":"%s","modelId":"%s"}\n{"type":"thinking_level_change","thinkingLevel":"%s"}\n' \
    "$record_provider" "$record_model" "$record_thinking" > "$session_path"
  case "$session_mode" in
    first-match-later-mismatch)
      printf '{"type":"model_change","provider":"other-provider","modelId":"other-model"}\n{"type":"thinking_level_change","thinkingLevel":"low"}\n' >> "$session_path"
      ;;
    first-mismatch-later-match)
      printf '{"type":"model_change","provider":"%s","modelId":"%s"}\n' "$provider" "$model" >> "$session_path"
      ;;
    first-thinking-mismatch-later-match)
      printf '{"type":"thinking_level_change","thinkingLevel":"%s"}\n' "$thinking" >> "$session_path"
      ;;
  esac
  return 0
}
case "${1:-}" in
  pane)
    case "${2:-}" in
      get)
        # The parent pane keeps its own fixture, so the display-name tests can
        # vary its label. Any other pane is described from HERDR_TEST_PANE_CWD
        # (unset means the test's cwd), and carries the Pi session record the
        # fake start wrote for it.
        if [ "${3:-}" = "$HERDR_PANE_ID" ]; then
          cat "$HERDR_TEST_PANE_JSON"
          exit 0
        fi
        if [ -n "${HERDR_TEST_PI_SESSION_PATH_DELAY:-}" ]; then
          # Keep the pipe closed to the launcher even if the fake is killed by
          # timeout; a child holding stdout would defeat the test's deadline.
          sleep "$HERDR_TEST_PI_SESSION_PATH_DELAY" >/dev/null 2>&1
        fi
        pane_cwd="${HERDR_TEST_PANE_CWD-$PWD}"
        session_kind="${HERDR_TEST_PI_SESSION_KIND:-path}"
        safe_pane="${3:-}"
        safe_pane="${safe_pane//[^[:alnum:]_.-]/_}"
        session_path_file="$HERDR_TEST_STATE/pi-session-${safe_pane}"
        session_field=''
        if [ "$session_kind" = path ] && [ -s "$session_path_file" ]; then
          session_field=",\"agent_session\":{\"agent\":\"pi\",\"kind\":\"path\",\"value\":\"$(cat "$session_path_file")\"}"
        elif [ "$session_kind" = id ]; then
          session_field=',"agent_session":{"agent":"pi","kind":"id","value":"session-id"}'
        elif [ "$session_kind" = empty ]; then
          session_field=',"agent_session":{"agent":"pi","kind":"path","value":""}'
        fi
        if [ "${HERDR_TEST_PANE_NO_FOREGROUND:-0}" = 1 ]; then
          printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","cwd":"%s"%s}},"type":"pane_info"}\n' \
            "${3:-}" "$pane_cwd" "$session_field"
        elif [ "${HERDR_TEST_PANE_EMPTY_FOREGROUND:-0}" = 1 ]; then
          printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":""%s}},"type":"pane_info"}\n' \
            "${3:-}" "$pane_cwd" "$session_field"
        else
          printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"%s}},"type":"pane_info"}\n' \
            "${3:-}" "$pane_cwd" "$pane_cwd" "$session_field"
        fi
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
        # Written to the caller's stderr so an ordering test can prove the
        # launcher printed its probe and launch lines before it started.
        if [ -n "${HERDR_TEST_START_MARKER:-}" ]; then
          printf '%s\n' "$HERDR_TEST_START_MARKER" >&2
        fi
        # Simulate the launched session's statusline: the launcher installs a
        # statusLine command in its settings file, and this fake runs that
        # command with a fabricated statusline document. Without it nothing
        # would ever write the probe the launcher waits for, and no real Claude
        # CLI is started by this test suite.
        settings=''
        kind=''
        pane=''
        provider=''
        model=''
        effort=''
        thinking=''
        shift 2
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --settings) settings="${2:-}"; shift 2 || shift ;;
            --kind) kind="${2:-}"; shift 2 || shift ;;
            --pane) pane="${2:-}"; shift 2 || shift ;;
            --provider) provider="${2:-}"; shift 2 || shift ;;
            --model) model="${2:-}"; shift 2 || shift ;;
            --effort) effort="${2:-}"; shift 2 || shift ;;
            --thinking) thinking="${2:-}"; shift 2 || shift ;;
            *) shift ;;
          esac
        done
        statusline="${HERDR_TEST_STATUSLINE:-}"
        if [ -n "$settings" ] && [ -s "$settings" ] && [ -n "$statusline" ] && [ "$statusline" != none ]; then
          command="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)" || command=''
          case "$statusline" in
            match) document="{\"model\":{\"id\":\"$model\"},\"effort\":{\"level\":\"$effort\"}}" ;;
            alias) document="{\"model\":{\"id\":\"claude-haiku-5-5\"},\"effort\":{\"level\":\"$effort\"}}" ;;
            bad-model) document="{\"model\":{\"id\":\"claude-other-9\"},\"effort\":{\"level\":\"$effort\"}}" ;;
            bad-effort) document="{\"model\":{\"id\":\"$model\"},\"effort\":{\"level\":\"low\"}}" ;;
            no-effort) document="{\"model\":{\"id\":\"$model\"}}" ;;
            no-model) document="{\"effort\":{\"level\":\"$effort\"}}" ;;
            *) document='{}' ;;
          esac
          if [ -n "$command" ]; then
            printf '%s' "$document" | bash -c "$command" >/dev/null 2>&1 || true
          fi
          if [ "$statusline" = stale-nonce ]; then
            # A record from another launch in the same pane: the launcher must
            # reject it instead of reporting those values as its own.
            for probe in "${TMPDIR:-/tmp}"/agent-harness/claude-spec/*.json; do
              [ -s "$probe" ] || continue
              case "$probe" in *.settings.json) continue ;; esac
              jq -c '.nonce = "forged"' "$probe" > "$probe.tmp" 2>/dev/null && mv "$probe.tmp" "$probe"
            done
          fi
        fi
        if [ "$kind" = pi ] && [ -n "$pane" ]; then
          # Simulate the session record Pi writes. The launcher reads the first
          # model_change and thinking_level_change, so a later change must not
          # win; the mode lets a test make the first entry wrong, the record
          # late, or the path unusable.
          session_mode="${HERDR_TEST_PI_SESSION_MODE:-match}"
          safe_pane="${pane//[^[:alnum:]_.-]/_}"
          session_dir="$HERDR_TEST_STATE/pi-sessions"
          mkdir -p -- "$session_dir"
          session_path="$session_dir/${safe_pane}.jsonl"
          rm -f -- "$session_path"
          printf '%s|%s|%s|%s|%s\n' "$provider" "$model" "$thinking" "$pane" "$session_mode" \
            > "$HERDR_TEST_STATE/pi-start-${safe_pane}"
          if [ "$session_mode" = on-prompt ] || [ "$session_mode" = on-prompt-late ]; then
            # Pi creates the record on the first turn; the launcher's startup
            # probe is what makes it appear in this mode. `on-prompt-late`
            # delays the write to test the shared deadline.
            printf '%s\n' "$session_path" > "$HERDR_TEST_STATE/pi-session-${safe_pane}"
          elif [ "$session_mode" = late ]; then
            printf '%s\n' "$session_path" > "$HERDR_TEST_STATE/pi-session-${safe_pane}"
            ( sleep 0.3; write_pi_session "$session_path" "$session_mode" "$provider" "$model" "$thinking" ) &
          else
            # Publish the path only after the record is complete, so a test
            # that expects an unreadable or empty record is not racing the
            # launcher's first read.
            write_pi_session "$session_path" "$session_mode" "$provider" "$model" "$thinking"
            printf '%s\n' "$session_path" > "$HERDR_TEST_STATE/pi-session-${safe_pane}"
          fi
        fi
        exit "${HERDR_TEST_START_RC:-0}"
        ;;
      wait)
        printf '%s\n' "$*" >> "$HERDR_TEST_WAITS"
        printf '{"id":"cli:agent:wait","result":{"agent":{"agent":"claude","agent_status":"%s","pane_id":"%s"},"type":"agent_info"}}\n' \
          "${HERDR_TEST_AGENT_STATUS:-idle}" "${3:-}"
        exit "${HERDR_TEST_WAIT_RC:-0}"
        ;;
      prompt)
        shift 2
        [ "$#" -eq 2 ] || exit 91
        printf '%s' "$1" > "$HERDR_TEST_TARGET"
        printf '%s' "$2" > "$HERDR_TEST_MESSAGE"
        for arg in "$@"; do [ "$arg" = --wait ] && exit 92; done
        safe_pane="${1//[^[:alnum:]_.-]/_}"
        start_file="$HERDR_TEST_STATE/pi-start-${safe_pane}"
        if [ -s "$start_file" ]; then
          IFS='|' read -r start_provider start_model start_thinking start_pane start_mode \
            <<< "$(cat "$start_file")"
          if [ "$start_mode" = on-prompt ] || [ "$start_mode" = on-prompt-late ]; then
            session_path="$HERDR_TEST_STATE/pi-sessions/${safe_pane}.jsonl"
            if [ "$start_mode" = on-prompt-late ]; then
              sleep "${HERDR_TEST_PI_SESSION_LATE_DELAY:-0.3}"
            fi
            write_pi_session "$session_path" match "$start_provider" "$start_model" "$start_thinking"
          fi
        fi
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

# Fake Claude CLI. The launcher's preflight runs
# scripts/pi-development/claude-auth-status.sh, which calls `claude auth
# status`; the helper is real, the CLI is not. Every other subcommand fails, so
# a launcher that started a real session would be caught here.
cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_TEST_CLAUDE_CALLS"
case "${1:-} ${2:-}" in
  'auth status')
    # Mirrors 2.1.328: an explicit CLAUDE_CONFIG_DIR is reported as is, and the
    # default is <home>/.claude, while the state file stays at <home>/.claude.json.
    config_directory="${HERDR_TEST_CLAUDE_CONFIG_DIR:-${HERDR_TEST_CLAUDE_HOME}/.claude}"
    if [ "${HERDR_TEST_CLAUDE_LOGGED_IN:-true}" = true ]; then
      printf '{"loggedIn":true,"configDirectory":"%s","authMethod":"oauth","email":"never-printed@example.invalid"}\n' \
        "$config_directory"
      exit 0
    fi
    printf '{"loggedIn":false,"configDirectory":"%s","authMethod":"none"}\n' \
      "$config_directory"
    exit 1
    ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$MOCK_BIN/claude"

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
export HERDR_TEST_CLAUDE_CALLS="$MOCK_LOG/claude-calls"
# The fake `claude auth status` reports $HERDR_TEST_CLAUDE_HOME/.claude unless
# HERDR_TEST_CLAUDE_CONFIG_DIR names an explicit config directory.
export HERDR_TEST_CLAUDE_HOME="$TEST_TMP/claude-home"
mkdir -p "$HERDR_TEST_CLAUDE_HOME"
# The launcher derives its probe directory from TMPDIR, so the suite keeps it
# inside the temporary tree instead of the shared /tmp.
export TMPDIR="$TEST_TMP/tmp"
mkdir -p "$TMPDIR"
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
: > "$HERDR_TEST_CLAUDE_CALLS"
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
  : > "$HERDR_TEST_CLAUDE_CALLS"
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

  # A workspace without worktree information (wF) is not covered by a
  # --target-repo grant whose source is the repository-side workspace: the
  # classifier matches the grant against the repo_root the counterpart side
  # reports, and wF reports none. The wG repo grant above is active here.
  reset_logs
  expect_scope_reject repo-mismatch "$PARENT_SCRIPT" wF:p2 'prompt'
  expect_scope_reject repo-mismatch env HERDR_WORKSPACE_ID=wF HERDR_PANE_ID=wF:p1 \
    "$CHILD_SCRIPT" wG:p2 completed 'body'
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^agent prompt' "$HERDR_TEST_CALLS"

  # The same --target-repo grant covers both directions once the plain
  # workspace is its source: then the counterpart side reports the granted
  # repo_root, from either end of the edge.
  rm -f "$HERDR_SCOPE_FILE"
  "$GRANT_SCRIPT" grant --source wF --target-repo "$REPO_ALPHA" --by reviewer --task '#270' >/dev/null
  reset_logs
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wF:p2 'plain-source repo grant'
  assert_file_eq wF:p2 "$HERDR_TEST_TARGET"
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wF HERDR_PANE_ID=wF:p1 \
    "$CHILD_SCRIPT" wG:p2 completed 'plain-source repo grant return'
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"

  # A pair grant on the workspace IDs covers the same edge in both
  # directions without any repository knowledge.
  rm -f "$HERDR_SCOPE_FILE"
  "$GRANT_SCRIPT" grant --source wG --target wF --by reviewer --task '#270' >/dev/null
  reset_logs
  HERDR_TEST_RC=0 "$PARENT_SCRIPT" wF:p2 'pair grant'
  assert_file_eq wF:p2 "$HERDR_TEST_TARGET"
  reset_logs
  HERDR_TEST_RC=0 env HERDR_WORKSPACE_ID=wF HERDR_PANE_ID=wF:p1 \
    "$CHILD_SCRIPT" wG:p2 completed 'pair grant return'
  assert_file_eq wG:p2 "$HERDR_TEST_TARGET"

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

# Fixtures for the profile mode of worktree-team-start.sh. Every profile lives
# under a temporary PI_CODING_AGENT_DIR, so the real user profiles are never
# read, and --resolver replaces the model-spec resolver (always an absolute
# path, as the script passes it through unchanged).
profile_home() { # <tag> -> prints the temporary agent dir
  local home="$TEST_TMP/pi-agent-$1"
  mkdir -p "$home/pi-development/profiles"
  printf '%s' "$home"
}

write_profile_fixture() { # <agent-dir> <name> <json>
  printf '%s\n' "$3" > "$1/pi-development/profiles/$2.json"
}

write_profile_resolvers() {
  # Both stubs answer only a harness-aware call: team-record.sh must name the
  # harness, so a producer that stopped doing so would fail here instead of
  # silently resolving through the wrong grammar.
  cat > "$TEST_TMP/resolver-ok.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != --harness ]; then
  printf 'result=unknown\n'
  exit 1
fi
case "${2:-}" in
  pi) printf 'harness=pi provider=stub model=stub requested=high supported=high effective=high result=ok verification=exact thinking_level_map={}\n' ;;
  claude) printf 'harness=claude provider= model=stub requested=high supported= effective= result=ok verification=postlaunch permission_mode=auto\n' ;;
  *) printf 'result=unknown\n'; exit 1 ;;
esac
STUB
  cat > "$TEST_TMP/resolver-marker.sh" <<STUB
#!/usr/bin/env bash
printf 'called\n' >> "$TEST_TMP/resolver-calls"
if [ "\${1:-}" != --harness ]; then
  printf 'result=unknown\n'
  exit 1
fi
printf 'harness=%s result=ok verification=postlaunch\n' "\${2:-}"
STUB
  chmod +x "$TEST_TMP/resolver-ok.sh" "$TEST_TMP/resolver-marker.sh"
}

# Fixtures for the Claude paths of the shared launcher. The trusted directory is
# the only one a state file approves; the fake `claude auth status` answers with
# $HERDR_TEST_CLAUDE_CONFIG_DIR when it is set and with
# $HERDR_TEST_CLAUDE_HOME/.claude otherwise, so both state-file locations are
# exercised without a real CLI or a real user profile.
LAUNCHER="$HERDR_DIR/scripts/start-agent.sh"
CLAUDE_TRUSTED_DIR="$TEST_TMP/claude-worktree"
CLAUDE_UNTRUSTED_DIR="$TEST_TMP/claude-worktree-untrusted"
mkdir -p "$CLAUDE_TRUSTED_DIR" "$CLAUDE_UNTRUSTED_DIR"

write_claude_trust() { # <config-dir> <approved-path>
  mkdir -p "$1"
  printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$(realpath -m -- "$2")" > "$1/.claude.json"
}

# An explicit CLAUDE_CONFIG_DIR fixture and a default config-home fixture. Both
# approve only $CLAUDE_TRUSTED_DIR, so the two state-file locations can be
# exercised independently.
CLAUDE_EXPLICIT_CONFIG_DIR="$TEST_TMP/claude-config"
write_claude_trust "$CLAUDE_EXPLICIT_CONFIG_DIR" "$CLAUDE_TRUSTED_DIR"
write_claude_trust "$HERDR_TEST_CLAUDE_HOME" "$CLAUDE_TRUSTED_DIR"

claude_config_dir() { # <tag> -> prints a fresh, unapproved config directory
  local dir="$TEST_TMP/claude-config-$1"
  mkdir -p "$dir"
  rm -f "$dir/.claude.json"
  printf '%s' "$dir"
}

# Line number of the first match, or nothing.
line_of() { # <text> <pattern>
  printf '%s\n' "$1" | grep -n "$2" | head -n 1 | cut -d: -f1
}

worktree_team_start_profile_mode() {
  local task_file="$TEST_TMP/profile-task.md" home launch err
  printf '%s\n' 'Goal: coordinate the worktree team' 'Acceptance: the team reports back' > "$task_file"
  write_profile_resolvers

  home="$(profile_home default)"
  write_profile_fixture "$home" default '{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "impl-provider", "model": "impl-model", "thinking": "high"},
    "review": {"provider": "review-provider", "model": "review-model", "thinking": "medium"},
    "pr-fix": {"provider": "impl-provider", "model": "impl-model", "thinking": "high"},
    "orchestrator": {"provider": "openrouter", "model": "anthropic/claude-x", "thinking": "max"}
  }
}'
  write_profile_fixture "$home" crew '{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "impl-provider", "model": "impl-model", "thinking": "high"},
    "review": {"provider": "review-provider", "model": "review-model", "thinking": "medium"},
    "pr-fix": {"provider": "impl-provider", "model": "impl-model", "thinking": "high"},
    "orchestrator": {"provider": "openai-codex", "model": "gpt-6.1-sol", "thinking": "high"}
  }
}'

  # The default profile supplies all three flags; the task text stays intact and
  # the launch line is appended before the wrapper's return instruction.
  reset_logs
  err="$(HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --resolver "$TEST_TMP/resolver-ok.sh" "$task_file" 2>&1 >/dev/null)"
  [ "$(wc -l < "$HERDR_TEST_STARTS")" -eq 1 ]
  grep -Fqx 'agent start orchestrator --kind pi --pane wB:p2 --timeout 60000 -- --provider openrouter --model anthropic/claude-x --thinking max' "$HERDR_TEST_STARTS"
  [ "$(wc -l < "$HERDR_TEST_WAITS")" -eq 1 ]
  grep -Fqx 'wB:p2 orchestrator' "$HERDR_TEST_RENAMES"
  launch='launch: profile=default role=orchestrator harness=pi spec=pi:openrouter/anthropic/claude-x/max spec_source=profile origin=default'
  grep -Fqx "$launch" <<< "$err"
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  grep -Fq 'Goal: coordinate the worktree team' "$HERDR_TEST_MESSAGE"
  [ "$(grep -c '^launch: ' "$HERDR_TEST_MESSAGE")" -eq 1 ]
  grep -Fqx "$launch" "$HERDR_TEST_MESSAGE"
  awk '/^launch: /{ l=NR } /Direct parent pane for result return/{ r=NR } END { exit !(l && r && l < r) }' "$HERDR_TEST_MESSAGE"

  # --profile selects another profile and reports source=explicit.
  reset_logs
  err="$(HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --profile crew --resolver "$TEST_TMP/resolver-ok.sh" "$task_file" 2>&1 >/dev/null)"
  grep -Fqx 'agent start orchestrator --kind pi --pane wB:p2 --timeout 60000 -- --provider openai-codex --model gpt-6.1-sol --thinking high' "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=crew role=orchestrator harness=pi spec=pi:openai-codex/gpt-6.1-sol/high spec_source=profile origin=explicit' <<< "$err"

  # active selects the profile when --profile is absent.
  printf 'crew\n' > "$home/pi-development/active"
  reset_logs
  err="$(HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --resolver "$TEST_TMP/resolver-ok.sh" "$task_file" 2>&1 >/dev/null)"
  grep -Fqx 'launch: profile=crew role=orchestrator harness=pi spec=pi:openai-codex/gpt-6.1-sol/high spec_source=profile origin=active' <<< "$err"
  rm -f "$home/pi-development/active"

  # The explicit mode reads no profile at all, even when none exists.
  reset_logs
  err="$(HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$TEST_TMP/no-such-pi-agent" "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file" 2>&1 >/dev/null)"
  grep -Fqx 'agent start impl --kind pi --pane wB:p2 --timeout 60000 -- --provider anthropic --model claude-sonnet-4-5 --thinking high' "$HERDR_TEST_STARTS"
  launch='launch: profile=- role=- harness=pi spec=pi:anthropic/claude-sonnet-4-5/high spec_source=explicit origin=explicit'
  grep -Fqx "$launch" <<< "$err"
  grep -Fqx "$launch" "$HERDR_TEST_MESSAGE"
}

worktree_team_start_profile_failures() {
  local task_file="$TEST_TMP/profile-error-task.md" home empty_home fake_root
  local claude_home claude_task claude_err rc_claude unknown_err rc_unknown
  local legacy_err pi_err
  printf '%s\n' 'Goal: fail closed' > "$task_file"
  write_profile_resolvers

  home="$(profile_home errors)"
  write_profile_fixture "$home" default '{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "p", "model": "m", "thinking": "high"},
    "review": {"provider": "p", "model": "m", "thinking": "high"},
    "pr-fix": {"provider": "p", "model": "m", "thinking": "high"}
  }
}'

  # An explicitly empty option value is a usage error, not an omitted option.
  # The active profile here has an orchestrator, so `--profile ""` would
  # otherwise resolve that profile and start an agent (the Round 1 finding).
  empty_home="$(profile_home empty-options)"
  write_profile_fixture "$empty_home" default '{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "p", "model": "m", "thinking": "high"},
    "review": {"provider": "p", "model": "m", "thinking": "high"},
    "pr-fix": {"provider": "p", "model": "m", "thinking": "high"},
    "orchestrator": {"provider": "p", "model": "orch", "thinking": "max"}
  }
}'
  printf 'default\n' > "$empty_home/pi-development/active"
  reset_logs
  rm -f "$TEST_TMP/resolver-calls"
  expect_rc 2 env PI_CODING_AGENT_DIR="$empty_home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --profile "" --resolver "$TEST_TMP/resolver-marker.sh" "$task_file"
  expect_rc 2 env PI_CODING_AGENT_DIR="$empty_home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --provider "" --resolver "$TEST_TMP/resolver-marker.sh" "$task_file"
  expect_rc 2 env PI_CODING_AGENT_DIR="$empty_home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --resolver "" "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --role "" \
    --provider p --model m --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider "" --model m --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider p --model "" --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider p --model m --thinking "" "$task_file"
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]
  [ ! -e "$TEST_TMP/resolver-calls" ]

  # Mode combinations fail closed with a usage status and start nothing.
  reset_logs
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --role orchestrator --provider p --model m --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --role orchestrator --provider p "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider p "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --provider p --model m "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --thinking high "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --profile default "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl --resolver "$TEST_TMP/resolver-ok.sh" "$task_file"
  expect_rc 2 "$START_SCRIPT" wB:p2 impl "$task_file"
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # An unknown role keeps team-record's usage status and starts nothing.
  reset_logs
  expect_rc 2 env PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 impl \
    --role reviewer --resolver "$TEST_TMP/resolver-ok.sh" "$task_file"
  [ ! -s "$HERDR_TEST_STARTS" ]

  # A profile without the role fails closed, and a missing explicit profile
  # never falls back to active or default.
  reset_logs
  expect_rc 1 env PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --resolver "$TEST_TMP/resolver-ok.sh" "$task_file"
  expect_rc 1 env PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --profile ghost --resolver "$TEST_TMP/resolver-ok.sh" "$task_file"
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # The scope check runs before profile resolution: a rejected edge exits 3
  # and the resolver is never called.
  reset_logs
  rm -f "$TEST_TMP/resolver-calls"
  expect_scope_reject repo-mismatch env PI_CODING_AGENT_DIR="$home" \
    "$START_SCRIPT" wE:p2 orchestrator --role orchestrator \
    --resolver "$TEST_TMP/resolver-marker.sh" "$task_file"
  [ ! -e "$TEST_TMP/resolver-calls" ]
  [ ! -s "$HERDR_TEST_STARTS" ]

  # A team-record that prints no record is this script's own error (exit 1),
  # and the helper path comes from the script location, not the caller's cwd.
  fake_root="$TEST_TMP/fake-package"
  rm -rf "$fake_root"
  mkdir -p "$fake_root/herdr" "$fake_root/scripts/pi-development"
  cp -R "$HERDR_DIR/scripts" "$fake_root/herdr/scripts"
  # lib/role-spec.mjs imports the shared grammar, so the fake package needs the
  # same library tree as the real one.
  cp -R "$HERDR_DIR/../scripts/pi-development/lib" "$fake_root/scripts/pi-development/lib"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_root/scripts/pi-development/team-record.sh"
  chmod +x "$fake_root/scripts/pi-development/team-record.sh"
  reset_logs
  (cd "$TEST_TMP" && expect_rc 1 env PI_CODING_AGENT_DIR="$home" \
    "$fake_root/herdr/scripts/worktree-team-start.sh" wB:p2 orchestrator --role orchestrator "$task_file")
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # A record without the resolved role key is also this script's error.
  cat > "$fake_root/scripts/pi-development/team-record.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'command=resolve profile=default source=default present=true result=ok\n'
exit 0
FAKE
  chmod +x "$fake_root/scripts/pi-development/team-record.sh"
  reset_logs
  (cd "$TEST_TMP" && expect_rc 1 env PI_CODING_AGENT_DIR="$home" \
    "$fake_root/herdr/scripts/worktree-team-start.sh" wB:p2 orchestrator --role orchestrator "$task_file")
  [ ! -s "$HERDR_TEST_STARTS" ]

  # A stored Claude role resolves to a `claude:` specification and stops before
  # any herdr call while the workspace is untrusted, so the profile path can
  # never start a harness it cannot verify. The successful profile start is
  # covered by worktree_team_start_claude_mode.
  local claude_home claude_task claude_err
  claude_home="$(profile_home claude)"
  claude_task="$TEST_TMP/claude-task.md"
  printf '%s\n' 'Goal: a claude orchestrator' > "$claude_task"
  write_profile_fixture "$claude_home" default '{
  "pr_fix_shared_with_impl": false,
  "roles": {
    "impl": {"provider": "p", "model": "m", "thinking": "high"},
    "review": {"provider": "p", "model": "m", "thinking": "high"},
    "pr-fix": {"provider": "p", "model": "m", "thinking": "high"},
    "orchestrator": {"harness": "claude", "model": "claude-haiku-5-5", "effort": "high", "permission_mode": "auto"}
  }
}'
  reset_logs
  set +e
  claude_err="$(HERDR_TEST_RC=0 HERDR_TEST_PANE_CWD="$CLAUDE_UNTRUSTED_DIR" \
    PI_CODING_AGENT_DIR="$claude_home" "$START_SCRIPT" wB:p2 orchestrator \
    --role orchestrator --resolver "$TEST_TMP/resolver-ok.sh" "$claude_task" 2>&1 >/dev/null)"
  rc_claude=$?
  set -e
  [ "$rc_claude" -eq 1 ]
  grep -Fq "claude-trust: $CLAUDE_UNTRUSTED_DIR が未承認です" <<< "$claude_err"
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -s "$HERDR_TEST_WAITS" ]
  [ ! -e "$HERDR_TEST_TARGET" ]

  # An unknown harness prefix is rejected too, rather than read as a provider.
  cat > "$fake_root/scripts/pi-development/team-record.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'command=resolve profile=default source=default present=true result=ok orchestrator=codex:model/high\n'
exit 0
FAKE
  chmod +x "$fake_root/scripts/pi-development/team-record.sh"
  reset_logs
  set +e
  unknown_err="$( (cd "$TEST_TMP" && HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" \
    "$fake_root/herdr/scripts/worktree-team-start.sh" wB:p2 orchestrator --role orchestrator "$task_file") 2>&1 >/dev/null)"
  rc_unknown=$?
  set -e
  [ "$rc_unknown" -eq 1 ]
  grep -Fq 'not a usable role specification: codex:model/high' <<< "$unknown_err"
  [ ! -s "$HERDR_TEST_STARTS" ]

  # A legacy unprefixed spec from an older producer still launches, and the
  # shared launcher prints it as the canonical prefixed specification.
  cat > "$fake_root/scripts/pi-development/team-record.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'command=resolve profile=default source=default present=true result=ok orchestrator=openrouter/anthropic/claude-x/max\n'
exit 0
FAKE
  chmod +x "$fake_root/scripts/pi-development/team-record.sh"
  reset_logs
  legacy_err="$( (cd "$TEST_TMP" && HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" \
    "$fake_root/herdr/scripts/worktree-team-start.sh" wB:p2 orchestrator --role orchestrator "$task_file") 2>&1 >/dev/null)"
  grep -Fqx 'agent start orchestrator --kind pi --pane wB:p2 --timeout 60000 -- --provider openrouter --model anthropic/claude-x --thinking max' "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=default role=orchestrator harness=pi spec=pi:openrouter/anthropic/claude-x/max spec_source=profile origin=default' <<< "$legacy_err"

  # A `pi:` prefixed spec from the current producer launches the same way.
  cat > "$fake_root/scripts/pi-development/team-record.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'command=resolve profile=default source=default present=true result=ok orchestrator=pi:openrouter/anthropic/claude-x/max\n'
exit 0
FAKE
  chmod +x "$fake_root/scripts/pi-development/team-record.sh"
  reset_logs
  pi_err="$( (cd "$TEST_TMP" && HERDR_TEST_RC=0 PI_CODING_AGENT_DIR="$home" \
    "$fake_root/herdr/scripts/worktree-team-start.sh" wB:p2 orchestrator --role orchestrator "$task_file") 2>&1 >/dev/null)"
  grep -Fqx 'agent start orchestrator --kind pi --pane wB:p2 --timeout 60000 -- --provider openrouter --model anthropic/claude-x --thinking max' "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=default role=orchestrator harness=pi spec=pi:openrouter/anthropic/claude-x/max spec_source=profile origin=default' <<< "$pi_err"
  [ "$(wc -l < "$HERDR_TEST_STARTS")" -eq 1 ]
}

shared_launcher_pi_arguments() {
  local err marker

  # Explicit mode: the flags become the canonical specification, the launch line
  # precedes the start, and the launcher's effective line follows the start.
  reset_logs
  marker='agent-start-marker'
  err="$(HERDR_TEST_START_MARKER="$marker" "$LAUNCHER" wB:p2 impl \
    --harness pi --provider openrouter --model anthropic/claude-x --thinking max 2>&1 >/dev/null)"
  grep -Fqx 'agent start impl --kind pi --pane wB:p2 --timeout 60000 -- --provider openrouter --model anthropic/claude-x --thinking max' "$HERDR_TEST_STARTS"
  grep -Fqx 'agent wait wB:p2 --until idle --until done --until blocked --timeout 60000' "$HERDR_TEST_WAITS"
  grep -Fqx 'launch: profile=- role=- harness=pi spec=pi:openrouter/anthropic/claude-x/max spec_source=explicit origin=explicit' <<< "$err"
  grep -Fqx 'effective: harness=pi provider=openrouter model=anthropic/claude-x effort=- thinking=max permission_requested=- requested=pi:openrouter/anthropic/claude-x/max' <<< "$err"
  [ "$(line_of "$err" '^launch: ')" -lt "$(line_of "$err" '^agent-start-marker$')" ]
  [ "$(line_of "$err" '^agent-start-marker$')" -lt "$(line_of "$err" '^effective: ')" ]
  ! grep -q '^probe: ' <<< "$err"

  # A canonical specification from a profile and a legacy unprefixed value are
  # parsed by the shared grammar and launched with the same three flags.
  reset_logs
  err="$("$LAUNCHER" wB:p2 impl --spec 'pi:opencode-go/deepseek-v4.1-flash/max' \
    --profile crew --role impl --spec-source profile --origin active 2>&1 >/dev/null)"
  grep -Fqx 'agent start impl --kind pi --pane wB:p2 --timeout 60000 -- --provider opencode-go --model deepseek-v4.1-flash --thinking max' "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=crew role=impl harness=pi spec=pi:opencode-go/deepseek-v4.1-flash/max spec_source=profile origin=active' <<< "$err"

  reset_logs
  err="$("$LAUNCHER" wB:p2 impl --spec 'openrouter/anthropic/claude-x/max' 2>&1 >/dev/null)"
  grep -Fqx 'agent start impl --kind pi --pane wB:p2 --timeout 60000 -- --provider openrouter --model anthropic/claude-x --thinking max' "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=- role=- harness=pi spec=pi:openrouter/anthropic/claude-x/max spec_source=explicit origin=explicit' <<< "$err"

  # A model ID may contain `/`: the provider is the first segment and the
  # thinking level the last one.
  reset_logs
  err="$("$LAUNCHER" wB:p2 impl --harness pi --provider openrouter --model 'anthropic/claude-x' --thinking high 2>&1 >/dev/null)"
  grep -Fqx 'launch: profile=- role=- harness=pi spec=pi:openrouter/anthropic/claude-x/high spec_source=explicit origin=explicit' <<< "$err"

  # Mixed, partial, and other-harness flags are usage errors that start nothing.
  reset_logs
  expect_rc 2 "$LAUNCHER" wB:p2 impl --harness pi --model m --effort high --permission-mode auto
  expect_rc 2 "$LAUNCHER" wB:p2 impl --provider p --model m
  expect_rc 2 "$LAUNCHER" wB:p2 impl --harness claude --model m --thinking high
  expect_rc 2 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --provider p
  expect_rc 2 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --model m
  expect_rc 2 "$LAUNCHER" wB:p2 impl --spec ''
  expect_rc 2 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --harness codex
  expect_rc 2 "$LAUNCHER" wB:p2 impl
  expect_rc 2 "$LAUNCHER" wB:p2
  [ ! -s "$HERDR_TEST_STARTS" ]

  # A usable argument shape with an unusable value is exit 1, not usage.
  expect_rc 1 "$LAUNCHER" wB:p2 impl --provider p --model m --thinking extreme
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'codex:model/high'
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'claude:claude-haiku-5-5/minimal/auto'
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'claude:claude-haiku-5-5/high/bypassPermissions'
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --harness claude
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --timeout 0
  expect_rc 1 "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high' --probe-timeout 400000
  expect_rc 1 "$LAUNCHER" bad-pane impl --spec 'pi:p/m/high'
  expect_rc 1 "$LAUNCHER" wB:p2 'bad name' --spec 'pi:p/m/high'
  [ ! -s "$HERDR_TEST_STARTS" ]
  [ ! -s "$HERDR_TEST_WAITS" ]

  # A blocked readiness state stops before anything else happens.
  reset_logs
  expect_rc 1 env HERDR_TEST_AGENT_STATUS=blocked \
    "$LAUNCHER" wB:p2 impl --spec 'pi:p/m/high'
  [ -s "$HERDR_TEST_STARTS" ]
}

shared_launcher_pi_effective() {
  local err rc mode kind

  # The launcher reads the session record, not the agent's environment, so a
  # matching record is enough even when $PI_* is absent.
  reset_logs
  err="$(HERDR_TEST_PI_SESSION_MODE=match "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  grep -Fqx 'effective: harness=pi provider=openai-codex model=gpt-6.2-sol effort=- thinking=max permission_requested=- requested=pi:openai-codex/gpt-6.2-sol/max' <<< "$err"

  # Pi writes the record only on its first turn; the launcher's startup probe
  # makes it appear before the task is delegated.
  reset_logs
  err="$(HERDR_TEST_PI_SESSION_MODE=on-prompt "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  grep -Fqx 'effective: harness=pi provider=openai-codex model=gpt-6.2-sol effort=- thinking=max permission_requested=- requested=pi:openai-codex/gpt-6.2-sol/max' <<< "$err"
  grep -Fq 'Startup check from the shared launcher' "$HERDR_TEST_MESSAGE"
  # A mismatch in any of the three launch values stops before delegating.
  for mode in provider-mismatch model-mismatch thinking-mismatch; do
    reset_logs
    set +e
    err="$(HERDR_TEST_PI_SESSION_MODE="$mode" "$LAUNCHER" wB:p2 impl --harness pi \
      --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
    grep -Fq 'does not match the requested specification' <<< "$err"
    ! grep -q '^effective: ' <<< "$err"
  done

  # An unusable agent_session and a record that never appears stop as well.
  for kind in id empty missing; do
    reset_logs
    set +e
    err="$(HERDR_TEST_PI_SESSION_KIND="$kind" "$LAUNCHER" wB:p2 impl --harness pi \
      --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 1000 2>&1 >/dev/null)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
    grep -Fq 'usable agent_session path' <<< "$err"
    ! grep -q '^effective: ' <<< "$err"
  done

  for mode in empty partial no-write; do
    reset_logs
    set +e
    err="$(HERDR_TEST_PI_SESSION_MODE="$mode" "$LAUNCHER" wB:p2 impl --harness pi \
      --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 1000 2>&1 >/dev/null)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
    grep -Fq 'did not report model and thinking values' <<< "$err"
    ! grep -q '^effective: ' <<< "$err"
  done
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=invalid "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 1000 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Eq 'unreadable entry|initial entries are missing before the conversation' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # Only the first model_change and thinking_level_change are authoritative: a
  # later switch must not win, and a wrong first value is not repaired by a
  # later matching one.
  reset_logs
  err="$(HERDR_TEST_PI_SESSION_MODE=first-match-later-mismatch "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  grep -Fqx 'effective: harness=pi provider=openai-codex model=gpt-6.2-sol effort=- thinking=max permission_requested=- requested=pi:openai-codex/gpt-6.2-sol/max' <<< "$err"
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=first-mismatch-later-match "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  ! grep -q '^effective: ' <<< "$err"

  # The first thinking level is authoritative too.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=first-thinking-mismatch-later-match "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'does not match the requested specification' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A broken initial entry is not skipped for a later matching one.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=broken-initial "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'unreadable' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # More than one JSON value on an initial line is not skipped for a later one.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=multi-value "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'multiple entries on one line' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A conversation entry before both initial values stops the read.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=initial-then-message "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'initial entries are missing before the conversation' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A custom_message line is also a conversation boundary and is not parsed.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_MODE=initial-then-custom-message "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'initial entries are missing before the conversation' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # One deadline covers the path lookup, the probe, and the record. The
  # bounded call itself must stop at the deadline, not after a slow IPC reply.
  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_PATH_DELAY=1.45 "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 1000 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  ! grep -q '^effective: ' <<< "$err"

  reset_logs
  set +e
  err="$(HERDR_TEST_PI_SESSION_PATH_DELAY=0.2 HERDR_TEST_PI_SESSION_MODE=on-prompt-late \
    HERDR_TEST_PI_SESSION_LATE_DELAY=2.0 "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 1000 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Eq 'could not be prompted|did not appear|did not report model and thinking values' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A record written shortly after readiness is still read within the bound.
  reset_logs
  err="$(HERDR_TEST_PI_SESSION_MODE=late "$LAUNCHER" wB:p2 impl --harness pi \
    --provider openai-codex --model gpt-6.2-sol --thinking max --probe-timeout 2000 2>&1 >/dev/null)"
  grep -Fqx 'effective: harness=pi provider=openai-codex model=gpt-6.2-sol effort=- thinking=max permission_requested=- requested=pi:openai-codex/gpt-6.2-sol/max' <<< "$err"
}

shared_launcher_claude_preflight() {
  local case_name config err rc probe settings command_line empty_home
  probe="$TMPDIR/agent-harness/claude-spec/wB_p2.json"
  settings="$TMPDIR/agent-harness/claude-spec/wB_p2.settings.json"

  # A logged-out CLI stops before the pane is even inspected, and the helper's
  # record never carries the account email.
  reset_logs
  set +e
  err="$(HERDR_TEST_CLAUDE_LOGGED_IN=false HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
    --permission-mode auto 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'Claude is not ready to start: command=auth-status result=unauthenticated' <<< "$err"
  ! grep -q 'never-printed@example.invalid' <<< "$err"
  ! grep -q 'email' <<< "$err"
  [ ! -s "$HERDR_TEST_STARTS" ]
  ! grep -q '^pane get ' "$HERDR_TEST_CALLS"

  # The trust file is read-only and fail closed: a missing file, `false`,
  # invalid JSON, and a project without the key are all unapproved, and the
  # file is byte-identical afterwards.
  for case_name in missing false invalid no-key; do
    config="$(claude_config_dir "$case_name")"
    rm -f "$config/before"
    case "$case_name" in
      missing) ;;
      false)
        printf '{"projects":{"%s":{"hasTrustDialogAccepted":false}}}\n' \
          "$(realpath -m -- "$CLAUDE_TRUSTED_DIR")" > "$config/.claude.json"
        ;;
      invalid) printf 'not json\n' > "$config/.claude.json" ;;
      no-key)
        printf '{"projects":{"%s":{"hasCompletedProjectOnboarding":true}}}\n' \
          "$(realpath -m -- "$CLAUDE_TRUSTED_DIR")" > "$config/.claude.json"
        ;;
    esac
    [ ! -e "$config/.claude.json" ] || cp "$config/.claude.json" "$config/before"
    reset_logs
    set +e
    err="$(CLAUDE_CONFIG_DIR="$config" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
      "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
      --permission-mode auto 2>&1 >/dev/null)"
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
    grep -Fqx "claude-trust: $(realpath -m -- "$CLAUDE_TRUSTED_DIR") が未承認です。そのディレクトリで claude を一度起動し、trust を承認してから再実行してください。" <<< "$err"
    [ ! -s "$HERDR_TEST_STARTS" ]
    ! grep -q '^launch: ' <<< "$err"
    ! grep -q '^probe: ' <<< "$err"
    if [ -e "$config/before" ]; then
      cmp -s "$config/.claude.json" "$config/before"
    else
      [ ! -e "$config/.claude.json" ]
    fi
  done

  # An explicit CLAUDE_CONFIG_DIR wins over the config directory the auth
  # record reports, so an approved directory in the other config cannot stand
  # in for this launch.
  config="$(claude_config_dir override)"
  reset_logs
  expect_rc 1 env CLAUDE_CONFIG_DIR="$config" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=match "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto
  [ ! -s "$HERDR_TEST_STARTS" ]

  # Trusted: the start carries the harness flags and a settings file path (never
  # an inline JSON argument), the probe record is private, and the effective
  # line follows the start.
  reset_logs
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=match HERDR_TEST_START_MARKER='agent-start-marker' \
    "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
    --permission-mode auto 2>&1 >/dev/null)"
  grep -Fqx "agent start review --kind claude --pane wB:p2 --timeout 60000 -- --model claude-haiku-5-5 --effort high --permission-mode auto --settings $settings" "$HERDR_TEST_STARTS"
  ! grep -q 'dangerously-skip-permissions' <<< "$(<"$HERDR_TEST_STARTS")"
  grep -Fqx "probe: $probe" <<< "$err"
  grep -Fqx 'effective: harness=claude provider=- model=claude-haiku-5-5 effort=high thinking=- permission_requested=auto requested=claude:claude-haiku-5-5/high/auto' <<< "$err"
  [ "$(line_of "$err" '^probe: ')" -lt "$(line_of "$err" '^launch: ')" ]
  [ "$(line_of "$err" '^launch: ')" -lt "$(line_of "$err" '^agent-start-marker$')" ]
  [ "$(line_of "$err" '^agent-start-marker$')" -lt "$(line_of "$err" '^effective: ')" ]
  [ "$(stat -c '%a' "$TMPDIR/agent-harness/claude-spec")" = 700 ]
  [ "$(stat -c '%a' "$probe")" = 600 ]
  [ "$(stat -c '%a' "$settings")" = 600 ]
  [ "$(jq -r '.statusLine.type' "$settings")" = command ]
  [ "$(jq -r '.statusLine.refreshInterval' "$settings")" = 1 ]
  command_line="$(jq -r '.statusLine.command' "$settings")"
  grep -Fq 'claude-statusline-probe.sh' <<< "$command_line"
  grep -Fq "$probe" <<< "$command_line"
  grep -Eq '[0-9a-f]{32}' <<< "$command_line"
  grep -Fqx 'pane get wB:p2' "$HERDR_TEST_CALLS"

  # Without CLAUDE_CONFIG_DIR the state file is <home>/.claude.json, one level
  # above the `<home>/.claude` directory the auth record reports.
  empty_home="$TEST_TMP/claude-home-empty"
  mkdir -p "$empty_home"
  reset_logs
  expect_rc 1 env -u CLAUDE_CONFIG_DIR HERDR_TEST_CLAUDE_HOME="$empty_home" \
    HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" "$LAUNCHER" wB:p2 review \
    --harness claude --model claude-haiku-5-5 --effort high --permission-mode auto
  [ ! -s "$HERDR_TEST_STARTS" ]

  # With the default state file in place it starts, and a missing
  # foreground_cwd falls back to cwd.
  reset_logs
  err="$(env -u CLAUDE_CONFIG_DIR HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_PANE_NO_FOREGROUND=1 HERDR_TEST_STATUSLINE=match \
    "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
    --permission-mode auto 2>&1 >/dev/null)"
  grep -q '^effective: ' <<< "$err"
  [ -s "$HERDR_TEST_STARTS" ]

  # An empty foreground_cwd falls back to cwd as well.
  reset_logs
  err="$(env -u CLAUDE_CONFIG_DIR HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_PANE_EMPTY_FOREGROUND=1 HERDR_TEST_STATUSLINE=match \
    "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
    --permission-mode auto 2>&1 >/dev/null)"
  grep -q '^effective: ' <<< "$err"
  [ -s "$HERDR_TEST_STARTS" ]

  # A pane without any working directory cannot be checked for trust.
  reset_logs
  expect_rc 1 env CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD= \
    "$LAUNCHER" wB:p2 review --harness claude --model claude-haiku-5-5 --effort high \
    --permission-mode auto
  [ ! -s "$HERDR_TEST_STARTS" ]
}

shared_launcher_claude_verification() {
  local err rc spec='claude:claude-haiku-5-5/high/auto'

  # A stored canonical model ID must match the launched session exactly.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=bad-model "$LAUNCHER" wB:p2 review --spec "$spec" \
    --spec-source profile --profile crew --role review 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'the launched Claude model does not match the requested specification: launched=claude-other-9' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"
  grep -q '^launch: ' <<< "$err"

  # An explicit alias is a one-off: the reported canonical model is the result,
  # even though it differs from the requested token.
  reset_logs
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=alias "$LAUNCHER" wB:p2 review --harness claude --model haiku \
    --effort high --permission-mode auto 2>&1 >/dev/null)"
  grep -Fqx 'effective: harness=claude provider=- model=claude-haiku-5-5 effort=high thinking=- permission_requested=auto requested=claude:haiku/high/auto' <<< "$err"

  # A different effort than the one requested stops the start.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=bad-effort "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'the launched Claude effort does not match the requested specification: launched=low' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A statusline without .effort.level is "not available", not a value.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=no-effort "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'did not report an effort level' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A statusline without .model.id is unusable too.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=no-model "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'reported no usable model' <<< "$err"

  # No write within the bounded wait stops the start and keeps the pane.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=none "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto --probe-timeout 300 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'did not report wB:p2 within 300ms' <<< "$err"
  grep -q '^launch: ' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"
  ! grep -q '^pane close' "$HERDR_TEST_CALLS"

  # A record from another launch in the same pane is never read as this one's.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=stale-nonce "$LAUNCHER" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto --probe-timeout 300 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq "another launch's record" <<< "$err"
  ! grep -q '^effective: ' <<< "$err"

  # A blocked agent receives no work: the launcher stops and leaves the pane.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR" \
    HERDR_TEST_STATUSLINE=match HERDR_TEST_AGENT_STATUS=blocked "$LAUNCHER" wB:p2 review \
    --harness claude --model claude-haiku-5-5 --effort high --permission-mode auto 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  grep -Fq 'is blocked; resolve the prompt in the pane' <<< "$err"
  ! grep -q '^effective: ' <<< "$err"
  ! grep -q '^pane close' "$HERDR_TEST_CALLS"
}

worktree_team_start_claude_mode() {
  local task_file="$TEST_TMP/claude-team-task.md" home err rc
  printf '%s\n' 'Goal: review with Claude' 'Acceptance: the review reports back' > "$task_file"
  write_profile_resolvers
  export HERDR_TEST_PANE_CWD="$CLAUDE_TRUSTED_DIR"

  # Explicit mode: the launcher's launch and effective lines reach the body in
  # that order, and the pane is renamed before the delegation.
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_STATUSLINE=match \
    HERDR_TEST_RC=0 "$START_SCRIPT" wB:p2 review --harness claude \
    --model claude-haiku-5-5 --effort high --permission-mode auto "$task_file" 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ]
  grep -Fqx "agent start review --kind claude --pane wB:p2 --timeout 60000 -- --model claude-haiku-5-5 --effort high --permission-mode auto --settings $TMPDIR/agent-harness/claude-spec/wB_p2.settings.json" "$HERDR_TEST_STARTS"
  grep -Fqx 'launch: profile=- role=- harness=claude spec=claude:claude-haiku-5-5/high/auto spec_source=explicit origin=explicit' <<< "$err"
  grep -Fqx 'effective: harness=claude provider=- model=claude-haiku-5-5 effort=high thinking=- permission_requested=auto requested=claude:claude-haiku-5-5/high/auto' <<< "$err"
  grep -Fqx 'wB:p2 review' "$HERDR_TEST_RENAMES"
  assert_file_eq wB:p2 "$HERDR_TEST_TARGET"
  grep -Fq 'Goal: review with Claude' "$HERDR_TEST_MESSAGE"
  [ "$(grep -c '^launch: ' "$HERDR_TEST_MESSAGE")" -eq 1 ]
  [ "$(grep -c '^effective: ' "$HERDR_TEST_MESSAGE")" -eq 1 ]
  awk '/^launch: /{ l=NR } /^effective: /{ e=NR } /Direct parent pane for result return/{ r=NR } END { exit !(l && e && r && l < e && e < r) }' "$HERDR_TEST_MESSAGE"

  # Pi now uses the launcher's effective line too, so both lines reach the body.
  reset_logs
  err="$(HERDR_TEST_RC=0 "$START_SCRIPT" wB:p2 impl \
    --provider anthropic --model claude-sonnet-4-5 --thinking high "$task_file" 2>&1 >/dev/null)"
  grep -Fqx 'launch: profile=- role=- harness=pi spec=pi:anthropic/claude-sonnet-4-5/high spec_source=explicit origin=explicit' <<< "$err"
  grep -Fqx 'effective: harness=pi provider=anthropic model=claude-sonnet-4-5 effort=- thinking=high permission_requested=- requested=pi:anthropic/claude-sonnet-4-5/high' <<< "$err"
  [ "$(grep -c '^launch: ' "$HERDR_TEST_MESSAGE")" -eq 1 ]
  [ "$(grep -c '^effective: ' "$HERDR_TEST_MESSAGE")" -eq 1 ]
  awk '/^launch: /{ l=NR } /^effective: /{ e=NR } /Direct parent pane for result return/{ r=NR } END { exit !(l && e && r && l < e && e < r) }' "$HERDR_TEST_MESSAGE"

  # Profile mode resolves a stored Claude role into the same launcher.
  home="$(profile_home claude-team)"
  write_profile_fixture "$home" default '{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "p", "model": "m", "thinking": "high"},
    "review": {"provider": "p", "model": "m", "thinking": "high"},
    "pr-fix": {"provider": "p", "model": "m", "thinking": "high"},
    "orchestrator": {"harness": "claude", "model": "claude-haiku-5-5", "effort": "high", "permission_mode": "auto"}
  }
}'
  reset_logs
  set +e
  err="$(CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_STATUSLINE=match HERDR_TEST_RC=0 \
    PI_CODING_AGENT_DIR="$home" "$START_SCRIPT" wB:p2 orchestrator --role orchestrator \
    --resolver "$TEST_TMP/resolver-ok.sh" "$task_file" 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" -eq 0 ]
  grep -Fqx 'launch: profile=default role=orchestrator harness=claude spec=claude:claude-haiku-5-5/high/auto spec_source=profile origin=default' <<< "$err"
  grep -Fqx 'effective: harness=claude provider=- model=claude-haiku-5-5 effort=high thinking=- permission_requested=auto requested=claude:claude-haiku-5-5/high/auto' <<< "$err"
  grep -Fqx "$(grep '^launch: ' <<< "$err" | tail -n 1)" "$HERDR_TEST_MESSAGE"
  grep -Fqx "$(grep '^effective: ' <<< "$err" | tail -n 1)" "$HERDR_TEST_MESSAGE"

  # A blocked start stops before the rename and the delegation, and the pane is
  # left in place for a human to resolve the prompt.
  reset_logs
  expect_rc 1 env CLAUDE_CONFIG_DIR="$CLAUDE_EXPLICIT_CONFIG_DIR" HERDR_TEST_STATUSLINE=match \
    HERDR_TEST_AGENT_STATUS=blocked HERDR_TEST_RC=0 "$START_SCRIPT" wB:p2 review \
    --harness claude --model claude-haiku-5-5 --effort high --permission-mode auto "$task_file"
  [ -s "$HERDR_TEST_STARTS" ]
  [ ! -s "$HERDR_TEST_RENAMES" ]
  [ ! -e "$HERDR_TEST_TARGET" ]
  ! grep -q '^pane close' "$HERDR_TEST_CALLS"

  unset HERDR_TEST_PANE_CWD
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
  #   M=5  -> 3x2: 2x3 and 3x2 both leave one slot, but the single-pane
  #           remainder row of 2x3 is a 200x20 pane (aspect 4.8), so only 3x2
  #           keeps every planned pane inside the window
  #   M=9  -> 3x3: four columns would need 220 cells of width
  #   M=12 -> 3x4, the largest grid this area can hold
  expect_plan 200x60 3 plan_grid_json '[2,2,4]'
  expect_plan 200x60 4 plan_grid_json '[2,3,5]'
  expect_plan 200x60 8 plan_grid_json '[3,3,9]'
  expect_plan 200x60 11 plan_grid_json '[4,3,12]'
  expect_plan_field 200x60 4 aspect_window '"ok"'
  expect_plan_field 200x60 3 capacity 12
  expect_plan 300x60 5 plan_grid_json '[2,3,6]'
  expect_plan 300x60 19 plan_grid_json '[4,5,20]'
  expect_plan_field 300x60 19 capacity 20
  # 220x56 with M=10 ties through empty slots and fill (both candidates leave
  # two slots and fill the minimum cell exactly), so rule 4 decides: 4x3 has
  # an aspect distance of 0.014 against 1.114 for 3x4.
  expect_plan 220x56 9 plan_grid_json '[3,4,10]'
  # Rule 4 still decides the shape on the uniform-cell basis, while the flag
  # reports the planned rectangles: the two-pane remainder row is 110x19.
  expect_plan_field 220x56 9 aspect_window '"relaxed"'
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
  # A grid whose last row holds fewer panes: the row cut chain runs first,
  # then each row, so every row pane spans the full width when it is cut.
  expect_plan 200x60 4 plan_splits_json \
    '[[0,0,3,"down",0.5],[0,0,1,"right",0.33],[0,1,2,"right",0.5],[0,3,4,"right",0.5]]'
  # Only the top-left cell is the pane the plan starts from.
  expect_plan 200x60 4 plan_cells_json \
    '[[0,0,0,0,0,66,30,true],[1,0,1,66,0,67,30,false],[2,0,2,133,0,67,30,false],[3,1,0,0,30,100,30,false],[4,1,1,100,30,100,30,false]]'
}

pane_layout_plan_relaxes_the_aspect_window() {
  # 110x40 holds four panes (2x2) but no two-pane grid fits the aspect window
  # (110x20 is 2.64, 55x40 is 0.66). The five-pane team is split evenly into
  # three and two, and the two-pane tab falls back to the hard minimum (tier
  # B) instead of failing the plan.
  expect_plan 110x40 5 plan_tabs_json '[[2,2,3,null],[2,1,2,null]]'
  expect_plan 110x40 5 plan_splits_json \
    '[[0,0,2,"down",0.5],[0,0,1,"right",0.5],[1,0,1,"down",0.5]]'
  expect_plan_field 110x40 5 tab_policy '"new"'
  expect_plan_field 110x40 5 capacity 4
  expect_plan_field 110x40 5 aspect_window '"relaxed"'
  # Both tabs are relaxed: the three-pane tab's remainder row is a single
  # 110x20 pane, aspect 2.64, and the two-pane tab is 110x20 twice.
  expect_plan_field 110x40 5 tabs.0.aspect_window '"relaxed"'
  expect_plan_field 110x40 5 tabs.1.aspect_window '"relaxed"'
  # A size with a window-satisfying full grid keeps using it.
  expect_plan 110x40 2 plan_grid_json '[2,2,3]'
  expect_plan_field 110x40 2 tab_policy '"current"'
  expect_plan_field 110x40 2 aspect_window '"relaxed"'
  # 100x14 can hold exactly one pane: every requested tab is relaxed, and the
  # plan still succeeds because the hard minimum is met.
  expect_plan 100x14 3 plan_tabs_json '[[1,1,1,null],[1,1,1,null],[1,1,1,null]]'
  expect_plan_field 100x14 3 tab_policy '"new"'
  expect_plan_field 100x14 3 capacity 1
  expect_plan_field 100x14 3 aspect_window '"relaxed"'
  expect_plan_field 100x14 3 tabs.0.aspect_window '"relaxed"'
}

pane_layout_plan_checks_the_actual_rectangles() {
  # The tier gate and the flag run on the planned rectangles, not on a uniform
  # cell: a partially filled last row spreads its panes over the full width.
  # 247x50 with M=10 keeps a 3x4 grid, but that last row holds two 123x17 and
  # 124x17 panes (aspect 3.47 / 3.50), so the plan reports relaxed.
  expect_plan_field 247x50 9 aspect_window '"relaxed"'
  expect_plan 247x50 9 plan_grid_json '[3,4,10]'
  printf '%s' "$(plan_json 247x50 9)" | assert_json_field tabs.0.aspect_window '"relaxed"'
  printf '%s' "$(plan_json 247x50 9)" | assert_json_field tabs.0.cells.8.width 123
  printf '%s' "$(plan_json 247x50 9)" | assert_json_field tabs.0.cells.8.height 17
  printf '%s' "$(plan_json 247x50 9)" | assert_json_field tabs.0.cells.9.width 124
  # A fully filled grid stays ok (M=4 at 247x47), and so does a partially
  # filled last row whose panes all remain inside the window (M=7).
  expect_plan_field 247x47 3 aspect_window '"ok"'
  expect_plan_field 247x47 6 aspect_window '"ok"'
  expect_plan_field 247x47 6 tabs.0.aspect_window '"ok"'
  # The same remainder problem in a narrow region: the M=3 layout at 110x40
  # leaves one 110x20 pane (aspect 2.64) in its last row.
  expect_plan_field 110x40 2 aspect_window '"relaxed"'
  expect_plan_field 110x40 2 tabs.0.aspect_window '"relaxed"'
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
  # Neither of these areas can hold one pane at the hard minimum: 40x10 is
  # smaller in both directions and 54x100 is narrower than 55 cells. The
  # aspect window alone never fails a plan.
  expect_plan_error 40x10 3 'no feasible pane grid'
  expect_plan_error 54x100 3 'no feasible pane grid'
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
  printf '%s' "$result" | assert_json_field aspect_window '"ok"'
  printf '%s' "$result" | assert_json_field tabs.0.aspect_window '"ok"'
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

  # A caller that does not start at the tab origin: the split ratios are
  # relative to the caller rectangle, and verification offsets every planned
  # cell by the caller's own origin.
  reset_layout_state 247x50 123 0 124 50
  result="$(HERDR_TEST_TAB_AREA=247x50 "$LAYOUT_SCRIPT" apply --count 3 --cwd "$TEST_TMP")"
  printf '%s' "$result" | assert_json_field tab_policy '"current"'
  printf '%s' "$result" | assert_json_field region '{"height":50,"width":124}'
  printf '%s' "$result" | assert_json_field rows 2
  printf '%s' "$result" | assert_json_field cols 2
  printf '%s' "$result" | assert_json_field created_panes '["wG:p10","wG:p9","wG:p11"]'
  # Planned cells stay relative to the caller rectangle at 123,0.
  printf '%s' "$result" | assert_json_field tabs.0.cells.1.x 62
  printf '%s' "$result" | assert_json_field tabs.0.cells.1.y 0
  printf '%s' "$result" | assert_json_field tabs.0.cells.3.x 62
  printf '%s' "$result" | assert_json_field tabs.0.cells.3.y 25
  grep -Fqx 'wG:p10|wG:t1|185|0|62|25' "$HERDR_TEST_STATE/panes"
  grep -Fqx 'wG:p11|wG:t1|185|25|62|25' "$HERDR_TEST_STATE/panes"
  expected="$(cat <<EOF
pane layout --pane wG:p1
pane split --pane wG:p1 --direction down --ratio 0.500000 --cwd $TEST_TMP --no-focus
pane split --pane wG:p1 --direction right --ratio 0.500000 --cwd $TEST_TMP --no-focus
pane split --pane wG:p9 --direction right --ratio 0.500000 --cwd $TEST_TMP --no-focus
pane layout --pane wG:p1
EOF
)"
  assert_layout_calls "$expected"
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

# The markdown link and anchor check is shared with CI and every other skill,
# so it lives in one script: in each given skill directory, every relative link
# must exist and every '#fragment' must name a heading of its target, while
# links that are examples (`code spans` and fenced blocks) are ignored.
MARKDOWN_CHECK="$HERDR_DIR/../scripts/check-markdown-links.sh"

markdown_check() { # <skill-dir>...
  "$MARKDOWN_CHECK" "$@"
}

# A copy of the skill markdown and the other-skill files that herdr/SKILL.md and
# herdr/references/*.md link to. The negative tests mutate this copy so the real
# tree stays clean.
MARKDOWN_FIXTURE_ROOT="$TEST_TMP/markdown-fixture"

setup_markdown_fixture() {
  rm -rf "$MARKDOWN_FIXTURE_ROOT"
  mkdir -p "$MARKDOWN_FIXTURE_ROOT/herdr/references" \
    "$MARKDOWN_FIXTURE_ROOT/herdr-issue-pr-workflow/references" \
    "$MARKDOWN_FIXTURE_ROOT/_docs"
  cp "$HERDR_DIR/SKILL.md" "$MARKDOWN_FIXTURE_ROOT/herdr/SKILL.md"
  cp "$HERDR_DIR"/references/*.md "$MARKDOWN_FIXTURE_ROOT/herdr/references/"
  cp "$HERDR_DIR/../herdr-issue-pr-workflow/SKILL.md" "$MARKDOWN_FIXTURE_ROOT/herdr-issue-pr-workflow/SKILL.md"
  cp "$HERDR_DIR/../herdr-issue-pr-workflow/references/kickoff-task-template.md" \
    "$MARKDOWN_FIXTURE_ROOT/herdr-issue-pr-workflow/references/kickoff-task-template.md"
  cp "$HERDR_DIR/../_docs/pi-development.md" "$MARKDOWN_FIXTURE_ROOT/_docs/pi-development.md"
}

replace_in_file() {
  local file="$1"
  sed "$2" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

expect_markdown_failure() {
  local root="$1" pattern="$2" output status
  set +e
  output="$(markdown_check "$root" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || {
    printf 'expected the markdown link check to fail for %s\n' "$root" >&2
    return 1
  }
  case "$output" in
    *"$pattern"*) ;;
    *)
      printf 'expected %s, got: %s\n' "$pattern" "$output" >&2
      return 1
      ;;
  esac
}

# The real tree must pass, and the negative cases fixed by the checker's
# contract must fail: renaming a reference file and renaming the heading of a
# skill that another skill links to both break the check, while an example link
# inside a code span or a fenced block does not.
markdown_check_passes() {
  markdown_check "$HERDR_DIR"
}

markdown_reference_file_rename_is_rejected() {
  setup_markdown_fixture
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  mv "$MARKDOWN_FIXTURE_ROOT/herdr/references/worktree-workspace-teams.md" \
    "$MARKDOWN_FIXTURE_ROOT/herdr/references/worktree-workspace-teams-renamed.md"
  expect_markdown_failure "$MARKDOWN_FIXTURE_ROOT/herdr" 'relative link does not resolve'
}

markdown_same_file_anchor_is_checked() {
  setup_markdown_fixture
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  replace_in_file "$MARKDOWN_FIXTURE_ROOT/herdr/SKILL.md" 's|](#worktree-workspaces)|](#worktree-workspaces-missing)|'
  expect_markdown_failure "$MARKDOWN_FIXTURE_ROOT/herdr" 'anchor does not resolve'
}

markdown_file_anchor_is_checked() {
  setup_markdown_fixture
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  replace_in_file "$MARKDOWN_FIXTURE_ROOT/herdr/SKILL.md" \
    's|references/worktree-workspace-teams\.md#orchestrator-first|references/worktree-workspace-teams.md#orchestrator-first-missing|'
  expect_markdown_failure "$MARKDOWN_FIXTURE_ROOT/herdr" 'anchor does not resolve'
}

markdown_other_skill_heading_rename_is_rejected() {
  setup_markdown_fixture
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  replace_in_file "$MARKDOWN_FIXTURE_ROOT/herdr-issue-pr-workflow/SKILL.md" \
    's|^## Completion$|## Completion Renamed|'
  expect_markdown_failure "$MARKDOWN_FIXTURE_ROOT/herdr" 'anchor does not resolve'
}

markdown_code_examples_are_ignored() {
  setup_markdown_fixture
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  cat >> "$MARKDOWN_FIXTURE_ROOT/herdr/SKILL.md" <<'EOF'

Examples are not navigation: `![alt](./shot.png)`, `](path)`, and
`[Snapshot](.playwright-cli/page-2026-02-14T19-22-42-679Z.yml)`.

```markdown
- [Snapshot](.playwright-cli/page-2026-02-14T19-22-42-679Z.yml)
- [Snapshot](path)
```
EOF
  markdown_check "$MARKDOWN_FIXTURE_ROOT/herdr" || return 1
  # The same target outside a code span is navigation and must be reported, so
  # the pass above proves the exclusion rather than the target's existence.
  printf '%s\n' 'Unwrapped: [Snapshot](.playwright-cli/page-2026-02-14T19-22-42-679Z.yml)' \
    >> "$MARKDOWN_FIXTURE_ROOT/herdr/SKILL.md"
  expect_markdown_failure "$MARKDOWN_FIXTURE_ROOT/herdr" 'relative link does not resolve'
}


run_test() {
  local test_name="$1"
  "$test_name"
  pass "$test_name"
}

expected_count=40

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
run_test worktree_team_start_profile_mode
run_test worktree_team_start_profile_failures
run_test shared_launcher_pi_arguments
run_test shared_launcher_pi_effective
run_test shared_launcher_claude_preflight
run_test shared_launcher_claude_verification
run_test worktree_team_start_claude_mode
run_test cli_failure_is_propagated
run_test parent_display_name_fallbacks
run_test python3_isolation
run_test wrappers_are_thin
run_test pane_layout_plan_grids
run_test pane_layout_plan_new_tabs
run_test pane_layout_plan_geometry
run_test pane_layout_plan_checks_the_actual_rectangles
run_test pane_layout_plan_relaxes_the_aspect_window
run_test pane_layout_plan_is_pure
run_test pane_layout_plan_rejects_bad_input
run_test pane_layout_apply_current_tab
run_test pane_layout_apply_new_tabs
run_test pane_layout_apply_stops_on_mismatch
run_test markdown_check_passes
run_test markdown_reference_file_rename_is_rejected
run_test markdown_same_file_anchor_is_checked
run_test markdown_file_anchor_is_checked
run_test markdown_other_skill_heading_rename_is_rejected
run_test markdown_code_examples_are_ignored

[ "$pass_count" -eq "$expected_count" ] || {
  printf 'FAIL: expected %s tests, got %s\n' "$expected_count" "$pass_count" >&2
  exit 1
}

printf 'PASS: %s Herdr async wrapper tests\n' "$pass_count"
