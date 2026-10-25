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
  'follows a completed run of the same Issue'
check_contains "a stopped predecessor builds every pane" "$REFERENCE_TEXT" \
  'stopped before'
check_contains "the idle check reads the agent status" "$REFERENCE_TEXT" \
  '`agent_status: idle`'
check_contains "the specification check reads the footer" "$REFERENCE_TEXT" \
  '--source visible'
check_contains "startup argv is not evidence" "$REFERENCE_TEXT" \
  'Startup argv'

# --- compaction ------------------------------------------------------------

check_contains "the command is a raw TUI prompt" "$REFERENCE_TEXT" \
  'herdr agent prompt <pane-id> "/compact"'
check_contains "the command is not a delegation" "$REFERENCE_TEXT" \
  'This is not a delegation'
check_contains "a successful compaction adds its result line" "$REFERENCE_TEXT" \
  'Compacted from <N>'
check_contains "a failed compaction adds an error line" "$REFERENCE_TEXT" \
  'Compaction failed: <reason>'
check_contains "the indicator line is not the completion test" "$REFERENCE_TEXT" \
  'never judge the outcome by searching'
check_contains "completion compares against the pre-send read" "$REFERENCE_TEXT" \
  'that read did not have'
check_contains "agent_status is never a completion signal" "$REFERENCE_TEXT" \
  'never a completion signal'
check_contains "reuse covers panes from an earlier run" "$REFERENCE_TEXT" \
  'an earlier run of the same Issue'
check_contains "a full reuse creates no pane" "$REFERENCE_TEXT" \
  'create no pane'
check_contains "SKILL.md skips the planner for a full reuse" "$TEAM_TEXT" \
  'the planner is not called'

# --- handoff and other panes ----------------------------------------------

check_contains "the facts travel in the task text" "$REFERENCE_TEXT" \
  'is not a handoff'
check_contains "sequential runs link the Team profiles section" "$REFERENCE_TEXT" \
  '../SKILL.md#team-profiles'
check_not_contains "sequential runs do not keep the old record anchor" "$REFERENCE_TEXT" \
  "$OLD_TEAM_RECORD_ANCHOR"
check_contains "a single new role is split, not planned" "$REFERENCE_TEXT" \
  'single-pane rules'
check_contains "the profile never makes a pane reusable" "$REFERENCE_TEXT" \
  'A profile says nothing about panes'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
