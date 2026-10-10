#!/usr/bin/env bash
# Hermetic tests for the approved-team-record helper: scripts/lib/team-record.mjs,
# scripts/team-record.mjs, and the scripts/team-record.sh wrapper.
#
# These tests do not require pi and do not touch the network: the model-spec
# resolver is replaced through --resolver (a stub that reports the result the
# case needs), every record lives under a temporary PI_CODING_AGENT_DIR, and
# the path-derivation cases use repositories created by `git init` alone.
# pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$SKILL_DIR/scripts/team-record.sh"
MODULE="$SKILL_DIR/scripts/lib/team-record.mjs"
SKILL_MD="$SKILL_DIR/SKILL.md"
UI_TESTER_REFERENCE="$SKILL_DIR/references/ui-tester-role.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/team-record-test-XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# Every record path in this suite stays inside the work tree; the helper reads
# PI_CODING_AGENT_DIR for the record directory.
export PI_CODING_AGENT_DIR="$WORK/agent"

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

command -v node >/dev/null 2>&1 || {
  printf 'FAIL: node is required to run the team-record tests\n' >&2
  exit 1
}

# --- pure module -----------------------------------------------------------

# The record format and key derivation must stay usable without pi or the
# filesystem, so the module imports nothing but the sibling pure module.
LIB_SOURCE="$(cat "$MODULE")"
check_not_contains "record module does not import node" "$LIB_SOURCE" "from \"node:"
check_not_contains "record module does not import pi" "$LIB_SOURCE" "@earendil-works"

cat > "$WORK/lib-probe.mjs" <<'PROBE'
import { pathToFileURL } from "node:url";

const lib = await import(pathToFileURL(process.argv[2]).href);
let failures = 0;

function ok(name) {
  process.stdout.write(`ok ${name}\n`);
}

function ng(name, detail) {
  failures += 1;
  process.stdout.write(`FAIL ${name}: ${detail}\n`);
}

function eq(name, got, want) {
  const renderedGot = JSON.stringify(got);
  const renderedWant = JSON.stringify(want);
  if (renderedGot === renderedWant) {
    ok(name);
  } else {
    ng(name, `got ${renderedGot}, want ${renderedWant}`);
  }
}

function makeRoles(overrides = {}) {
  return {
    impl: { provider: "opencode-go", model: "deepseek-v4.1-flash", thinking: "high" },
    review: { provider: "openai-codex", model: "gpt-6-astra", thinking: "medium" },
    "pr-fix": { provider: "opencode-go", model: "deepseek-v4.1-flash", thinking: "high" },
    ...overrides,
  };
}

function valid(overrides = {}) {
  return { version: 1, pr_fix_shared_with_impl: true, roles: makeRoles(), ...overrides };
}

function reasonOf(raw) {
  const result = lib.validateRecord(raw);
  return result.result === "ok" ? `ok:${Object.keys(result.record.roles).join(",")}` : result.reason;
}

// parseRoleSpec: the provider is the first segment, the thinking level the
// last one, and the model everything between them.
eq("parseRoleSpec accepts a plain spec", lib.parseRoleSpec("opencode-go/deepseek-v4.1-flash/high"), {
  provider: "opencode-go",
  model: "deepseek-v4.1-flash",
  thinking: "high",
});
eq("parseRoleSpec keeps slashes in the model", lib.parseRoleSpec("openrouter/anthropic/claude-x/max"), {
  provider: "openrouter",
  model: "anthropic/claude-x",
  thinking: "max",
});
eq("parseRoleSpec rejects a missing segment", lib.parseRoleSpec("opencode-go/high"), null);
eq("parseRoleSpec rejects an empty model", lib.parseRoleSpec("opencode-go//high"), null);
eq("parseRoleSpec rejects an empty provider", lib.parseRoleSpec("/model/high"), null);
eq("parseRoleSpec rejects an unknown level", lib.parseRoleSpec("opencode-go/model/bogus"), null);
eq("parseRoleSpec rejects whitespace", lib.parseRoleSpec("opencode-go/deep seek/high"), null);
eq("parseRoleSpec rejects a non-string", lib.parseRoleSpec(null), null);
eq("parseRoleSpec rejects an empty string", lib.parseRoleSpec(""), null);
eq(
  "formatRoleSpec round-trips",
  lib.formatRoleSpec(lib.parseRoleSpec("opencode-go/deepseek-v4.1-flash/high")),
  "opencode-go/deepseek-v4.1-flash/high",
);

