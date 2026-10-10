#!/usr/bin/env bash
# Hermetic tests for the pi-issue-pr-workflow helpers. These tests do not
# require pi and do not touch the network: the model-spec classification module
# is imported directly, the wrapper is driven only with an unresolved pi
# package root, and tests/team-record.sh replaces the model-spec resolver with a
# stub through --resolver while it exercises the approved-team-record helper.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE="$SKILL_DIR/scripts/lib/model-spec.mjs"
HELPER="$SKILL_DIR/scripts/resolve-model-spec.sh"
TEAM_RECORD_TEST="$SCRIPT_DIR/team-record.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/model-spec-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_eq() {
  local name="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$name" || ng "$name" "got '$got', want '$want'"
}

check_not_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ng "$name" "should NOT contain: $needle" ;;
    *) ok "$name" ;;
  esac
}

command -v node >/dev/null 2>&1 || {
  printf 'FAIL: node is required to run the model-spec tests\n' >&2
  exit 1
}

# The pure module must be importable without pi, so it must not import pi.
check_not_contains "pure module does not import pi" "$(cat "$MODULE")" "@earendil-works"

# classify(requested, supported, effective) is exercised through the real
# module; JSON-encoded arguments keep types and absent values unambiguous.
classify_case() { # name requested supported effective expected
  local name="$1" requested="$2" supported="$3" effective="$4" expected="$5" got rc
  got="$(MODEL_SPEC_MODULE="$MODULE" REQUESTED="$requested" SUPPORTED="$supported" EFFECTIVE="$effective" \
    node --input-type=module -e '
import { pathToFileURL } from "node:url";
const { classify } = await import(pathToFileURL(process.env.MODEL_SPEC_MODULE).href);
const value = classify(
  JSON.parse(process.env.REQUESTED),
  JSON.parse(process.env.SUPPORTED),
  JSON.parse(process.env.EFFECTIVE),
);
process.stdout.write(String(value));
' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ng "$name" "classify probe failed (rc=$rc): $got"
    return
  fi
  check_eq "$name" "$got" "$expected"
}

# ok: the requested level is supported.
classify_case "ok supported max" '"max"' '["low","high","max"]' '"max"' "ok"
classify_case "ok supported off" '"off"' '["off"]' '"off"' "ok"
classify_case "ok ignores effective" '"low"' '["low","high"]' '"high"' "ok"

# clamped: unsupported request with a different effective level from Pi.
classify_case "clamped medium to high" '"medium"' '["low","high","max"]' '"high"' "clamped"
classify_case "clamped off to low" '"off"' '["low","high","max"]' '"low"' "clamped"
classify_case "clamped xhigh to max" '"xhigh"' '["low","high","max"]' '"max"' "clamped"

# unsupported: the model reports no supported level (defensive, expected empty).
classify_case "unsupported empty" '"high"' '[]' 'null' "unsupported"
classify_case "unsupported wins over effective" '"high"' '[]' '"off"' "unsupported"

# unknown: invalid input or contradictory supported/effective pairs.
classify_case "unknown invalid requested" '"bogus"' '["low"]' '"low"' "unknown"
classify_case "unknown missing requested" 'null' '["low"]' '"low"' "unknown"
classify_case "unknown non-array supported" '"low"' '"low"' '"low"' "unknown"
classify_case "unknown non-level supported" '"low"' '["extreme"]' '"low"' "unknown"
classify_case "unknown missing effective" '"medium"' '["low","high"]' 'null' "unknown"
classify_case "unknown effective equals request" '"medium"' '["low","high"]' '"medium"' "unknown"

# An unresolved pi package root is result=unknown with a nonzero exit. This
# exercises the wrapper and the mjs output contract without an installed pi.
empty_root="$WORK/empty-pi-root"
mkdir -p "$empty_root"
printf '{}\n' > "$empty_root/package.json"
out="$("$HELPER" --provider opencode-go --model deepseek-v4.1-flash --thinking high \
  --pi-root "$empty_root" 2>"$WORK/unresolved.err")"
rc=$?
if [ "$rc" -ne 0 ]; then
  ok "unresolved root exits nonzero"
else
  ng "unresolved root exits nonzero" "expected nonzero exit, got $rc"
fi
case "$out" in
  *"result=unknown"*) ok "unresolved root reports result=unknown" ;;
  *) ng "unresolved root reports result=unknown" "output: $out" ;;
esac
check_eq "unresolved root keeps requested level" \
  "$(printf '%s\n' "$out" | sed -n 's/.* requested=\([^ ]*\).*/\1/p')" "high"
check_eq "unresolved root prints one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"

# Argument errors and unsafe values must still produce exactly one unknown
# record with a nonzero exit, including on the paths that never reach pi.
check_unknown_record() { # name rc out
  local name="$1" rc="$2" out="$3"
  if [ "$rc" -ne 0 ]; then
    ok "$name exits nonzero"
  else
    ng "$name exits nonzero" "expected nonzero exit, got $rc"
  fi
  case "$out" in
    *"result=unknown"*) ok "$name reports result=unknown" ;;
    *) ng "$name reports result=unknown" "output: $out" ;;
  esac
  check_eq "$name prints one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
}

# A dangling --pi-root must reach the shared argument-error path instead of
# exiting in the wrapper with no record.
out="$("$HELPER" --provider opencode-go --model deepseek-v4.1-flash --thinking max \
  --pi-root 2>"$WORK/dangling-root.err")"
rc=$?
check_unknown_record "dangling --pi-root" "$rc" "$out"
check_eq "dangling --pi-root keeps provider" \
  "$(printf '%s\n' "$out" | sed -n 's/.*provider=\([^ ]*\).*/\1/p')" "opencode-go"

# Values containing newlines must not split the record; the unsafe field is
# blanked and the result stays unknown.
out="$("$HELPER" --provider opencode-go --model "$(printf 'bad\012model')" --thinking max \
  2>"$WORK/newline-model.err")"
rc=$?
check_unknown_record "newline model" "$rc" "$out"
check_eq "newline model is blanked" \
  "$(printf '%s\n' "$out" | sed -n 's/.* model=\([^ ]*\).*/\1/p')" ""

out="$("$HELPER" --provider "$(printf 'bad\012provider')" --model deepseek-v4.1-flash --thinking max \
  2>"$WORK/newline-provider.err")"
rc=$?
check_unknown_record "newline provider" "$rc" "$out"
check_eq "newline provider is blanked" \
  "$(printf '%s\n' "$out" | sed -n 's/.*provider=\([^ ]*\).*/\1/p')" ""

out="$("$HELPER" --provider opencode-go --model deepseek-v4.1-flash \
  --thinking "$(printf 'max\012extra')" 2>"$WORK/newline-thinking.err")"
rc=$?
check_unknown_record "newline thinking" "$rc" "$out"

# The approved-team-record helper has its own hermetic suite; it runs here so
# the existing CI job covers it without a new step.
printf '\n== team-record helper ==\n'
if "$TEAM_RECORD_TEST"; then
  ok "team-record helper tests"
else
  ng "team-record helper tests" "see the failing cases above"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
