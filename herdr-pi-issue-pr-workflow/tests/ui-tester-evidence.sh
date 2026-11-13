#!/usr/bin/env bash
# Hermetic documentation contract for the ui-tester evidence rules: the return
# format carries the artifacts and their verification items, screenshots are
# the default, a video is WebM-only for time-direction claims, ffmpeg stays
# optional, and reflecting the evidence in the PR body belongs to the orchestrator.
#
# These tests read the skill's Markdown only: no pi, no network, no browser.
# herdr-pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
ROLE_REFERENCE="$SKILL_DIR/references/ui-tester-role.md"
README="$SKILL_DIR/../README.md"

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

SKILL_TEXT="$(cat "$SKILL_MD")"
ROLE_TEXT="$(cat "$ROLE_REFERENCE")"
README_TEXT="$(cat "$README")"

# --- return format ---------------------------------------------------------

# The orchestrator reads these lines to build the PR comment, so the field
# names and the positional item-to-artifact mapping are the contract.
check_contains "return format documents artifact lines" "$ROLE_TEXT" \
  'artifact: <absolute path> | <media type> | <bytes> | screenshot | video'
check_contains "return format documents video timelines" "$ROLE_TEXT" \
  'timeline: <start>-<end> <step> / <start>-<end> <step>'
check_contains "return format documents fallbacks" "$ROLE_TEXT" \
  'fallback: video -> screenshots; <reason>'
check_contains "artifact lines belong to the item above them" "$ROLE_TEXT" \
  'その上の項目に属する'
check_contains "a visual item returns at least one artifact" "$ROLE_TEXT" \
  '視覚的な全項目で必須'
check_contains "a video timeline is optional and video-only" "$ROLE_TEXT" \
  '任意で動画専用'

# --- evidence rules --------------------------------------------------------

check_contains "screenshots are the default evidence" "$ROLE_TEXT" \
  '既定はスクリーンショット'
check_contains "video is for time-direction claims only" "$ROLE_TEXT" \
  '時間に依存する主張'
check_contains "video is for time-direction claims only" "$ROLE_TEXT" \
  'にだけ使う'
check_contains "the video format is WebM" "$ROLE_TEXT" 'WebM'
check_contains "GIF is out of scope" "$ROLE_TEXT" 'GIF を生成せず'
check_contains "video text overlays are out of scope" "$ROLE_TEXT" '動画にテキストを焼き込まない'
check_contains "still marks are allowed" "$ROLE_TEXT" '静止画の印'
check_contains "before/after stills carry marks" "$ROLE_TEXT" '変更箇所の印を付ける'
check_contains "the capture procedure is a pointer" "$ROLE_TEXT" 'playwright/references/evidence.md'
check_contains "the workflow scopes the overlay ban to video" "$SKILL_TEXT" '静止画の印は可'
check_contains "the delegation body asks for marks" "$ROLE_TEXT" '静止画の印。'
check_contains "artifacts live under PW_ARTIFACT_DIR" "$ROLE_TEXT" \
  'すべての成果物を `PW_ARTIFACT_DIR` の下に置き'
check_contains "the attachment limit is 10 MB" "$ROLE_TEXT" '10 MB'
check_contains "ffmpeg is optional" "$ROLE_TEXT" 'ffmpeg は任意'
check_contains "a dropped video is recorded as a fallback" "$ROLE_TEXT" \
  'スクリーンショットへフォールバックし'
check_contains "a dropped video is recorded as a fallback" "$ROLE_TEXT" \
  'フォールバックを返却に記録'
check_contains "artifact names describe the content" "$ROLE_TEXT" \
  '内容に基づいて名前を付ける'
check_contains "the delegation body carries the evidence contract" "$ROLE_TEXT" \
  '[evidence](#evidence) 契約'
check_contains "repository-required evidence includes the ui-tester" "$ROLE_TEXT" \
  '変更内容にかかわらず証跡を要求'

# --- role boundary ---------------------------------------------------------

check_contains "ui-tester does not post PR comments" "$SKILL_TEXT" 'PR コメント投稿を行わない'
check_contains "the reference states who reflects the evidence" "$ROLE_TEXT" \
  '反映は orchestrator に属する'
check_contains "the orchestrator checks sizes before reflecting" "$ROLE_TEXT" \
  '本文へ反映する前にすべての成果物のサイズを確認する'