// readRoleSpec: strict about the stored shape, tolerant of extra keys.
eq("readRoleSpec accepts a stored spec", lib.readRoleSpec(makeRoles().impl), makeRoles().impl);
eq(
  "readRoleSpec ignores extra keys",
  lib.readRoleSpec({ ...makeRoles().impl, note: "ignored" }),
  makeRoles().impl,
);
eq("readRoleSpec rejects a slash in the provider", lib.readRoleSpec({ ...makeRoles().impl, provider: "open/ai" }), null);
eq("readRoleSpec rejects a missing level", lib.readRoleSpec({ provider: "opencode-go", model: "m" }), null);
eq("readRoleSpec rejects a non-object", lib.readRoleSpec("opencode-go/m/high"), null);

// validateRecord: what the reuse path may accept.
eq("validateRecord accepts the smallest record", reasonOf(valid()), "ok:impl,review,pr-fix");
eq(
  "validateRecord accepts a ui-tester",
  reasonOf(valid({ roles: makeRoles({ "ui-tester": { provider: "opencode-go", model: "m", thinking: "max" } }) })),
  "ok:impl,review,pr-fix,ui-tester",
);
eq(
  "validateRecord ignores unknown top-level keys",
  reasonOf({ ...valid(), note: "hand written", future_field: 1 }),
  "ok:impl,review,pr-fix",
);
eq(
  "validateRecord ignores unknown role keys",
  reasonOf({ ...valid(), roles: makeRoles({ reviewer: { provider: "opencode-go", model: "m", thinking: "max" } }) }),
  "ok:impl,review,pr-fix",
);
eq("validateRecord rejects a non-object", reasonOf(null), "bad-record");
eq("validateRecord rejects an array", reasonOf([]), "bad-record");
eq("validateRecord rejects an unknown version", reasonOf({ ...valid(), version: 2 }), "bad-version");
eq("validateRecord rejects a string version", reasonOf({ ...valid(), version: "1" }), "bad-version");
eq("validateRecord rejects a missing version", reasonOf({ pr_fix_shared_with_impl: true, roles: makeRoles() }), "bad-version");
eq("validateRecord rejects a missing shared flag", reasonOf({ version: 1, roles: makeRoles() }), "bad-shared");
eq("validateRecord rejects a string shared flag", reasonOf({ ...valid(), pr_fix_shared_with_impl: "true" }), "bad-shared");
eq("validateRecord rejects missing roles", reasonOf({ version: 1, pr_fix_shared_with_impl: true }), "bad-roles");
eq("validateRecord rejects an array roles", reasonOf({ version: 1, pr_fix_shared_with_impl: true, roles: [] }), "bad-roles");
eq(
  "validateRecord rejects a missing required role",
  reasonOf({ ...valid(), roles: { impl: makeRoles().impl, "pr-fix": makeRoles()["pr-fix"] } }),
  "missing-role",
);
eq(
  "validateRecord rejects a role that is not an object",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: "openai-codex/gpt-6-astra/medium" } }),
  "bad-role-spec",
);
eq(
  "validateRecord rejects an unknown thinking level",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: { ...makeRoles().review, thinking: "extreme" } } }),
  "bad-role-spec",
);
eq(
  "validateRecord rejects whitespace in a stored value",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: { ...makeRoles().review, thinking: "medium " } } }),
  "bad-role-spec",
);
eq(
  "validateRecord rejects a shared pr-fix with a different spec",
  reasonOf({ ...valid(), roles: { ...makeRoles(), "pr-fix": { provider: "opencode-go", model: "other", thinking: "high" } } }),
  "bad-shared",
);
eq(
  "validateRecord accepts a distinct pr-fix when not shared",
  reasonOf({
    ...valid({ pr_fix_shared_with_impl: false }),
    roles: { ...makeRoles(), "pr-fix": { provider: "opencode-go", model: "other", thinking: "high" } },
  }),
  "ok:impl,review,pr-fix",
);
eq(
  "validateRecord rejects an invalid optional role",
  reasonOf({ ...valid(), roles: makeRoles({ "ui-tester": { provider: "opencode-go", model: "" , thinking: "max" } }) }),
  "bad-role-spec",
);

