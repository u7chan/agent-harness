#!/usr/bin/env bash
# Hermetic documentation contract for the ui-tester evidence rules: the return
# format carries the artifacts and their verification items, screenshots are
# the default, a video is WebM-only for time-direction claims, ffmpeg stays
# optional, and posting the evidence belongs to the orchestrator.
#
# These tests read the skill's Markdown only: no pi, no network, no browser.
# pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
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
  'belongs to the item above it'
check_contains "a visual item returns at least one artifact" "$ROLE_TEXT" \
  'required for every item whose'
check_contains "a video timeline is optional and video-only" "$ROLE_TEXT" \
  'optional, video-only, and written for the orchestrator'

# --- evidence rules --------------------------------------------------------

check_contains "screenshots are the default evidence" "$ROLE_TEXT" \
  'Default to screenshots'
check_contains "video is for time-direction claims only" "$ROLE_TEXT" \
  'only for a claim that lives in time'
check_contains "the video format is WebM" "$ROLE_TEXT" 'WebM'
check_contains "GIF is out of scope" "$ROLE_TEXT" 'Never produce a GIF'
check_contains "text overlays are out of scope" "$ROLE_TEXT" 'drawtext'
check_contains "artifacts live under PW_ARTIFACT_DIR" "$ROLE_TEXT" \
  'Keep every artifact under `PW_ARTIFACT_DIR`'
check_contains "the attachment limit is 10 MB" "$ROLE_TEXT" '10 MB'
check_contains "ffmpeg is optional" "$ROLE_TEXT" 'ffmpeg is optional'
check_contains "a dropped video is recorded as a fallback" "$ROLE_TEXT" \
  'fall back to screenshots and record the fallback'
check_contains "artifact names describe the content" "$ROLE_TEXT" \
  'name it after its content'
check_contains "the delegation body carries the evidence contract" "$ROLE_TEXT" \
  'the [evidence](#evidence) contract'

# --- role boundary ---------------------------------------------------------

check_contains "ui-tester does not post PR comments" "$SKILL_TEXT" 'post PR comments'
check_contains "the reference states who posts the evidence" "$ROLE_TEXT" \
  'posting belongs to the orchestrator'
check_contains "the orchestrator checks sizes before posting" "$ROLE_TEXT" \
  'checks the size of every artifact before it posts'
check_contains "SKILL.md defers to the evidence contract" "$SKILL_TEXT" \
  'references/ui-tester-role.md#evidence'

# --- dependencies ----------------------------------------------------------

# ffmpeg stays optional: it is not a prerequisite command of this repository.
check_not_contains "ffmpeg is not a README dependency row" "$README_TEXT" '| ffmpeg |'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
