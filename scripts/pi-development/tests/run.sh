#!/usr/bin/env bash
# Hermetic tests for the shared development helpers. These tests do not
# require pi and do not touch the network: the model-spec classification module
# is imported directly, the wrapper is driven only with an unresolved pi
# package root, the Claude paths are validated by shape and enumeration only,
# the auth preflight runs against a fake `claude` on PATH, and
# tests/team-record.sh replaces the model-spec resolver with a stub through
# --resolver while it exercises the team-profile helper.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="$SCRIPT_DIR/../lib/model-spec.mjs"
HELPER="$SCRIPT_DIR/../resolve-model-spec.sh"
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

# --- harness-aware resolution ----------------------------------------------

# One field of the single output line. A leading space lets the same pattern
# read a field that comes first (harness).
kv_line() { # output key
  printf ' %s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle (got: $hay)" ;;
  esac
}

# A Pi request keeps every existing field and now names the harness and the
# verification method. The unresolved-root case exercises the contract without
# an installed pi.
out="$("$HELPER" --provider opencode-go --model deepseek-v4.1-flash --thinking high \
  --pi-root "$empty_root" 2>"$WORK/harness-pi.err")"
check_eq "pi record names the harness" "$(kv_line "$out" harness)" "pi"
check_eq "pi record names the exact verification" "$(kv_line "$out" verification)" "exact"
check_eq "pi record keeps provider" "$(kv_line "$out" provider)" "opencode-go"
check_not_contains "pi record has no permission mode" "$out" "permission_mode="
out="$("$HELPER" --harness pi --provider opencode-go --model deepseek-v4.1-flash --thinking high \
  --pi-root "$empty_root" 2>"$WORK/harness-pi-explicit.err")"
check_eq "an explicit pi harness matches the default" "$(kv_line "$out" harness)" "pi"

# A Claude request is validated by shape and enumeration only: there is no
# installed catalog to match against, so the result is postlaunch and the
# effective values stay empty instead of claiming an exact match.
out="$("$HELPER" --harness claude --model claude-haiku-5-5 --effort high \
  --permission-mode auto 2>"$WORK/claude-ok.err")"
rc=$?
check_eq "claude ok exits zero" "$rc" "0"
check_eq "claude ok result" "$(kv_line "$out" result)" "ok"
check_eq "claude ok names the harness" "$(kv_line "$out" harness)" "claude"
check_eq "claude ok is postlaunch-verified" "$(kv_line "$out" verification)" "postlaunch"
check_eq "claude ok model" "$(kv_line "$out" model)" "claude-haiku-5-5"
check_eq "claude ok requested effort" "$(kv_line "$out" requested)" "high"
check_eq "claude ok permission mode" "$(kv_line "$out" permission_mode)" "auto"
check_eq "claude ok provider is empty" "$(kv_line "$out" provider)" ""
check_eq "claude ok reports no effective model" "$(kv_line "$out" effective)" ""
check_eq "claude ok prints one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
check_not_contains "claude record has no thinking map" "$out" "thinking_level_map="

# The Claude permission-mode default has one definition and is part of the
# vocabulary the resolver accepts.
default_mode="$(MODEL_SPEC_MODULE="$MODULE" node --input-type=module -e '
import { pathToFileURL } from "node:url";
const module = await import(pathToFileURL(process.env.MODEL_SPEC_MODULE).href);
process.stdout.write(
  module.CLAUDE_PERMISSION_MODES.includes(module.CLAUDE_DEFAULT_PERMISSION_MODE)
    ? module.CLAUDE_DEFAULT_PERMISSION_MODE
    : "not-in-vocabulary",
);
')"
check_eq "the Claude default permission mode is in the vocabulary" "$default_mode" "auto"

# Omitting the permission mode resolves to the default; the completed record is
# what a caller turns into a launch spec.
out="$("$HELPER" --harness claude --model claude-haiku-5-5 --effort high \
  2>"$WORK/claude-default-permission.err")"