// buildRecord: the canonical content the writer stores.
eq(
  "buildRecord keeps role order",
  Object.keys(lib.buildRecord(makeRoles({ "ui-tester": { provider: "opencode-go", model: "m", thinking: "max" } }), false).roles),
  ["impl", "review", "pr-fix", "ui-tester"],
);
eq("buildRecord stores the version", lib.buildRecord(makeRoles(), true).version, 1);
eq("buildRecord stores the shared flag", lib.buildRecord(makeRoles(), true).pr_fix_shared_with_impl, true);

// parseOriginKey: only a remote that names exactly owner/repo is usable.
eq("parseOriginKey reads an https remote", lib.parseOriginKey("https://github.com/u7chan/agent-harness.git"), "u7chan__agent-harness");
eq("parseOriginKey reads an https remote without .git", lib.parseOriginKey("https://github.com/u7chan/agent-harness"), "u7chan__agent-harness");
eq("parseOriginKey trims a trailing slash", lib.parseOriginKey("https://github.com/u7chan/agent-harness/"), "u7chan__agent-harness");
eq("parseOriginKey reads an scp-like remote", lib.parseOriginKey("git@github.com:u7chan/agent-harness.git"), "u7chan__agent-harness");
eq("parseOriginKey reads an ssh remote", lib.parseOriginKey("ssh://git@github.com/u7chan/agent-harness.git"), "u7chan__agent-harness");
eq("parseOriginKey reads a remote with a port", lib.parseOriginKey("https://github.com:443/u7chan/agent-harness.git"), "u7chan__agent-harness");
eq("parseOriginKey ignores the host", lib.parseOriginKey("https://gitlab.com/u7chan/agent-harness.git"), "u7chan__agent-harness");
eq("parseOriginKey rejects a nested path", lib.parseOriginKey("https://github.com/u7chan/agent-harness/tree/main"), null);
eq("parseOriginKey rejects a repository-only remote", lib.parseOriginKey("https://github.com/u7chan"), null);
eq("parseOriginKey rejects an empty segment", lib.parseOriginKey("https://github.com//agent-harness"), null);
eq("parseOriginKey rejects a dot segment", lib.parseOriginKey("https://github.com/u7chan/.."), null);
eq("parseOriginKey rejects a file remote", lib.parseOriginKey("file:///home/u/checkout.git"), null);
eq("parseOriginKey rejects a local path", lib.parseOriginKey("/home/u/checkout"), null);
eq("parseOriginKey rejects a bare owner/repo", lib.parseOriginKey("u7chan/agent-harness"), null);
eq("parseOriginKey rejects an empty value", lib.parseOriginKey(""), null);
eq("parseOriginKey rejects a non-string", lib.parseOriginKey(null), null);

// recordKeyFromPath and recordFileName: the fallback key stays one filename.
eq("recordKeyFromPath sanitizes a path", lib.recordKeyFromPath("/home/u/dev/repo"), "home-u-dev-repo");
eq("recordKeyFromPath sanitizes spaces", lib.recordKeyFromPath("/tmp/x y/z"), "tmp-x-y-z");
eq("recordKeyFromPath handles an empty path", lib.recordKeyFromPath(""), "repository-root");
eq("recordKeyFromPath handles the current directory", lib.recordKeyFromPath("."), "repository-root");
eq("recordFileName appends the suffix", lib.recordFileName("u7chan__agent-harness"), "u7chan__agent-harness.json");

process.exit(failures === 0 ? 0 : 1);
PROBE

PROBE_OUT="$(node "$WORK/lib-probe.mjs" "$MODULE" 2>"$WORK/lib-probe.err")"
PROBE_RC=$?
printf '%s\n' "$PROBE_OUT"
if [ "$PROBE_RC" -ne 0 ]; then
  printf 'FAIL %s\n     %s\n' "pure module probe exited nonzero" "$(cat "$WORK/lib-probe.err")"
  FAIL=$((FAIL + 1))
