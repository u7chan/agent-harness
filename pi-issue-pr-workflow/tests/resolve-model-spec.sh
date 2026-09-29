#!/usr/bin/env bash
# Live tests for scripts/resolve-model-spec.sh. These tests require an installed
# pi (and its model catalog); they are skipped when the `pi` command is absent,
# so the hermetic suite in tests/run.sh stays the CI baseline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$SKILL_DIR/scripts/resolve-model-spec.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/model-spec-live-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_eq() {
  local name="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$name" || ng "$name" "got '$got', want '$want'"
}

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle (got '$hay')" ;;
  esac
}

check_not_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ng "$name" "should NOT contain: $needle" ;;
    *) ok "$name" ;;
  esac
}

if ! command -v pi >/dev/null 2>&1; then
  printf 'SKIP: pi is not installed; live model-spec tests skipped\n'
  exit 0
fi

printf 'pi: %s (%s)\n' "$(command -v pi)" "$(pi --version 2>/dev/null || echo 'unknown version')"

# Runs the helper and captures stdout, stderr, and the exit status. The helper
# prints one key=value line even when the result is unresolved.
RC=0
OUT=""
ERR=""
capture() {
  local out_file err_file
  out_file="$(mktemp "$WORK/out.XXXXXX")"
  err_file="$(mktemp "$WORK/err.XXXXXX")"
  "$HELPER" "$@" >"$out_file" 2>"$err_file"
  RC=$?
  OUT="$(cat "$out_file")"
  ERR="$(cat "$err_file")"
  cat "$out_file" "$err_file" >> "$WORK/all-output.txt"
  rm -f "$out_file" "$err_file"
}

# Reads one field from the single output line. Field values never contain
# spaces; thinking_level_map is compact JSON.
kv() { # $1=output line $2=key
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]${2}=\([^[:space:]]*\).*/\1/p"
}

check_single_line() { # name
  local name="$1"
  check_eq "$name prints one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
}

# Case 1: opencode-go/deepseek-v4.1-flash max is supported and stays effective.
capture --provider opencode-go --model deepseek-v4.1-flash --thinking max
check_single_line "case 1"
check_eq "case 1 exits ok" "$RC" "0"
check_eq "case 1 result" "$(kv "$OUT" result)" "ok"
check_eq "case 1 requested" "$(kv "$OUT" requested)" "max"
check_eq "case 1 effective" "$(kv "$OUT" effective)" "max"
check_contains "case 1 supported includes max" ",$(kv "$OUT" supported)," ",max,"

# Case 2: the same model clamps the unsupported medium request to another level.
capture --provider opencode-go --model deepseek-v4.1-flash --thinking medium
check_single_line "case 2"
if [ "$RC" -ne 0 ]; then
  ok "case 2 unresolved exits nonzero"
else
  ng "case 2 unresolved exits nonzero" "expected nonzero exit, got $RC"
fi
check_eq "case 2 result" "$(kv "$OUT" result)" "clamped"
check_eq "case 2 requested" "$(kv "$OUT" requested)" "medium"
effective="$(kv "$OUT" effective)"
if [ -n "$effective" ] && [ "$effective" != "medium" ]; then
  ok "case 2 effective is a different level ($effective)"
else
  ng "case 2 effective is a different level" "got '$effective'"
fi
check_contains "case 2 supported includes the effective level" ",$(kv "$OUT" supported)," ",$effective,"

# Case 3: openai-codex/gpt-6-astra high is supported and stays effective.
capture --provider openai-codex --model gpt-6-astra --thinking high
check_single_line "case 3"
check_eq "case 3 exits ok" "$RC" "0"
check_eq "case 3 result" "$(kv "$OUT" result)" "ok"
check_eq "case 3 effective" "$(kv "$OUT" effective)" "high"

# Case 4: an unknown model is unresolved instead of fuzzy-matched.
capture --provider opencode-go --model definitely-not-a-model-221 --thinking max
check_single_line "case 4"
if [ "$RC" -ne 0 ]; then
  ok "case 4 exits nonzero"
else
  ng "case 4 exits nonzero" "expected nonzero exit, got $RC"
fi
check_eq "case 4 result" "$(kv "$OUT" result)" "unknown"
check_eq "case 4 supported is empty" "$(kv "$OUT" supported)" ""
check_eq "case 4 effective is empty" "$(kv "$OUT" effective)" ""

# Credentials, API keys, and auth paths must never appear in any output.
ALL_OUTPUT="$(cat "$WORK/all-output.txt")"
for needle in 'sk-' 'apiKey' 'api_key' 'secret' 'credentials' '/home/' '.pi/agent'; do
  check_not_contains "helper output has no '$needle'" "$ALL_OUTPUT" "$needle"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
