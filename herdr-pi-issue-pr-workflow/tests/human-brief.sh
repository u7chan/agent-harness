#!/usr/bin/env bash
# Hermetic documentation contract for the human review brief: the orchestrator
# adds the marked summary to the PR body, the implementation agent skips it,
# and the summary remains separate from the ui-tester evidence.
#
# These tests read the skill's Markdown and the shared contract only: no pi,
# no Herdr, no network, no browser.
# herdr-pi-issue-pr-workflow/tests/run.sh runs this file as part of the suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$SKILL_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
ROLE_REFERENCE="$SKILL_DIR/references/ui-tester-role.md"
HUMAN_BRIEF="$ROOT/_docs/human-brief.md"

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_contains() { # name haystack needle
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle" ;;
  esac
}

section_text() { # file heading (heading includes the leading hashes)
  awk -v heading="$2" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

section_line() { # file heading
  awk -v heading="$2" '$0 == heading { print NR; exit }' "$1"
}

[ -f "$SKILL_MD" ] || { printf 'FAIL missing %s\n' "$SKILL_MD" >&2; exit 1; }
[ -f "$HUMAN_BRIEF" ] || { printf 'FAIL missing %s\n' "$HUMAN_BRIEF" >&2; exit 1; }

SKILL_TEXT="$(cat "$SKILL_MD")"
HUMAN_BRIEF_TEXT="$(cat "$HUMAN_BRIEF")"
ROLE_TEXT="$(cat "$ROLE_REFERENCE")"
BRIEF_TEXT="$(section_text "$SKILL_MD" "### Human review brief")"
BRIEF_LINE="$(section_line "$SKILL_MD" "### Human review brief")"
REVIEW_LINE="$(section_line "$SKILL_MD" "### Initial review")"

# --- the shared contract ----------------------------------------------------

for value in \
  'pi:human-brief:start' \
  'pi:human-brief:end' \
  '## 人間レビュー用サマリ' \
  'GIF' \
  'MP4' \
  '10 MB' \
  'attachments' \
  'この節は証跡ではなく' \
  '範囲外の本文を正本' \
  '行頭の HTML コメント' \
  'コード Span'; do
  check_contains "the shared contract contains $value" "$HUMAN_BRIEF_TEXT" "$value"
done

# --- the orchestrator owns the section -------------------------------------

check_contains "the workflow links the shared contract" "$SKILL_TEXT" '../_docs/human-brief.md'
check_contains "the preflight skips the brief" "$SKILL_TEXT" \
  '本文の `pi:human-brief` 範囲は除く'
check_contains "the implementation step skips the brief" "$SKILL_TEXT" \
  'Issue 本文の `pi:human-brief` 範囲は読まない'
check_contains "the reviewer skips the brief" "$SKILL_TEXT" \
  'PR 本文の `pi:human-brief` 範囲は読まないと伝える'
check_contains "the draft PR leaves the brief to the orchestrator" "$SKILL_TEXT" \
  '人間レビュー用サマリも orchestrator が追加する'

if [ -n "$BRIEF_LINE" ] && [ -n "$REVIEW_LINE" ] && [ "$BRIEF_LINE" -lt "$REVIEW_LINE" ]; then
  ok "the brief is prepared before the review"
else
  ng "the brief is prepared before the review" \
    "brief line '${BRIEF_LINE:-none}' review line '${REVIEW_LINE:-none}'"
fi

for value in \
  '../_docs/human-brief.md' \
  '../explain-video/SKILL.md' \
  'GIF' \
  'MP4' \
  '`pi:human-brief`' \
  '`pr.update`' \
  '`attachments`' \
  '`head`' \
  '行頭の HTML コメントのマーカーが 1 対だけ' \
  'コード Span や引用はマーカーとして数えない' \
  'FFmpeg / Playwright が使えない場合'; do
  check_contains "the brief section contains $value" "$BRIEF_TEXT" "$value"
done

check_contains "the completion gate requires the brief" "$SKILL_TEXT" \
  '行頭の `pi:human-brief` マーカーが 1 対だけ'
check_contains "the brief is refreshed after a fix push" "$SKILL_TEXT" \
  '修正 push 後に、人間レビュー用サマリがある PR'
check_contains "the completion gate keeps the evidence separate" "$SKILL_TEXT" \
  'サマリは証跡ではないため、証跡節の条件を置き換えない'

# --- separation from ui-tester evidence ------------------------------------

check_contains "the UI evidence still forbids GIF" "$ROLE_TEXT" 'GIF を生成せず'
check_contains "the brief is not ui-tester evidence" "$BRIEF_TEXT" \
  '`ui-tester` の証跡とは別'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