fi
PASS=$((PASS + $(printf '%s\n' "$PROBE_OUT" | grep -c '^ok ' || true)))
FAIL=$((FAIL + $(printf '%s\n' "$PROBE_OUT" | grep -c '^FAIL ' || true)))

# --- resolver stubs --------------------------------------------------------

cat > "$WORK/stub-ok.sh" <<'STUB'
#!/usr/bin/env bash
printf 'provider=stub model=stub requested=high supported=high effective=high result=ok thinking_level_map={}\n'
exit 0
STUB
cat > "$WORK/stub-mixed.sh" <<'STUB'
#!/usr/bin/env bash
model=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      model="${2:-}"
      shift
      [ "$#" -gt 0 ] && shift
      ;;
    *)
      shift
      ;;
  esac
done
case "$model" in
  unresolvable)
    result=unknown
    level=unknown
    rc=1
    ;;
  clamped-model)
    result=clamped
    level=high
    rc=1
    ;;
  *)
    result=ok
    level=high
    rc=0
    ;;
esac
printf 'provider=stub model=%s requested=high supported=high effective=%s result=%s thinking_level_map={}\n' "$model" "$level" "$result"
exit "$rc"
STUB
chmod +x "$WORK/stub-ok.sh" "$WORK/stub-mixed.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub-noexec.sh"
chmod -x "$WORK/stub-noexec.sh"

# --- record fixtures -------------------------------------------------------

RECORDS="$WORK/records"
mkdir -p "$RECORDS"
IMPL='{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"high"}'
REVIEW='{"provider":"openai-codex","model":"gpt-6-astra","thinking":"medium"}'
PRFIX='{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"high"}'
UI_TESTER='{"provider":"opencode-go","model":"deepseek-v4-flash","thinking":"max"}'
UNRESOLVABLE='{"provider":"opencode-go","model":"unresolvable","thinking":"high"}'
CLAMPED='{"provider":"opencode-go","model":"clamped-model","thinking":"high"}'

record() { # file json
  printf '%s\n' "$2" > "$RECORDS/$1"
}

record valid.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX}}"
record valid-ui-tester.json "{\"version\":1,\"pr_fix_shared_with_impl\":false,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX,\"ui-tester\":$UI_TESTER}}"
# Role keys this version does not know, including a previous name of a known
# role, are ignored: a run that needs such a role finds no role to reuse and
# returns to the proposal path.
record unknown-keys.json "{\"version\":1,\"note\":\"hand written\",\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX,\"reviewer\":$UI_TESTER,\"unknown\":{\"provider\":\"x\"}}}"
record bad-json.json 'not json'
record version2.json "{\"version\":2,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX}}"
record version-missing.json "{\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX}}"
record roles-missing.json '{"version":1,"pr_fix_shared_with_impl":true}'
record missing-review.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"pr-fix\":$PRFIX}}"
record role-not-object.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":\"openai-codex/gpt-6-astra/medium\",\"pr-fix\":$PRFIX}}"
record role-bad-thinking.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":{\"provider\":\"openai-codex\",\"model\":\"gpt-6-astra\",\"thinking\":\"extreme\"},\"pr-fix\":$PRFIX}}"
record role-whitespace.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":{\"provider\":\"openai-codex\",\"model\":\"gpt 6 astra\",\"thinking\":\"medium\"},\"pr-fix\":$PRFIX}}"
record shared-missing.json "{\"version\":1,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$PRFIX}}"
record shared-mismatch.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$REVIEW,\"pr-fix\":$REVIEW}}"
record unresolvable-model.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$UNRESOLVABLE,\"pr-fix\":$PRFIX}}"
record clamped-model.json "{\"version\":1,\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":$IMPL,\"review\":$CLAMPED,\"pr-fix\":$PRFIX}}"

# --- resolve ---------------------------------------------------------------

RC=0
OUT=""
ERR=""
capture() { # cli-args...
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

# Reads one field from the single output line.
kv() { # output key
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]${2}=\([^[:space:]]*\).*/\1/p"
}

check_single_line() { # name
  check_eq "$1 prints one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
}