rc=$?
check_eq "claude omitted permission mode exits zero" "$rc" "0"
check_eq "claude omitted permission mode result" "$(kv_line "$out" result)" "ok"
check_eq "claude omitted permission mode fills the default" "$(kv_line "$out" permission_mode)" "auto"
check_eq "claude omitted permission mode keeps the effort" "$(kv_line "$out" requested)" "high"

# An explicit empty value is a usage error, not an omission: the flag was given,
# so the default must not stand in for it.
out="$("$HELPER" --harness claude --model claude-haiku-5-5 --effort high \
  --permission-mode "" 2>"$WORK/claude-empty-permission.err")"
rc=$?
check_eq "claude empty permission mode is a usage error" "$rc" "2"
check_contains "claude empty permission mode names the flag" \
  "$(cat "$WORK/claude-empty-permission.err")" "--permission-mode requires a non-empty value"
check_eq "claude empty permission mode stays unresolved" "$(kv_line "$out" result)" "unknown"

# An omitted mode is not filled on a request that never reaches the permission
# check: the unknown record must not claim a value the run did not get to.
for missing in model effort; do
  if [ "$missing" = model ]; then
    case_args=(--harness claude --effort high)
  else
    case_args=(--harness claude --model claude-haiku-5-5)
  fi
  out="$("$HELPER" "${case_args[@]}" 2>"$WORK/claude-missing-$missing.err")"
  rc=$?
  check_eq "claude omitted mode with missing $missing exits 2" "$rc" "2"
  check_eq "claude omitted mode with missing $missing result" "$(kv_line "$out" result)" "unknown"
  check_eq "claude omitted mode with missing $missing leaves the mode empty" \
    "$(kv_line "$out" permission_mode)" ""
done

out="$("$HELPER" --harness claude --model haiku --effort max --permission-mode plan \
  2>"$WORK/claude-alias.err")"
rc=$?
check_eq "claude accepts an alias by shape" "$rc" "0"
check_eq "claude alias result" "$(kv_line "$out" result)" "ok"
check_eq "claude alias model is kept as given" "$(kv_line "$out" model)" "haiku"

out="$("$HELPER" --harness claude --model anthropic/claude-sonnet-4-5-20250929 \
  --effort xhigh --permission-mode acceptEdits 2>"$WORK/claude-slash.err")"
check_eq "claude accepts a slashed model" "$(kv_line "$out" result)" "ok"
check_eq "claude keeps the slashed model" "$(kv_line "$out" model)" "anthropic/claude-sonnet-4-5-20250929"

# Every rejected Claude request stays one unknown record with the postlaunch
# verification method, so a consumer never reads a failure as a launchable spec.
check_claude_invalid() { # name extra-needle cli-args...
  local name="$1" needle="$2" rc_out out
  shift 2
  out="$("$HELPER" "$@" 2>"$WORK/claude-invalid.err")"
  rc_out=$?
  check_eq "$name exits nonzero" "$([ "$rc_out" -ne 0 ] && echo yes || echo no)" "yes"
  check_eq "$name result" "$(kv_line "$out" result)" "unknown"
  check_eq "$name harness" "$(kv_line "$out" harness)" "claude"
  check_eq "$name verification" "$(kv_line "$out" verification)" "postlaunch"
  check_eq "$name prints one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
  if [ -n "$needle" ]; then
    check_contains "$name names the field" "$out" "$needle"
  fi
}

check_claude_invalid "claude off effort" "permission_mode=auto" \
  --harness claude --model claude-haiku-5-5 --effort off --permission-mode auto
check_claude_invalid "claude minimal effort" "" \
  --harness claude --model claude-haiku-5-5 --effort minimal --permission-mode auto
check_claude_invalid "claude bogus effort" "" \
  --harness claude --model claude-haiku-5-5 --effort extreme --permission-mode auto
check_claude_invalid "claude bypassPermissions" "permission_mode=bypassPermissions" \
  --harness claude --model claude-haiku-5-5 --effort high --permission-mode bypassPermissions
