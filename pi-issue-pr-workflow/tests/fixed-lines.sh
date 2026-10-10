#!/usr/bin/env bash
# Hermetic contract for the workflow's fixed report lines. Each line has one
# authoritative definition, and the line is pinned at that definition so a
# wording change fails here instead of drifting between SKILL.md and the
# references.
#
# The authorities are:
#   - references/ui-tester-role.md: the participation forms and the closure
#     line;
#   - SKILL.md: the target PR forms.
# The `前回承認編成を使用:` reuse line stays owned by tests/team-record.sh,
# which pins it next to the record helper it belongs to; this suite does not
# duplicate that check.
#
# A form is read from the section that defines it, not from the whole file:
# the completion report repeats `対象 PR` as an example, so a whole-file search
# would still pass after the kickoff definition changed.
#
# These tests read the skill's Markdown only: no pi, no network.
# pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
ROLE_REFERENCE="$SKILL_DIR/references/ui-tester-role.md"

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
ROLE_TEXT="$(cat "$ROLE_REFERENCE")"

PARTICIPATION_TEXT="$(section_text "$ROLE_REFERENCE" "Participation")"
CLEANUP_TEXT="$(section_text "$ROLE_REFERENCE" "Completion cleanup")"
KICKOFF_TEXT="$(section_text "$SKILL_MD" "Kickoff gate")"

# --- participation lines (authority: references/ui-tester-role.md) ---------

# The three forms the kickoff reply may print, one per line. The ambiguous
# form carries the Draft PR re-judgment rule, so it is pinned with the rest.
check_contains "participation line includes the role" "$PARTICIPATION_TEXT" \
  'ui-tester: 同梱（<根拠>）'
check_contains "participation line excludes the role" "$PARTICIPATION_TEXT" \
  'ui-tester: 除外（<根拠>）'
check_contains "participation line keeps the ambiguous form" "$PARTICIPATION_TEXT" \
  'ui-tester: 同梱（曖昧: <根拠>; Draft PR の差分で再判定）'

# SKILL.md delegates the definition and keeps the rule that the reply always
# prints one line; a re-enumeration there would reintroduce the second source.
check_contains "SKILL.md points the gate at the participation rule" "$KICKOFF_TEXT" \
  'references/ui-tester-role.md#participation'
check_contains "SKILL.md keeps the one-line kickoff reply rule" "$KICKOFF_TEXT" \
  'in every kickoff reply'
check_not_contains "SKILL.md does not restate the include form" "$SKILL_TEXT" \
  'ui-tester: 同梱'
check_not_contains "SKILL.md does not restate the exclude form" "$SKILL_TEXT" \
  'ui-tester: 除外'

# --- closure line (authority: references/ui-tester-role.md) ----------------

# The completion cleanup prints exactly one line for the one pane it closes.
check_contains "closure line names the pane and the reason" "$CLEANUP_TEXT" \
  'ui-tester: <pane-id> をクローズ（未委譲）'
check_not_contains "SKILL.md does not restate the closure line" "$SKILL_TEXT" \
  'ui-tester: <pane-id>'

# --- target PR forms (authority: SKILL.md) ---------------------------------

# The kickoff proposal, the delegation body, and the completion report print
# one of these two forms; the sequence form carries the position of this run.
check_contains "target PR form states a position within the plan" "$KICKOFF_TEXT" \
  '`対象 PR: <position>/<total>`'
check_contains "target PR form states a single-PR run" "$KICKOFF_TEXT" \
  '`対象 PR: single`'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
