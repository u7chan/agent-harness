#!/usr/bin/env bash
# Hermetic documentation contract for the herdr-issue-review start gate: the gate
# runs before any side effect, it defers to the herdr skill for the conditions
# themselves, and it states the stop and the no-substitution rules.
#
# These tests read the skill's Markdown only: no pi, no Herdr, no network, no
# GitHub. They are an instruction contract, not proof of a technical block:
# SKILL.md is guidance to an agent and the gate has no enforcement path.
#
# The contract is the structure, not the prose: it pins where the gate sits,
# which authority it names, and which keywords carry the conditions and the
# stop rule. Whole sentences and the existing procedure headings are not
# pinned, so an edit that keeps the contract can reword the text freely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"

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

check_not_contains() { # name haystack needle
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ng "$name" "should NOT contain: $needle" ;;
    *) ok "$name" ;;
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

GATE_TEXT="$(section_text "$SKILL_MD" "## 開始前チェック")"
GATE_LINE="$(section_line "$SKILL_MD" "## 開始前チェック")"
ARTIFACT_LINE="$(section_line "$SKILL_MD" "## 成果物ファイル")"
PROCEDURE_LINE="$(section_line "$SKILL_MD" "## 手順")"

# --- the gate exists and runs before every side effect ---------------------

if [ -n "$GATE_LINE" ]; then
  ok "the skill documents a start gate"
else
  ng "the skill documents a start gate" "## 開始前チェック not found"
fi

# The gate is only a gate while it runs first: the artifact file and the
# review procedure both live below it.
if [ -n "$GATE_LINE" ] && [ -n "$ARTIFACT_LINE" ] && [ "$GATE_LINE" -lt "$ARTIFACT_LINE" ]; then
  ok "the gate precedes the artifact file section"
else
  ng "the gate precedes the artifact file section" \
    "gate line '${GATE_LINE:-none}' artifact line '${ARTIFACT_LINE:-none}'"
fi

if [ -n "$GATE_LINE" ] && [ -n "$PROCEDURE_LINE" ] && [ "$GATE_LINE" -lt "$PROCEDURE_LINE" ]; then
  ok "the gate precedes the review procedure"
else
  ng "the gate precedes the review procedure" \
    "gate line '${GATE_LINE:-none}' procedure line '${PROCEDURE_LINE:-none}'"
fi

# --- the conditions stay owned by the herdr skill --------------------------

check_contains "the gate defers to the herdr skill" "$GATE_TEXT" '../herdr/SKILL.md'
check_contains "the gate names the herdr preflight" "$GATE_TEXT" 'Preflight'
check_contains "the gate names the herdr caller pinning" "$GATE_TEXT" 'Caller pinning'

# The check commands themselves stay in herdr/SKILL.md: copying them here would
# give the repository a second definition to keep in sync.
check_not_contains "the gate does not copy the herdr preflight command" "$GATE_TEXT" \
  'test "${HERDR_ENV:-}" = 1'
check_not_contains "the gate does not copy the herdr command probe" "$GATE_TEXT" \
  'command -v herdr'

# The gate still lists the conditions the Issue requires.
check_contains "the gate names the Herdr marker variable" "$GATE_TEXT" 'HERDR_ENV'
check_contains "the gate names the workspace ID" "$GATE_TEXT" 'HERDR_WORKSPACE_ID'
check_contains "the gate names the pane ID" "$GATE_TEXT" 'HERDR_PANE_ID'
check_contains "the gate keeps the ID format check" "$GATE_TEXT" '形式'
check_contains "the gate keeps the workspace consistency check" "$GATE_TEXT" '整合'

# --- the gate states the stop and the no-substitution rules ----------------

check_contains "the gate states that it stops" "$GATE_TEXT" '停止'
check_contains "the gate names the GitHub write it blocks" "$GATE_TEXT" \
  'Issue の作成・更新'
check_contains "the gate forbids self review instead" "$GATE_TEXT" '自己レビュー'
check_contains "the gate forbids switching the delegation transport" "$GATE_TEXT" '切り替え'
check_contains "the gate forbids installing Herdr" "$GATE_TEXT" 'インストール'

# The gate is an instruction, so it points at the boundary document that says
# why a skill rule is not a technical block.
check_contains "the gate links the delegation boundary reference" "$GATE_TEXT" \
  '../herdr/references/technical-delegation-boundary.md'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