check_claude_invalid "claude unknown permission mode" "" \
  --harness claude --model claude-haiku-5-5 --effort high --permission-mode always
check_claude_invalid "claude empty permission mode" "" \
  --harness claude --model claude-haiku-5-5 --effort high --permission-mode ""
check_claude_invalid "claude missing effort" "" \
  --harness claude --model claude-haiku-5-5 --permission-mode auto
check_claude_invalid "claude missing model" "" \
  --harness claude --effort high --permission-mode auto
out="$("$HELPER" --harness claude --model claude-haiku-5-5 --effort high \
  --permission-mode auto --provider opencode-go 2>"$WORK/claude-mixed.err")"
rc=$?
check_eq "claude rejects a pi provider" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check_eq "claude rejects a pi provider result" "$(kv_line "$out" result)" "unknown"
out="$("$HELPER" --harness claude --model claude-haiku-5-5 --effort high \
  --permission-mode auto --thinking max 2>"$WORK/claude-mixed-thinking.err")"
check_eq "claude rejects a pi thinking level" "$(kv_line "$out" result)" "unknown"
out="$("$HELPER" --harness claude --model "$(printf 'bad\012model')" --effort high \
  --permission-mode auto 2>"$WORK/claude-newline-model.err")"
check_eq "claude rejects an unsafe model" "$(kv_line "$out" result)" "unknown"
check_eq "claude blanks an unsafe model" "$(kv_line "$out" model)" ""
out="$("$HELPER" --harness codex --model m 2>"$WORK/harness-unknown.err")"
rc=$?
check_eq "an unknown harness exits nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check_eq "an unknown harness result" "$(kv_line "$out" result)" "unknown"
check_eq "an unknown harness names no verification" "$(kv_line "$out" verification)" ""

# --- Claude auth preflight -------------------------------------------------

AUTH_HELPER="$SCRIPT_DIR/../claude-auth-status.sh"
FAKE_BIN="$WORK/fake-claude-bin"
EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$FAKE_BIN" "$EMPTY_BIN"

# Each fake is a hermetic stand-in for the real CLI: no network, no session,
# and the status document carries an email and an organization that must never
# reach the record.
fake_claude() { # name json rc
  local name="$1" document="$2" status="$3"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$*\" >> \"\$CLAUDE_AUTH_CALLS\"" "cat <<'JSON'" \
    "$document" 'JSON' "exit $status" > "$WORK/$name"
  chmod +x "$WORK/$name"
}

fake_claude claude-ok '{"loggedIn":true,"authMethod":"claude.ai","configDirectory":"/tmp/agent-harness-fake-claude","email":"leak@example.com","orgId":"leak-org-id","orgName":"Leak Org"}' 0
fake_claude claude-logged-out '{"loggedIn":false,"authMethod":"none","configDirectory":"/tmp/agent-harness-fake-claude"}' 1
fake_claude claude-status-failed '{"loggedIn":true,"configDirectory":"/tmp/agent-harness-fake-claude"}' 1
fake_claude claude-bad-json 'this is not json' 0
fake_claude claude-no-config '{"loggedIn":true}' 0
fake_claude claude-relative-config '{"loggedIn":true,"configDirectory":"relative/dir"}' 0
fake_claude claude-unsafe-config '{"loggedIn":true,"configDirectory":"/tmp/bad\nsecond-line"}' 0

use_fake_claude() { # name
  cp "$WORK/$1" "$FAKE_BIN/claude"
  chmod +x "$FAKE_BIN/claude"
}

auth_record() { # name
  local out rc_out
  CLAUDE_AUTH_CALLS="$WORK/claude-auth-calls-$1" \
    PATH="$FAKE_BIN:$PATH" "$AUTH_HELPER" >"$WORK/auth-$1.out" 2>"$WORK/auth-$1.err"
  rc_out=$?
  AUTH_OUT="$(cat "$WORK/auth-$1.out")"
  AUTH_RC="$rc_out"
}

auth_field() { # key
  kv_line "$AUTH_OUT" "$1"
}