check_nonzero() { # name
  if [ "$RC" -ne 0 ]; then
    ok "$1 exits nonzero"
  else
    ng "$1 exits nonzero" "expected nonzero exit, got $RC"
  fi
}

# A missing record: nothing to reuse, so the kickoff proposes and waits.
capture resolve --record "$RECORDS/absent.json" --resolver "$WORK/stub-ok.sh"
check_single_line "missing record"
check_nonzero "missing record"
check_eq "missing record result" "$(kv "$OUT" result)" "missing"
check_eq "missing record present" "$(kv "$OUT" present)" "false"
check_eq "missing record reason" "$(kv "$OUT" reason)" "absent"

# Invalid content: every shape violation returns to the proposal path.
check_invalid() { # name file expected-reason
  capture resolve --record "$RECORDS/$2" --resolver "$WORK/stub-ok.sh"
  check_single_line "$1"
  check_nonzero "$1"
  check_eq "$1 result" "$(kv "$OUT" result)" "invalid"
  check_eq "$1 reason" "$(kv "$OUT" reason)" "$3"
}

check_invalid "broken JSON" bad-json.json bad-json
check_invalid "unknown version" version2.json bad-version
check_invalid "missing version" version-missing.json bad-version
check_invalid "missing roles" roles-missing.json bad-roles
check_invalid "missing role key" missing-review.json missing-role
check_invalid "role is not an object" role-not-object.json bad-role-spec
check_invalid "role has an unknown level" role-bad-thinking.json bad-role-spec
check_invalid "role value has whitespace" role-whitespace.json bad-role-spec
check_invalid "missing shared flag" shared-missing.json bad-shared
check_invalid "shared pr-fix differs from impl" shared-mismatch.json bad-shared

# A directory in place of the record file is unreadable, not broken JSON.
capture resolve --record "$RECORDS" --resolver "$WORK/stub-ok.sh"
check_single_line "unreadable record"
check_nonzero "unreadable record"
check_eq "unreadable record result" "$(kv "$OUT" result)" "invalid"
check_eq "unreadable record reason" "$(kv "$OUT" reason)" "unreadable"

# The reuse path: recorded roles resolve, so the kickoff continues without a
# table and without an approval round.
capture resolve --record "$RECORDS/valid.json" --resolver "$WORK/stub-mixed.sh"
check_single_line "reusable record"
check_eq "reusable record exits ok" "$RC" "0"
check_eq "reusable record result" "$(kv "$OUT" result)" "ok"
check_eq "reusable record present" "$(kv "$OUT" present)" "true"
check_eq "reusable record shared flag" "$(kv "$OUT" pr_fix_shared_with_impl)" "true"
check_eq "reusable record impl" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"
check_eq "reusable record review" "$(kv "$OUT" review)" "openai-codex/gpt-6-astra/medium"
check_eq "reusable record pr-fix" "$(kv "$OUT" pr-fix)" "opencode-go/deepseek-v4.1-flash/high"

capture resolve --record "$RECORDS/valid-ui-tester.json" --resolver "$WORK/stub-mixed.sh"
check_eq "reusable record with ui-tester exits ok" "$RC" "0"
check_eq "reusable record tests the ui-tester spec" "$(kv "$OUT" ui-tester)" "opencode-go/deepseek-v4-flash/max"

# Unknown top-level and role keys are ignored, so a later role name does not
# break this reader; the role is simply absent and --require-role reports it.
capture resolve --record "$RECORDS/unknown-keys.json" --resolver "$WORK/stub-mixed.sh"
check_eq "unknown keys still reuse the record" "$RC" "0"
check_eq "unknown role key is not a known role" "$(kv "$OUT" ui-tester)" ""
check_eq "unknown role keys keep the required roles" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"
capture resolve --record "$RECORDS/unknown-keys.json" --resolver "$WORK/stub-mixed.sh" --require-role ui-tester
check_nonzero "required ui-tester absent from the record"
check_eq "required ui-tester result" "$(kv "$OUT" result)" "unresolved"
check_eq "required ui-tester is reported" "$(kv "$OUT" unresolved)" "ui-tester"
check_eq "required ui-tester reports absent" "$(kv "$OUT" unresolved_result)" "absent"

