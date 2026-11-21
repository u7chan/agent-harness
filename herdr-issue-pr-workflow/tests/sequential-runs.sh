#!/usr/bin/env bash
# Hermetic documentation contract for sequential run pane reuse: reuse only
# after a completed run and only when every condition holds, a manual
# compaction is sent as a TUI command rather than a delegation, its completion
# is judged on the screen instead of `agent_status`, and the previous run's
# facts travel in the task text.
#
# These tests read the skill's Markdown only: no pi, no Herdr, no network.
# herdr-pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
SEQUENTIAL_REFERENCE="$SKILL_DIR/references/sequential-runs.md"

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle" ;;
  esac
}

check_not_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ng "$name" "should NOT contain: $needle" ;;
    *) ok "$name" ;;
  esac
}

section_text() { # file heading
  awk -v heading="## $2" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

SKILL_TEXT="$(cat "$SKILL_MD")"
REFERENCE_TEXT="$(cat "$SEQUENTIAL_REFERENCE")"

# The removed section anchor is rebuilt from its heading words, so this suite
# itself does not carry the old literal while the check still pins its absence.
OLD_TEAM_RECORD_ANCHOR="#$(printf '%s' 'approved' ' team' ' record' | tr ' ' '-')"
KICKOFF_TEXT="$(section_text "$SKILL_MD" "Kickoff gate")"
TEAM_TEXT="$(section_text "$SKILL_MD" "Start the team")"

# --- SKILL.md keeps the rules and points at the procedure ------------------

# Both the multi-PR rule and Start the team point at the procedure reference.
check_contains "the multi-PR rule references the procedure" "$KICKOFF_TEXT" \
  'references/sequential-runs.md'
check_contains "Start the team references the procedure" "$TEAM_TEXT" \
  'references/sequential-runs.md'
check_contains "Start the team passes only the new panes to the planner" \
  "$TEAM_TEXT" '--count <new physical agents>'

# --- reuse conditions ------------------------------------------------------

check_contains "reuse follows a completed run" "$REFERENCE_TEXT" \
  '同じ Issue の完了済み実行に続く実行'
check_contains "a stopped predecessor builds every pane" "$REFERENCE_TEXT" \
  'より前に停止した'
check_contains "the idle check reads the agent status" "$REFERENCE_TEXT" \
  '`agent_status: idle`'
check_contains "a pane from the other harness is not reusable" "$REFERENCE_TEXT" \
  'ハーネスが異なるペインを、同じロールの再利用先にしない'
check_contains "the specification check reads the footer" "$REFERENCE_TEXT" \
  '--source visible'
check_contains "the Claude reuse reads the probe path" "$REFERENCE_TEXT" \
  'probe: <path>'
check_contains "reuse treats the recorded effective line as authoritative" "$REFERENCE_TEXT" \
  '会話に記録された最後の `effective:` 行を正本とし'
check_contains "the probe nonce stays internal to the launcher" "$REFERENCE_TEXT" \
  '`nonce` はランチャー内部の起動記録'
check_contains "the probe line exposes only the path" "$REFERENCE_TEXT" \
  '`probe:` 行にはパスだけが出る'
check_contains "the probe check compares model and effort" "$REFERENCE_TEXT" \
  '`model` と `effort` を比較するだけで'
check_contains "the statusline fields are the probe input" "$REFERENCE_TEXT" \
  'statusline の `.model.id` と `.effort.level` は probe の入力'
check_not_contains "the orchestrator does not gate reuse on the nonce" "$REFERENCE_TEXT" \
  '`nonce` が一致しない場合'
check_not_contains "the probe file does not expose statusline dotted fields" "$REFERENCE_TEXT" \
  'のファイルを読み、`.model.id`'
check_contains "startup argv is not evidence" "$REFERENCE_TEXT" \
  '起動 argv'

# --- compaction ------------------------------------------------------------

check_contains "the command is a raw TUI prompt" "$REFERENCE_TEXT" \
  'herdr agent prompt <pane-id> "/compact"'
check_contains "the command is not a delegation" "$REFERENCE_TEXT" \
  'これは委譲ではない'
check_contains "a successful compaction adds its result line" "$REFERENCE_TEXT" \
  'Compacted from <N>'
check_contains "a successful Claude compaction adds its result line" "$REFERENCE_TEXT" \
  'Compacted ('
check_contains "a failed compaction adds an error line" "$REFERENCE_TEXT" \
  'Compaction failed: <reason>'
check_contains "both harnesses report a compaction failure by prefix" "$REFERENCE_TEXT" \
  '`Compaction failed` で始まる'
check_contains "the indicator line is not the completion test" "$REFERENCE_TEXT" \
  'ペインを検索して結果を判定してはならない'
check_contains "completion compares against the pre-send read" "$REFERENCE_TEXT" \
  'その読み取りになかった結果行'
check_contains "agent_status is never a completion signal" "$REFERENCE_TEXT" \
  '完了の信号にならない'
check_contains "reuse covers panes from an earlier run" "$REFERENCE_TEXT" \
  '同じ Issue の以前の実行'
check_contains "a full reuse creates no pane" "$REFERENCE_TEXT" \
  'ペインを作らず'
check_contains "SKILL.md skips the planner for a full reuse" "$TEAM_TEXT" \
  'プランナーも呼ばない'

# --- handoff and other panes ----------------------------------------------

check_contains "the facts travel in the task text" "$REFERENCE_TEXT" \
  'ハンドオフではない'
check_contains "sequential runs link the Team profiles section" "$REFERENCE_TEXT" \
  '../SKILL.md#team-profiles'
check_not_contains "sequential runs do not keep the old record anchor" "$REFERENCE_TEXT" \
  "$OLD_TEAM_RECORD_ANCHOR"
check_contains "a single new role is split, not planned" "$REFERENCE_TEXT" \
  '単一ペイン規則'
check_contains "the profile never makes a pane reusable" "$REFERENCE_TEXT" \
  'プロファイルはペインについて何も言わず'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