use_fake_claude claude-ok
auth_record ok
check_eq "auth ok exits zero" "$AUTH_RC" "0"
check_eq "auth ok result" "$(auth_field result)" "ok"
check_eq "auth ok loggedIn" "$(auth_field loggedIn)" "true"
check_eq "auth ok config directory" "$(auth_field configDirectory)" "/tmp/agent-harness-fake-claude"
check_eq "auth ok prints one line" "$(printf '%s\n' "$AUTH_OUT" | wc -l | tr -d ' ')" "1"
check_eq "auth asks for the status subcommand" "$(cat "$WORK/claude-auth-calls-ok")" "auth status"
check_not_contains "auth output has no email" "$AUTH_OUT" "leak@example.com"
check_not_contains "auth output has no organization" "$AUTH_OUT" "leak-org-id"
check_not_contains "auth output has no organization name" "$AUTH_OUT" "Leak Org"
check_not_contains "auth output has no auth method" "$AUTH_OUT" "claude.ai"

use_fake_claude claude-logged-out
auth_record logged-out
check_eq "auth logged-out exits one" "$AUTH_RC" "1"
check_eq "auth logged-out result" "$(auth_field result)" "unauthenticated"
check_eq "auth logged-out loggedIn" "$(auth_field loggedIn)" "false"
check_eq "auth logged-out reason" "$(auth_field reason)" "not-logged-in"

use_fake_claude claude-status-failed
auth_record status-failed
check_eq "auth status-failed exits one" "$AUTH_RC" "1"
check_eq "auth status-failed result" "$(auth_field result)" "error"
check_eq "auth status-failed reason" "$(auth_field reason)" "status-failed"

use_fake_claude claude-bad-json
auth_record bad-json
check_eq "auth bad-json exits one" "$AUTH_RC" "1"
check_eq "auth bad-json result" "$(auth_field result)" "error"
check_eq "auth bad-json reason" "$(auth_field reason)" "bad-json"

use_fake_claude claude-no-config
auth_record no-config
check_eq "auth without a config directory reason" "$(auth_field reason)" "missing-config-directory"
check_eq "auth without a config directory reports no path" "$(auth_field configDirectory)" "-"

use_fake_claude claude-relative-config
auth_record relative-config
check_eq "auth relative config reason" "$(auth_field reason)" "config-directory-not-absolute"

use_fake_claude claude-unsafe-config
auth_record unsafe-config
check_eq "auth unsafe config reason" "$(auth_field reason)" "config-directory-unsafe"

PATH="$EMPTY_BIN" "$BASH" "$AUTH_HELPER" >"$WORK/auth-missing.out" 2>"$WORK/auth-missing.err"
AUTH_RC=$?
AUTH_OUT="$(cat "$WORK/auth-missing.out")"
check_eq "auth without claude exits one" "$AUTH_RC" "1"
check_eq "auth without claude result" "$(auth_field result)" "error"
check_eq "auth without claude reason" "$(auth_field reason)" "claude-missing"
check_eq "auth without claude prints one line" "$(printf '%s\n' "$AUTH_OUT" | wc -l | tr -d ' ')" "1"

"$AUTH_HELPER" --bogus >"$WORK/auth-usage.out" 2>"$WORK/auth-usage.err"
AUTH_RC=$?
AUTH_OUT="$(cat "$WORK/auth-usage.out")"
check_eq "auth rejects an argument" "$AUTH_RC" "2"
check_eq "auth argument error reason" "$(auth_field reason)" "usage"

# The team-profile helper has its own hermetic suite under the shared CI step.
printf '\n== team-record helper ==\n'
if "$TEAM_RECORD_TEST"; then
  ok "team-record helper tests"
else
  ng "team-record helper tests" "see the failing cases above"
fi

# The local profile editor (BFF and model master) has its own hermetic suite.
printf '\n== profile editor ==\n'
if "$SCRIPT_DIR/web.sh"; then
  ok "profile editor tests"
else
  ng "profile editor tests" "see the failing cases above"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