# One recorded role that does not resolve sends the kickoff back to the
# proposal path, and the other specifications stay visible for the proposal.
capture resolve --record "$RECORDS/unresolvable-model.json" --resolver "$WORK/stub-mixed.sh"
check_single_line "unresolvable role"
check_nonzero "unresolvable role"
check_eq "unresolvable role result" "$(kv "$OUT" result)" "unresolved"
check_eq "unresolvable role is reported" "$(kv "$OUT" unresolved)" "review"
check_eq "unresolvable role token" "$(kv "$OUT" unresolved_result)" "unknown"
check_eq "unresolvable role keeps impl for the proposal" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"

capture resolve --record "$RECORDS/clamped-model.json" --resolver "$WORK/stub-mixed.sh"
check_nonzero "clamped role"
check_eq "clamped role token" "$(kv "$OUT" unresolved_result)" "clamped"

# A resolver that cannot run is unresolved, never a silent success.
capture resolve --record "$RECORDS/valid.json" --resolver "$WORK/absent-resolver.sh"
check_single_line "missing resolver"
check_nonzero "missing resolver"
check_eq "missing resolver result" "$(kv "$OUT" result)" "unresolved"
check_eq "missing resolver token" "$(kv "$OUT" unresolved_result)" "error"
capture resolve --record "$RECORDS/valid.json" --resolver "$WORK/stub-noexec.sh"
check_nonzero "non-executable resolver"
check_eq "non-executable resolver token" "$(kv "$OUT" unresolved_result)" "error"

# --- write -----------------------------------------------------------------

json_field() { # file jq-style path
  node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = process.argv[2].split(".").reduce((current, key) => (current == null ? undefined : current[key]), data);
process.stdout.write(value === undefined ? "" : String(value));
' "$1" "$2"
}

file_mode() { # file
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

WRITE_TEAM=(--role impl=opencode-go/deepseek-v4.1-flash/high
  --role review=openai-codex/gpt-6-astra/medium
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high)

TARGET="$WORK/written/record.json"
rm -rf "$WORK/written"
capture write --record "$TARGET" --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_single_line "write creates the record"
check_eq "write exits ok" "$RC" "0"
check_eq "write result" "$(kv "$OUT" result)" "ok"
check_eq "write wrote" "$(kv "$OUT" written)" "true"
check_eq "write roles" "$(kv "$OUT" roles)" "impl,review,pr-fix"
check_eq "write reports the target" "$(kv "$OUT" record)" "$TARGET"
check_eq "write stores the version" "$(json_field "$TARGET" version)" "1"
check_eq "write stores the shared flag" "$(json_field "$TARGET" pr_fix_shared_with_impl)" "true"
check_eq "write stores the impl model" "$(json_field "$TARGET" roles.impl.model)" "deepseek-v4.1-flash"
check_eq "write stores the review thinking" "$(json_field "$TARGET" roles.review.thinking)" "medium"
check_eq "write mode is 0600" "$(file_mode "$TARGET")" "600"
check_not_contains "write leaves no temporary file" "$(ls -A "$WORK/written")" ".tmp"

# The written record is reusable as-is.
capture resolve --record "$TARGET" --resolver "$WORK/stub-mixed.sh"
check_eq "written record resolves" "$(kv "$OUT" result)" "ok"

# An existing record is replaced, and the replacement keeps mode 0600.
capture write --record "$TARGET" --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl false "${WRITE_TEAM[@]}" --role ui-tester=opencode-go/deepseek-v4-flash/max
check_eq "write replaces the record" "$RC" "0"
check_eq "write stores the ui-tester" "$(json_field "$TARGET" roles.ui-tester.model)" "deepseek-v4-flash"
check_eq "write replacement mode is 0600" "$(file_mode "$TARGET")" "600"
check_eq "replaced record reports the shared flag" "$(json_field "$TARGET" pr_fix_shared_with_impl)" "false"

# Rejected writes must not create or change the record file.
UNTOUCHED="$WORK/untouched/record.json"

capture write --record "$UNTOUCHED" --resolver "$WORK/stub-mixed.sh" --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high \
  --role review=opencode-go/unresolvable/high \
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high
check_nonzero "write with unresolvable role"
check_eq "write with unresolvable role result" "$(kv "$OUT" result)" "unresolved"
check_eq "write with unresolvable role written" "$(kv "$OUT" written)" "false"
check_eq "write with unresolvable role names the role" "$(kv "$OUT" unresolved)" "review"
if [ -e "$UNTOUCHED" ]; then
  ng "write with unresolvable role leaves no file" "found $UNTOUCHED"
else
  ok "write with unresolvable role leaves no file"
fi

check_write_invalid() { # name expected-reason cli-args...
  local name="$1" expected="$2"
  shift 2
  capture write --record "$WORK/invalid/record.json" --resolver "$WORK/stub-mixed.sh" "$@"
  check_nonzero "$name"
  check_eq "$name result" "$(kv "$OUT" result)" "invalid"
  check_eq "$name reason" "$(kv "$OUT" reason)" "$expected"
}

check_write_invalid "write without the shared flag" usage "${WRITE_TEAM[@]}"
check_write_invalid "write with a non-boolean shared flag" usage --pr-fix-shared-with-impl maybe "${WRITE_TEAM[@]}"
check_write_invalid "write without roles" missing-role --pr-fix-shared-with-impl true
check_write_invalid "write without a required role" missing-role --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high --role review=openai-codex/gpt-6-astra/medium
check_write_invalid "write with an unknown role name" unknown-role --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}" \
  --role reviewer=openai-codex/gpt-6-astra/medium
