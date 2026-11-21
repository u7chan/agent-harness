#!/usr/bin/env bash
# Keep the merge procedure out of this skill and behind its authoritative
# section. The workflow forbids the reviewer and the orchestrator from merging;
# the executor, the path, and the pre/post-merge checks live in
# _docs/skill-distribution.md, so every place that mentions a merge after a run
# links to that section instead of restating it.
#
# The link carries the fragment, because a link to the document alone would
# still pass after the section moved or was renamed.
#
# These tests read the skill's Markdown only: no pi, no network.
# herdr-pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0
CANON_LINK='../_docs/skill-distribution.md#merge--rollout'

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle" ;;
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
REVIEW_TEXT="$(section_text "$SKILL_MD" "Delegation contract")"
COMPLETION_TEXT="$(section_text "$SKILL_MD" "Completion")"

check_contains "the merge prohibition links the merge procedure" "$REVIEW_TEXT" "$CANON_LINK"
check_contains "the completion rollout guidance links the merge procedure" "$COMPLETION_TEXT" "$CANON_LINK"

# The prohibition itself stays one sentence; the linked section owns the rules.
case "$REVIEW_TEXT" in
  *"レビュアーは修正実装、PR の APPROVE、マージを行わない。"*) ok "the reviewer prohibition is unchanged" ;;
  *) ng "the reviewer prohibition is unchanged" "expected the prohibition sentence in Delegation contract" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
