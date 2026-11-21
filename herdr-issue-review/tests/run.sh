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

subsection_text() { # file heading (a level-3 heading, stopped by ## or ###)
  awk -v heading="$2" '
    $0 == heading { inside = 1; next }
    inside && /^#{2,3} / { exit }
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
REVIEWER_TEXT="$(subsection_text "$SKILL_MD" "### 1. レビュアーのペインと起動 spec を用意する")"
BRIEF_TEXT="$(subsection_text "$SKILL_MD" "### 5. 人間レビュー用サマリを付ける")"
BRIEF_LINE="$(section_line "$SKILL_MD" "### 5. 人間レビュー用サマリを付ける")"
CONFIRM_LINE="$(section_line "$SKILL_MD" "### 6. Issue を確定する")"
DELEGATION_TEXT="$(subsection_text "$SKILL_MD" "### 2. 1 回目を委譲する")"
CONFIRM_TEXT="$(subsection_text "$SKILL_MD" "### 6. Issue を確定する")"

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

# --- the reviewer starts from the effective profile ------------------------

# The reviewer specification is the effective profile's `review`, overlaid with
# the user's explicit values only, and the composed specification is re-checked
# before the agent starts.
check_contains "the reviewer section names the effective profile" "$REVIEWER_TEXT" \
  '実効プロファイル'
check_contains "the reviewer section links the shared profiles contract" "$REVIEWER_TEXT" \
  '../_docs/pi-development.md'
check_contains "the reviewer section resolves the review role" "$REVIEWER_TEXT" \
  'scripts/pi-development/team-record.sh resolve --only-role review'
check_contains "the reviewer section bases the spec on the profile review" "$REVIEWER_TEXT" \
  'review=<harness>:<...>'
check_contains "the reviewer section names the Pi canonical form" "$REVIEWER_TEXT" \
  'pi:<provider>/<model>/<thinking>'
check_contains "the reviewer section names the Claude canonical form" "$REVIEWER_TEXT" \
  'claude:<model>/<effort>/<permission_mode>'
check_contains "the reviewer section overlays only the user values per harness" "$REVIEWER_TEXT" \
  'ユーザー指定はハーネス別にだけ上書きする'
check_contains "the reviewer section refuses mixed harness values" "$REVIEWER_TEXT" \
  'ハーネスをまたぐ指定'
check_contains "the reviewer section allows a same-harness partial override" "$REVIEWER_TEXT" \
  'プロファイルが `result=ok` のときは、同じハーネスの範囲で指定されたフィールドだけを上書きし、指定されていない値はプロファイルから補う'
check_contains "the reviewer section stops a partial override without a profile" "$REVIEWER_TEXT" \
  'プロファイルが使えない場合の部分的に揃った指定は、プロファイルや推測で埋めずに停止する'
check_contains "the reviewer section re-validates per harness" "$REVIEWER_TEXT" \
  'scripts/pi-development/resolve-model-spec.sh --harness <pi|claude>'
check_contains "the reviewer section passes the Pi specification flags" "$REVIEWER_TEXT" \
  '--provider <provider> --model <model> --thinking <thinking>'
check_contains "the reviewer section passes the Claude specification flags" "$REVIEWER_TEXT" \
  '--model <model> --effort <effort> --permission-mode <permission_mode>'
check_contains "the reviewer section requires the exact Pi verification" "$REVIEWER_TEXT" \
  'verification=exact'
check_contains "the reviewer section requires the Claude postlaunch verification" "$REVIEWER_TEXT" \
  'verification=postlaunch'
check_contains "the reviewer section starts only after both checks" "$REVIEWER_TEXT" \
  '`result=ok` と `verification=exact`'
check_contains "the reviewer section stops for a non-ok user specification" "$REVIEWER_TEXT" \
  '再検証が `result=ok` でなければ停止する'

# A profile that cannot be used keeps a Pi-only fallback to the runtime values
# the caller's own session publishes; a partial specification or a Claude
# reviewer stops instead of being guessed.
check_contains "the reviewer section keeps the Pi environment fallback" "$REVIEWER_TEXT" \
  '実行環境の既定'
check_contains "the reviewer section derives the Pi fallback from the runtime" "$REVIEWER_TEXT" \
  '$PI_PROVIDER'
check_contains "the reviewer section reads all three Pi runtime values" "$REVIEWER_TEXT" \
  '"$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL"'
check_contains "the reviewer section stops on an incomplete Pi fallback" "$REVIEWER_TEXT" \
  '3 値が揃わない場合はフォールバックせず停止する'
check_contains "the reviewer section never falls back for Claude" "$REVIEWER_TEXT" \
  'Claude は既定へフォールバックしない'
check_contains "the reviewer section stops on a partial specification" "$REVIEWER_TEXT" \
  '不足をプロファイルや推測で埋めずに停止して確認する'
check_contains "the reviewer section validates a complete user specification" "$REVIEWER_TEXT" \
  'ユーザー指定が完全なら'
check_contains "the reviewer section fixes the fallback line" "$REVIEWER_TEXT" \
  'review: 実効プロファイルを使わず実行環境の既定で起動（profile=<missing|invalid|unresolved>）'
check_contains "the reviewer section marks the fallback line as Pi-only" "$REVIEWER_TEXT" \
  'この行は Pi 用であり、Claude では出さない'

# The reviewer starts through the shared launcher: the pane, the agent name,
# the canonical specification, and the launch context go to it as arguments,
# and the caller renames the pane itself.
check_contains "the reviewer section starts through the shared launcher" "$REVIEWER_TEXT" \
  'herdr/scripts/start-agent.sh <pane-id> herdr-issue-review'
check_contains "the reviewer section passes the canonical specification" "$REVIEWER_TEXT" \
  '--spec <harness>:<...>'
check_contains "the reviewer section passes the launch context" "$REVIEWER_TEXT" \
  '--profile <name|-> --role review'
check_contains "the reviewer section passes the source and origin" "$REVIEWER_TEXT" \
  '--spec-source <profile|explicit> --origin <explicit|active|default>'
check_contains "the reviewer section reserves spec-source profile for an unmodified spec" "$REVIEWER_TEXT" \
  '`review` の spec をそのまま使う場合だけ `--spec-source profile` にする'
check_contains "the reviewer section marks any override as explicit" "$REVIEWER_TEXT" \
  '明示上書きを 1 つでも適用した場合'
check_contains "the reviewer section separates spec_source from origin" "$REVIEWER_TEXT" \
  '`spec_source` と `origin` は別物'
check_contains "the reviewer section keeps the profile origin on an override" "$REVIEWER_TEXT" \
  '--profile default --role review --spec-source explicit --origin default'
check_contains "the reviewer section pins the partial-override precondition" "$REVIEWER_TEXT" \
  '土台のプロファイル `default` の `review` が Claude で、model と permission_mode が揃っている場合に限り'
check_contains "the reviewer section refuses a cross-harness example" "$REVIEWER_TEXT" \
  'ハーネスをまたぐ指定はこの形にできないため停止する'
check_contains "the reviewer section keeps the full-profile example" "$REVIEWER_TEXT" \
  '--spec-source profile --origin default'
check_contains "the reviewer section reuses the launch pane ID" "$REVIEWER_TEXT" \
  '起動に使った pane ID をそのまま使い'
check_contains "the reviewer section states the launcher does not return JSON" "$REVIEWER_TEXT" \
  '共有ランチャーは JSON を返さず'
check_contains "the reviewer section states the launcher stderr lines" "$REVIEWER_TEXT" \
  '`launch:` 行（Claude は `probe:` と `effective:` も）を stderr に出す'
check_not_contains "the reviewer section does not depend on a JSON response" "$REVIEWER_TEXT" \
  'JSON 応答'
check_contains "the reviewer section keeps the caller-side rename" "$REVIEWER_TEXT" \
  'herdr pane rename <pane-id> herdr-issue-review'
check_not_contains "the reviewer section does not start agents directly" "$REVIEWER_TEXT" \
  '--kind pi'
check_not_contains "the reviewer section does not name a raw agent start" "$REVIEWER_TEXT" \
  'herdr agent start'

# The harness preflight and the harness-specific effective check replace the
# Pi-only launch check. The trust stop line is a fixed line shared with the
# launcher.
check_contains "the reviewer section requires the Pi CLI" "$REVIEWER_TEXT" \
  'Pi は `pi` が使える'
check_contains "the reviewer section checks the Claude login state" "$REVIEWER_TEXT" \
  'claude auth status'
check_contains "the reviewer section checks the Claude skills location" "$REVIEWER_TEXT" \
  '~/.claude/skills'
check_contains "the reviewer section fixes the trust stop line" "$REVIEWER_TEXT" \
  'claude-trust: <path> が未承認です。そのディレクトリで claude を一度起動し、trust を承認してから再実行してください。'
check_contains "the reviewer section makes Pi print the effective line" "$REVIEWER_TEXT" \
  "printf 'effective: harness=pi provider=%s model=%s effort=- thinking=%s permission_requested=- requested=pi:%s/%s/%s"
check_contains "the reviewer section matches the Pi effective line to the launch" "$REVIEWER_TEXT" \
  '`launch:` 行と照合'
check_contains "the reviewer section treats the footer as auxiliary" "$REVIEWER_TEXT" \
  'footer だけで一致とみなさない'
check_contains "the reviewer section uses the launcher effective line for Claude" "$REVIEWER_TEXT" \
  'stderr に出す最後の `effective:` 行'
check_contains "the reviewer section refuses launch arguments as evidence" "$REVIEWER_TEXT" \
  '起動引数だけを証拠にしない'
check_contains "the reviewer section stops without an effective line" "$REVIEWER_TEXT" \
  'レビュー結果を採用せずに停止する'

# The user's explicit values outrank the profile.
check_contains "the preconditions let the user override the profile" \
  "$(section_text "$SKILL_MD" "## 前提")" 'ユーザーが明示指定した値はプロファイルより優先する'

# --- the human review brief (contract: _docs/human-brief.md) --------------

check_contains "the artifact file points at the shared brief contract" \
  "$(section_text "$SKILL_MD" "## 成果物ファイル")" '../_docs/human-brief.md'
check_contains "the delegation skips the brief" "$DELEGATION_TEXT" \
  'Issue 本文の `pi:human-brief` 範囲は読まない'

if [ -n "$BRIEF_LINE" ] && [ -n "$CONFIRM_LINE" ] && [ "$BRIEF_LINE" -lt "$CONFIRM_LINE" ]; then
  ok "the brief is prepared before the issue is filed"
else
  ng "the brief is prepared before the issue is filed" \
    "brief line '${BRIEF_LINE:-none}' confirm line '${CONFIRM_LINE:-none}'"
fi

check_contains "the brief uses the explained contract" "$BRIEF_TEXT" '../_docs/human-brief.md'
check_contains "the brief uses the explain-video renderer" "$BRIEF_TEXT" '../explain-video/SKILL.md'
check_contains "the brief supports a GIF" "$BRIEF_TEXT" 'GIF'
check_contains "the brief supports an MP4" "$BRIEF_TEXT" 'MP4'
check_contains "the brief is marked" "$BRIEF_TEXT" '`pi:human-brief`'
check_contains "the brief is attached" "$BRIEF_TEXT" 'attachments'
check_contains "the issue marker omits head" "$BRIEF_TEXT" \
  'Issue の開始マーカーには `head` を付けない'
check_contains "the brief heading is exempt from the review-record ban" \
  "$(section_text "$SKILL_MD" "## 成果物ファイル")" 'この禁止の対象外'
check_contains "a missing renderer falls back to text" "$BRIEF_TEXT" \
  'FFmpeg または Playwright が使えない場合'
check_contains "the issue is read back after writing" "$CONFIRM_TEXT" 'issue.get'
check_contains "the issue write can carry attachments" "$CONFIRM_TEXT" 'attachments'
check_contains "the issue update replaces only the marker range" "$CONFIRM_TEXT" \
  '行頭のマーカー間だけを差し替える'
check_contains "the issue readback counts only HTML comment markers" "$CONFIRM_TEXT" \
  '行頭の HTML コメントの開始と終了マーカーが 1 対だけ'
check_contains "the issue readback excludes code spans" "$CONFIRM_TEXT" \
  'コード Span や引用はマーカーとして数えない'
check_contains "the issue purity check excludes the fixed heading" "$CONFIRM_TEXT" \
  '固定見出しと確認観点を除き'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