check_write_invalid "write with a malformed spec" bad-role-spec --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash --role review=openai-codex/gpt-6-astra/medium --role pr-fix=x/y/z
check_write_invalid "write with an unknown level" bad-role-spec --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/bogus --role review=openai-codex/gpt-6-astra/medium \
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high
check_write_invalid "write with a duplicated role" duplicate-role --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}" \
  --role review=openai-codex/gpt-6-astra/medium
check_write_invalid "write with a shared pr-fix that differs" bad-shared --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high --role review=openai-codex/gpt-6-astra/medium \
  --role pr-fix=opencode-go/deepseek-v4-flash/max

# A model ID may contain a slash: the provider is the first segment and the
# thinking level is the last one.
cat > "$WORK/stub-echo.sh" <<'STUB'
#!/usr/bin/env bash
provider=""
model=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) provider="${2:-}"; shift ;;
    --model) model="${2:-}"; shift ;;
  esac
  [ "$#" -gt 0 ] && shift
done
printf 'provider=%s model=%s requested=high supported=high effective=high result=ok thinking_level_map={}\n' "$provider" "$model"
exit 0
STUB
chmod +x "$WORK/stub-echo.sh"
capture write --record "$WORK/slash/record.json" --resolver "$WORK/stub-echo.sh" \
  --pr-fix-shared-with-impl true \
  --role impl=openrouter/anthropic/claude-x/max \
  --role review=openai-codex/gpt-6-astra/medium \
  --role pr-fix=openrouter/anthropic/claude-x/max
check_eq "write accepts a model with a slash" "$RC" "0"
check_eq "write stores the slashed model" "$(json_field "$WORK/slash/record.json" roles.impl.model)" "anthropic/claude-x"
check_eq "write stores the slashed provider" "$(json_field "$WORK/slash/record.json" roles.impl.provider)" "openrouter"

# Argument errors keep the one-line contract and exit 2.
capture write --record "$WORK/invalid/record.json" --resolver "$WORK/stub-mixed.sh" --pr-fix-shared-with-impl true \
  "${WRITE_TEAM[@]}" --bogus
check_single_line "write rejects an unknown argument"
check_eq "write rejects an unknown argument with usage" "$RC" "2"
check_eq "write rejects an unknown argument result" "$(kv "$OUT" result)" "invalid"
capture resolve --record "$RECORDS/valid.json" --resolver "$WORK/stub-mixed.sh" --bogus
check_eq "resolve rejects an unknown argument with usage" "$RC" "2"
capture resolve --record "$RECORDS/valid.json" --resolver
check_eq "resolve rejects a dangling option with usage" "$RC" "2"

# --- record path derivation ------------------------------------------------