check_contains "SKILL.md defers to the evidence contract" "$SKILL_TEXT" \
  'references/ui-tester-role.md#evidence'

# --- evidence posting ------------------------------------------------------

# The comment shape the orchestrator builds from the return: the marker keys
# the head, images carry alt text, videos stay standalone, and every
# attachment is referenced so the post-write check stays decidable.
check_contains "the marker carries the full head SHA" "$ROLE_TEXT" \
  '<!-- pi:ui-evidence:start head=<head SHA> -->'
check_contains "the evidence section has an end marker" "$ROLE_TEXT" \
  '<!-- pi:ui-evidence:end -->'
check_contains "the orchestrator reflects the returned artifacts" "$ROLE_TEXT" \
  'orchestrator は返却された成果物を PR 本文の証跡節へ反映'
check_contains "the evidence is never posted as a comment" "$ROLE_TEXT" \
  '証跡コメントは投稿しない'
check_contains "a previous evidence section is reused only when covered" "$ROLE_TEXT" \
  '前回の証跡節の画像を再利用'
check_contains "images are inline references with alt text" "$ROLE_TEXT" \
  'alt テキスト付きのインライン参照'
check_contains "videos render as standalone players" "$ROLE_TEXT" \
  '動画は単独の段落'
check_contains "every attachment is referenced" "$ROLE_TEXT" \
  'すべての添付を参照する'
check_contains "the body update defers to the shared contract" "$ROLE_TEXT" \
  '_docs/pr-evidence.md'

# The orchestrator's posting procedure: one comment per head, an explicit
# grant, a pre-post existence and size check, and no guessing on failures.
check_contains "the orchestrator reflects the returned evidence" "$SKILL_TEXT" \
  '返却された証跡は'
check_contains "the orchestrator reflects the returned evidence in the PR body" "$SKILL_TEXT" \
  'PR 本文の証跡節へ反映する'
check_contains "reflecting uses pr.create or pr.update" "$SKILL_TEXT" 'pr.create'
check_contains "reflecting uses pr.update" "$SKILL_TEXT" 'pr.update'
check_contains "the evidence is never posted as a comment" "$SKILL_TEXT" \
  '証跡コメントは投稿しない'
check_contains "reflecting carries an explicit grant" "$SKILL_TEXT" '明示的な `grant`'
check_contains "a previous evidence section is reused only when covered" "$SKILL_TEXT" \
  '今回返却された全項目をすでに列挙している'
check_contains "a fix push updates the evidence head" "$SKILL_TEXT" \
  '修正 push で head が変わった'
check_contains "the body is re-read before updating" "$SKILL_TEXT" \
  '更新直前に `pr.read` で本文を読み'
check_contains "the marker carries the current head" "$SKILL_TEXT" '現在 head の完全な SHA'
check_contains "artifacts are checked before reflecting" "$SKILL_TEXT" \
  '本文へ反映する前に成果物の存在'
check_contains "attachment pre-write errors keep the deterministic codes" "$SKILL_TEXT" \
  'MISSING_DEPENDENCY'
check_contains "attachment pre-write errors keep the deterministic codes" "$SKILL_TEXT" \
  'ATTACH_UNSUPPORTED'
check_contains "attachment pre-write errors keep the deterministic codes" "$SKILL_TEXT" \
  'ATTACH_INVALID'
check_contains "attachment pre-write errors stop without retrying" "$SKILL_TEXT" \
  '`retryable=false`'
check_contains "attachment pre-write errors stop without retrying" "$SKILL_TEXT" \
  '再試行不能な書き込み前エラー'
check_contains "unknown_outcome is not guessed" "$SKILL_TEXT" \
  '`unknown_outcome` は不明として扱い'
check_contains "completion requires the attached evidence" "$SKILL_TEXT" \
  '現在の head を指す PR 本文の証跡節に証拠が添付'
check_contains "completion never ignores a passed item" "$SKILL_TEXT" \
  '添付証拠がないまま完了を報告しない'

# --- dependencies ----------------------------------------------------------

# ffmpeg stays optional: it is not a prerequisite command of this repository.
check_not_contains "ffmpeg is not a README dependency row" "$README_TEXT" '| ffmpeg |'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
