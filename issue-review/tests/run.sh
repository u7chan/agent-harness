#!/usr/bin/env bash
# Hermetic documentation contract for the issue-review start gate: the skill
# stops before any side effect when the Herdr preflight does not pass, keeps
# the herdr skill authoritative for the conditions themselves, and keeps the
# existing review-and-file flow reachable after the gate.
#
# These tests read the skill's Markdown only: no pi, no Herdr, no network, no
# GitHub. They are an instruction contract, not proof of a technical block:
# SKILL.md is guidance to an agent and the gate has no enforcement path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
HERDR_SKILL_MD="$SKILL_DIR/../herdr/SKILL.md"

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
[ -f "$HERDR_SKILL_MD" ] || { printf 'FAIL missing %s\n' "$HERDR_SKILL_MD" >&2; exit 1; }

SKILL_TEXT="$(cat "$SKILL_MD")"
GATE_TEXT="$(section_text "$SKILL_MD" "## 開始前チェック")"

# --- the gate exists and precedes every side effect ------------------------

check_contains "the skill documents a start gate section" "$SKILL_TEXT" "## 開始前チェック"

# The gate is only a gate while it runs first: the artifact file, the pane
# work, and the GitHub writes all live below it.
GATE_LINE="$(section_line "$SKILL_MD" "## 開始前チェック")"
ARTIFACT_LINE="$(section_line "$SKILL_MD" "## 成果物ファイル")"
PROCEDURE_LINE="$(section_line "$SKILL_MD" "## 手順")"

if [ -n "$GATE_LINE" ]; then
  ok "the gate section has a position"
else
  ng "the gate section has a position" "## 開始前チェック not found"
fi

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

check_contains "the gate defers to the herdr skill" "$GATE_TEXT" "../herdr/SKILL.md"
check_contains "the gate names the herdr preflight" "$GATE_TEXT" '`Preflight`'
check_contains "the gate names the herdr caller pinning" "$GATE_TEXT" '`Caller pinning`'
check_contains "the gate forbids a second definition" "$GATE_TEXT" '再定義しない'

# The three conditions of the Issue are listed, but the check commands
# themselves are not copied: herdr/SKILL.md stays the only source of them.
check_contains "the gate requires HERDR_ENV=1" "$GATE_TEXT" '`HERDR_ENV=1`'
check_contains "the gate requires the herdr command" "$GATE_TEXT" '`herdr` コマンドが利用できる'
check_contains "the gate requires both caller IDs" "$GATE_TEXT" '`HERDR_WORKSPACE_ID`'
check_contains "the gate requires the pane ID too" "$GATE_TEXT" '`HERDR_PANE_ID`'
check_contains "the gate requires an ID format check" "$GATE_TEXT" '形式が有効'
check_contains "the gate requires the workspace consistency check" "$GATE_TEXT" '整合している'
check_not_contains "the gate does not copy the herdr preflight command" "$GATE_TEXT" \
  'test "${HERDR_ENV:-}" = 1'
check_not_contains "the gate does not copy the herdr command probe" "$GATE_TEXT" \
  'command -v herdr'

# --- stop conditions before any side effect --------------------------------

check_contains "an unmet condition stops the run" "$GATE_TEXT" '条件を満たさない'
check_contains "a failed or unknown check is not treated as success" "$GATE_TEXT" \
  '失敗・不明'
check_contains "an unknown result is not normalized to success" "$GATE_TEXT" '正常扱いしない'

# The side effects named by the Issue must all wait for the gate.
check_contains "the gate blocks the body file" "$GATE_TEXT" '`成果物ファイル` の作成'
check_contains "the gate blocks pane creation" "$GATE_TEXT" 'ペイン作成'
check_contains "the gate blocks agent startup" "$GATE_TEXT" 'エージェント起動'
check_contains "the gate blocks review delegation" "$GATE_TEXT" 'レビュー委譲'
check_contains "the gate blocks the GitHub write" "$GATE_TEXT" 'Issue の作成・更新'
check_contains "the gate scopes the block to every step below it" "$GATE_TEXT" \
  'このチェックを通るまで'

# The stop report explains the cause and states that nothing was started.
check_contains "the stop report explains the cause" "$GATE_TEXT" '会話言語で説明する'
check_contains "the stop report states nothing was started" "$GATE_TEXT" \
  '処理を開始していないこと'
check_contains "the stop report states no body file was written" "$GATE_TEXT" \
  'Issue 本文ファイルを作っていないこと'
check_contains "the stop report states no GitHub write happened" "$GATE_TEXT" \
  'Issue の作成・更新をしていないこと'

# No silent substitution: no self review, no other transport, no install.
check_contains "the gate forbids self review instead" "$GATE_TEXT" '自己レビューへの置き換え'
check_contains "the gate forbids switching the delegation transport" "$GATE_TEXT" \
  '別の委譲方式への自動切り替え'
check_contains "the gate forbids installing Herdr" "$GATE_TEXT" 'Herdr の自動インストール'
check_not_contains "the gate does not allow a fallback review path" "$GATE_TEXT" '自己レビューで代替'
check_not_contains "the gate does not allow an install attempt" "$GATE_TEXT" 'インストールして再試行'

# The gate is an instruction, and the skill does not claim it enforces
# anything technically.
check_contains "the gate states it is an instruction" "$GATE_TEXT" '操作指示であり'
check_contains "the gate denies being a technical block" "$GATE_TEXT" '技術的な遮断になるわけではない'
check_contains "the gate links the delegation boundary reference" "$GATE_TEXT" \
  '../herdr/references/technical-delegation-boundary.md'

# --- the existing flow survives the gate -----------------------------------

check_contains "the artifact file path is unchanged" "$SKILL_TEXT" '/tmp/<topic>-issue.md'
check_contains "the pane setup step is kept" "$SKILL_TEXT" '### 1. レビュアーのペインを用意する'
check_contains "the first delegation step is kept" "$SKILL_TEXT" '### 2. 1 回目を委譲する'
check_contains "the convergence step is kept" "$SKILL_TEXT" '### 4. LGTM まで収束させる'
check_contains "the filing step is kept" "$SKILL_TEXT" '### 5. Issue を確定する'
check_contains "the notes repeat the gate" "$SKILL_TEXT" '開始前チェックを通っていない場合は'

# The gate must stay out of the herdr skill's territory: the operating
# sections keep delegating to it instead of inlining pane commands elsewhere.
check_contains "the procedure delegates delegation to the herdr skill" "$SKILL_TEXT" \
  'の `scripts/parent-delegate-async.sh` を使う'

# herdr/SKILL.md stays the authority the gate points at.
check_contains "herdr keeps its own preflight heading" "$(cat "$HERDR_SKILL_MD")" '## Preflight'
check_contains "herdr keeps its own caller pinning heading" "$(cat "$HERDR_SKILL_MD")" \
  '## Caller pinning'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