ORIGIN_REPO="$WORK/repos/with-origin"
NO_ORIGIN_REPO="$WORK/repos/plain"
mkdir -p "$ORIGIN_REPO" "$NO_ORIGIN_REPO"
git -C "$ORIGIN_REPO" init -q
git -C "$ORIGIN_REPO" remote add origin git@github.com:u7chan/agent-harness.git

capture write --repo-root "$ORIGIN_REPO" --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_eq "write derives the key from origin" "$RC" "0"
check_eq "write uses the owner__repo key" "$(kv "$OUT" record)" \
  "$PI_CODING_AGENT_DIR/pi-issue-pr-workflow/teams/u7chan__agent-harness.json"
check_eq "derived record is written" "$(json_field "$PI_CODING_AGENT_DIR/pi-issue-pr-workflow/teams/u7chan__agent-harness.json" version)" "1"

capture resolve --repo-root "$NO_ORIGIN_REPO" --resolver "$WORK/stub-mixed.sh"
check_contains "a root without origin falls back to the path key" "$(kv "$OUT" record)" "pi-issue-pr-workflow/teams/"
check_contains "the fallback key derives from the root" "$(kv "$OUT" record)" "repos-plain.json"
check_eq "the fallback record is missing" "$(kv "$OUT" result)" "missing"

capture resolve --repo-root "$ORIGIN_REPO" --resolver "$WORK/stub-mixed.sh"
check_eq "the derived record resolves" "$(kv "$OUT" result)" "ok"

# --- skill documentation ---------------------------------------------------

SKILL_TEXT="$(cat "$SKILL_MD")"
check_contains "skill documents the record helper" "$SKILL_TEXT" "team-record.sh"
check_contains "skill documents the record location" "$SKILL_TEXT" 'PI_CODING_AGENT_DIR'
check_contains "skill documents the reuse line" "$SKILL_TEXT" "前回承認編成を使用"
check_contains "skill documents the report origin" "$SKILL_TEXT" "origin of the used team specification"
check_contains "skill documents the required role option" "$SKILL_TEXT" "--require-role"
check_contains "skill shows the ui-tester role in the reuse line" "$SKILL_TEXT" "[ui-tester=<provider>/<model>/<thinking>]"
check_contains "skill documents the composition reuse gate" "$SKILL_TEXT" "states the composition never reuses the record"
check_contains "skill documents writing the settled composition" "$SKILL_TEXT" "including the composition"

# An exclusion the user overrides never settles a composition, so the write
# keeps the approved ui-tester in the record instead of dropping it.
check_contains "skill never reads the participation decision as a composition" "$SKILL_TEXT" "decides this run's team only and never states the composition"
check_contains "skill keeps the reuse path for an overridden participation decision" "$SKILL_TEXT" "A participation decision the user overrode is not such a statement either"
check_contains "skill keeps an excluded ui-tester in the record" "$SKILL_TEXT" 'a recorded `ui-tester` that the participation decision excluded stays in the record'
check_contains "skill keeps the record whatever the exclusion's origin is" "$SKILL_TEXT" "whether the Issue derived the decision or the user overrode it in the same reply"
check_not_contains "skill no longer narrows the kept record to a derived exclusion" "$SKILL_TEXT" "only the participation decision excluded"

# Completion cleanup names the command for the one pane it may close.
UI_TESTER_TEXT="$(cat "$UI_TESTER_REFERENCE")"
check_contains "skill names the pane close command" "$SKILL_TEXT" '`herdr pane close <pane-id>`'
check_contains "skill rules out closing a whole tab or workspace" "$SKILL_TEXT" '`herdr tab close` and `herdr workspace close` are never used'
check_contains "ui-tester reference names the pane close command" "$UI_TESTER_TEXT" '`herdr pane close <pane-id>`'
check_contains "ui-tester reference scopes the close to the single pane" "$UI_TESTER_TEXT" '`herdr tab close` and `herdr workspace close` would close delegated'

# No output may leak the machine paths or credentials of the environment.
ALL_OUTPUT="$(cat "$WORK/all-output.txt" 2>/dev/null || true)"
for needle in 'sk-' 'apiKey' 'api_key' 'secret' 'credentials'; do
  check_not_contains "helper output has no '$needle'" "$ALL_OUTPUT" "$needle"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
