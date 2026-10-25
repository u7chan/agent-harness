#!/usr/bin/env bash
# Hermetic tests for the team-profile helper: scripts/lib/team-record.mjs,
# scripts/team-record.mjs, and the scripts/team-record.sh wrapper.
#
# These tests do not require pi and do not touch the network: the model-spec
# resolver is replaced through --resolver (a stub that reports the result the
# case needs), and every profile lives under a temporary PI_CODING_AGENT_DIR.
# herdr-pi-issue-pr-workflow/tests/run.sh runs this file as part of the skill suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$SKILL_DIR/scripts/team-record.sh"
MODULE="$SKILL_DIR/scripts/lib/team-record.mjs"
SKILL_MD="$SKILL_DIR/SKILL.md"
UI_TESTER_REFERENCE="$SKILL_DIR/references/ui-tester-role.md"
SEQUENTIAL_REFERENCE="$SKILL_DIR/references/sequential-runs.md"
MIGRATION_REFERENCE="$SKILL_DIR/references/team-profile-migration.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/team-record-test-XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
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

section_text() { # file heading
  awk -v heading="## $2" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

command -v node >/dev/null 2>&1 || {
  printf 'FAIL: node is required to run the team-record tests\n' >&2
  exit 1
}

# --- pure module -----------------------------------------------------------

# The profile format and the name rules must stay usable without pi or the
# filesystem, so the module imports nothing but the sibling pure module.
LIB_SOURCE="$(cat "$MODULE")"
check_not_contains "profile module does not import node" "$LIB_SOURCE" "from \"node:"
check_not_contains "profile module does not import pi" "$LIB_SOURCE" "@earendil-works"

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
  return { pr_fix_shared_with_impl: true, roles: makeRoles(), ...overrides };
}

function reasonOf(raw) {
  const result = lib.validateProfile(raw);
  return result.result === "ok" ? `ok:${Object.keys(result.profile.roles).join(",")}` : result.reason;
}

function activeReasonOf(text) {
  const result = lib.parseActiveContent(text);
  return result.result === "ok" ? `ok:${result.name}` : result.reason;
}

// Profile names: one filename segment of profiles/, without the extension.
eq("isProfileName accepts default", lib.isProfileName("default"), true);
eq("isProfileName accepts a dotted name", lib.isProfileName("gpt.6-sol_x-1"), true);
eq("isProfileName rejects the current directory", lib.isProfileName("."), false);
eq("isProfileName rejects the parent directory", lib.isProfileName(".."), false);
eq("isProfileName rejects a path separator", lib.isProfileName("a/b"), false);
eq("isProfileName rejects whitespace", lib.isProfileName("fall back"), false);
eq("isProfileName rejects an empty value", lib.isProfileName(""), false);
eq("isProfileName rejects a non-string", lib.isProfileName(null), false);
eq("profileFileName appends the suffix", lib.profileFileName("fallback"), "fallback.json");

// active: exactly one line, at most one trailing newline, a valid name.
eq("parseActiveContent accepts a trailing newline", activeReasonOf("fallback\n"), "ok:fallback");
eq("parseActiveContent accepts no trailing newline", activeReasonOf("fallback"), "ok:fallback");
eq("parseActiveContent accepts default", activeReasonOf("default\n"), "ok:default");
eq("parseActiveContent rejects an empty file", activeReasonOf(""), "bad-active");
eq("parseActiveContent rejects a bare newline", activeReasonOf("\n"), "bad-active");
eq("parseActiveContent rejects two lines", activeReasonOf("a\nb\n"), "bad-active");
eq("parseActiveContent rejects a second newline", activeReasonOf("fallback\n\n"), "bad-active");
eq("parseActiveContent rejects an invalid name", activeReasonOf("fall back\n"), "bad-active");
eq("parseActiveContent rejects a path", activeReasonOf("../x\n"), "bad-active");
eq("parseActiveContent rejects a dot", activeReasonOf(".\n"), "bad-active");
eq("parseActiveContent rejects a non-string", activeReasonOf(null), "bad-active");

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

// validateProfile: what the reuse path may accept.
eq("validateProfile accepts the smallest profile", reasonOf(valid()), "ok:impl,review,pr-fix");
eq(
  "validateProfile accepts a ui-tester",
  reasonOf(valid({ roles: makeRoles({ "ui-tester": { provider: "opencode-go", model: "m", thinking: "max" } }) })),
  "ok:impl,review,pr-fix,ui-tester",
);
eq(
  "validateProfile ignores unknown top-level keys",
  reasonOf({ ...valid(), note: "hand written", future_field: 1 }),
  "ok:impl,review,pr-fix",
);
eq(
  "validateProfile accepts a profile that still carries the removed version",
  reasonOf({ version: 1, ...valid() }),
  "ok:impl,review,pr-fix",
);
eq(
  "validateProfile ignores unknown role keys",
  reasonOf({ ...valid(), roles: makeRoles({ reviewer: { provider: "opencode-go", model: "m", thinking: "max" } }) }),
  "ok:impl,review,pr-fix",
);
eq("validateProfile rejects a non-object", reasonOf(null), "bad-record");
eq("validateProfile rejects an array", reasonOf([]), "bad-record");
eq("validateProfile rejects a missing shared flag", reasonOf({ roles: makeRoles() }), "bad-shared");
eq("validateProfile rejects a string shared flag", reasonOf({ ...valid(), pr_fix_shared_with_impl: "true" }), "bad-shared");
eq("validateProfile rejects missing roles", reasonOf({ pr_fix_shared_with_impl: true }), "bad-roles");
eq("validateProfile rejects an array roles", reasonOf({ pr_fix_shared_with_impl: true, roles: [] }), "bad-roles");
eq(
  "validateProfile rejects a missing required role",
  reasonOf({ ...valid(), roles: { impl: makeRoles().impl, "pr-fix": makeRoles()["pr-fix"] } }),
  "missing-role",
);
eq(
  "validateProfile rejects a role that is not an object",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: "openai-codex/gpt-6-astra/medium" } }),
  "bad-role-spec",
);
eq(
  "validateProfile rejects an unknown thinking level",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: { ...makeRoles().review, thinking: "extreme" } } }),
  "bad-role-spec",
);
eq(
  "validateProfile rejects whitespace in a stored value",
  reasonOf({ ...valid(), roles: { ...makeRoles(), review: { ...makeRoles().review, thinking: "medium " } } }),
  "bad-role-spec",
);
eq(
  "validateProfile rejects a shared pr-fix with a different spec",
  reasonOf({ ...valid(), roles: { ...makeRoles(), "pr-fix": { provider: "opencode-go", model: "other", thinking: "high" } } }),
  "bad-shared",
);
eq(
  "validateProfile accepts a distinct pr-fix when not shared",
  reasonOf({
    ...valid({ pr_fix_shared_with_impl: false }),
    roles: { ...makeRoles(), "pr-fix": { provider: "opencode-go", model: "other", thinking: "high" } },
  }),
  "ok:impl,review,pr-fix",
);
eq(
  "validateProfile rejects an invalid optional role",
  reasonOf({ ...valid(), roles: makeRoles({ "ui-tester": { provider: "opencode-go", model: "" , thinking: "max" } }) }),
  "bad-role-spec",
);

// buildProfile: the canonical content the writer stores.
eq(
  "buildProfile keeps role order",
  Object.keys(lib.buildProfile(makeRoles({ "ui-tester": { provider: "opencode-go", model: "m", thinking: "max" } }), false).roles),
  ["impl", "review", "pr-fix", "ui-tester"],
);
eq("buildProfile stores the shared flag", lib.buildProfile(makeRoles(), true).pr_fix_shared_with_impl, true);
eq(
  "buildProfile no longer stores a version",
  Object.prototype.hasOwnProperty.call(lib.buildProfile(makeRoles(), true), "version"),
  false,
);

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

# --- profile fixtures ------------------------------------------------------

IMPL='{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"high"}'
REVIEW='{"provider":"openai-codex","model":"gpt-6-astra","thinking":"medium"}'
PRFIX='{"provider":"opencode-go","model":"deepseek-v4.1-flash","thinking":"high"}'
UI_TESTER='{"provider":"opencode-go","model":"deepseek-v4-flash","thinking":"max"}'
UNRESOLVABLE='{"provider":"opencode-go","model":"unresolvable","thinking":"high"}'
CLAMPED='{"provider":"opencode-go","model":"clamped-model","thinking":"high"}'
ROLES='{"impl":'"$IMPL"',"review":'"$REVIEW"',"pr-fix":'"$PRFIX"'}'
ROLES_UI_TESTER='{"impl":'"$IMPL"',"review":'"$REVIEW"',"pr-fix":'"$PRFIX"',"ui-tester":'"$UI_TESTER"'}'

profile_json() { # shared roles-json
  printf '{"pr_fix_shared_with_impl":%s,"roles":%s}' "$1" "$2"
}

asset() { # agent-dir
  printf '%s/pi-issue-pr-workflow' "$1"
}

new_agent() { # name
  local dir="$WORK/agent-$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

put_profile() { # agent-dir name json
  mkdir -p "$(asset "$1")/profiles"
  printf '%s\n' "$3" > "$(asset "$1")/profiles/$2.json"
}

put_active() { # agent-dir content (printf %b escapes)
  mkdir -p "$(asset "$1")"
  printf '%b' "$2" > "$(asset "$1")/active"
  chmod 600 "$(asset "$1")/active"
}

active_content() { # agent-dir
  cat "$(asset "$1")/active" 2>/dev/null
}

# --- helper invocation -----------------------------------------------------

RC=0
OUT=""
ERR=""
capture() { # cli-args... (uses the already-exported PI_CODING_AGENT_DIR)
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

capture_in() { # agent-dir cli-args...
  local dir="$1" saved="${PI_CODING_AGENT_DIR-}"
  shift
  export PI_CODING_AGENT_DIR="$dir"
  capture "$@"
  export PI_CODING_AGENT_DIR="$saved"
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

check_exit() { # name expected
  check_eq "$1 exit status" "$RC" "$2"
}

# --- resolve: profile selection -------------------------------------------

# No profiles at all: nothing to reuse, so the kickoff proposes and waits.
D="$(new_agent no-profiles)"
capture_in "$D" resolve --resolver "$WORK/stub-ok.sh"
check_single_line "no profiles"
check_nonzero "no profiles"
check_eq "no profiles result" "$(kv "$OUT" result)" "missing"
check_eq "no profiles reason" "$(kv "$OUT" reason)" "no-profiles"
check_eq "no profiles reports no profile set" "$(kv "$OUT" profiles_present)" "false"
check_eq "no profiles reports the selected profile absent" "$(kv "$OUT" present)" "false"
check_eq "no profiles selects default" "$(kv "$OUT" profile)" "default"
check_eq "no profiles source is default" "$(kv "$OUT" source)" "default"
check_eq "no profiles names the would-be file" "$(kv "$OUT" record)" \
  "$(asset "$D")/profiles/default.json"

# An existing but empty profiles/ directory is the same state.
D="$(new_agent empty-profiles)"
mkdir -p "$(asset "$D")/profiles"
capture_in "$D" resolve --resolver "$WORK/stub-ok.sh"
check_eq "empty profiles dir result" "$(kv "$OUT" result)" "missing"
check_eq "empty profiles dir reason" "$(kv "$OUT" reason)" "no-profiles"
check_eq "empty profiles dir reports no profile set" "$(kv "$OUT" profiles_present)" "false"

# A non-JSON file does not count as a profile.
D="$(new_agent non-json-entry)"
mkdir -p "$(asset "$D")/profiles"
printf 'notes\n' > "$(asset "$D")/profiles/notes.txt"
capture_in "$D" resolve --resolver "$WORK/stub-ok.sh"
check_eq "a non-JSON entry is not a profile" "$(kv "$OUT" reason)" "no-profiles"
check_eq "a non-JSON entry keeps profiles_present false" "$(kv "$OUT" profiles_present)" "false"

# Only default.json, no active: default applies implicitly.
D="$(new_agent default-only)"
put_profile "$D" default "$(profile_json true "$ROLES")"
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_single_line "default profile"
check_exit "default profile exits ok" "0"
check_eq "default profile result" "$(kv "$OUT" result)" "ok"
check_eq "default profile name" "$(kv "$OUT" profile)" "default"
check_eq "default profile source" "$(kv "$OUT" source)" "default"
check_eq "default profile present" "$(kv "$OUT" present)" "true"
check_eq "default profile reports the set" "$(kv "$OUT" profiles_present)" "true"
check_eq "default profile shared flag" "$(kv "$OUT" pr_fix_shared_with_impl)" "true"
check_eq "default profile impl" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"
check_eq "default profile review" "$(kv "$OUT" review)" "openai-codex/gpt-6-astra/medium"
check_eq "default profile pr-fix" "$(kv "$OUT" pr-fix)" "opencode-go/deepseek-v4.1-flash/high"

# active selects the named profile, with or without a trailing newline.
D="$(new_agent active)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_profile "$D" fallback "$(profile_json true "$ROLES")"
put_active "$D" 'fallback\n'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_exit "active profile exits ok" "0"
check_eq "active profile result" "$(kv "$OUT" result)" "ok"
check_eq "active profile name" "$(kv "$OUT" profile)" "fallback"
check_eq "active profile source" "$(kv "$OUT" source)" "active"
check_eq "active profile file" "$(kv "$OUT" record)" "$(asset "$D")/profiles/fallback.json"

put_active "$D" 'fallback'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "active without a trailing newline still applies" "$(kv "$OUT" result)" "ok"
check_eq "active without a trailing newline keeps the name" "$(kv "$OUT" profile)" "fallback"

# An explicit --profile wins over active and reports source=explicit.
capture_in "$D" resolve --profile default --resolver "$WORK/stub-mixed.sh"
check_exit "explicit profile exits ok" "0"
check_eq "explicit profile name" "$(kv "$OUT" profile)" "default"
check_eq "explicit profile source" "$(kv "$OUT" source)" "explicit"
check_eq "explicit profile result" "$(kv "$OUT" result)" "ok"

# profiles_present=true with only the selected profile missing is not a
# no-profile state: the run returns to the proposal path with its own reason.
D="$(new_agent fallback-only)"
put_profile "$D" fallback "$(profile_json true "$ROLES")"
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_single_line "missing selected profile"
check_nonzero "missing selected profile"
check_eq "missing selected profile result" "$(kv "$OUT" result)" "missing"
check_eq "missing selected profile reason" "$(kv "$OUT" reason)" "missing-selected-profile"
check_eq "missing selected profile selects default" "$(kv "$OUT" profile)" "default"
check_eq "missing selected profile keeps profiles_present" "$(kv "$OUT" profiles_present)" "true"
check_eq "missing selected profile is absent" "$(kv "$OUT" present)" "false"

# active naming a missing profile is an error, never a silent default.
D="$(new_agent active-missing)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_active "$D" 'nope\n'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_nonzero "active names a missing profile"
check_eq "active missing profile result" "$(kv "$OUT" result)" "missing"
check_eq "active missing profile reason" "$(kv "$OUT" reason)" "missing-active-profile"
check_eq "active missing profile keeps the active name" "$(kv "$OUT" profile)" "nope"
check_eq "active missing profile does not fall back to default" "$(kv "$OUT" impl)" ""
check_eq "active missing profile is absent" "$(kv "$OUT" present)" "false"

# A broken active file is bad-active, whatever its shape.
check_bad_active() { # name content
  local name="$1" content="$2" dir
  dir="$(new_agent "bad-active-$name")"
  put_profile "$dir" default "$(profile_json true "$ROLES")"
  put_active "$dir" "$content"
  capture_in "$dir" resolve --resolver "$WORK/stub-mixed.sh"
  check_single_line "bad active: $name"
  check_nonzero "bad active: $name"
  check_eq "bad active: $name result" "$(kv "$OUT" result)" "invalid"
  check_eq "bad active: $name reason" "$(kv "$OUT" reason)" "bad-active"
  check_eq "bad active: $name profiles_present" "$(kv "$OUT" profiles_present)" "true"
}

check_bad_active empty ''
check_bad_active multi-line 'a\nb\n'
check_bad_active invalid-name 'fall back\n'
check_bad_active parent-dir '..\n'

# An explicit profile that is absent has its own reason.
D="$(new_agent explicit-missing)"
put_profile "$D" default "$(profile_json true "$ROLES")"
capture_in "$D" resolve --profile ghost --resolver "$WORK/stub-mixed.sh"
check_nonzero "explicit missing profile"
check_eq "explicit missing profile result" "$(kv "$OUT" result)" "missing"
check_eq "explicit missing profile reason" "$(kv "$OUT" reason)" "missing-explicit-profile"
check_eq "explicit missing profile source" "$(kv "$OUT" source)" "explicit"

# An explicit name that is not a profile name is an argument error.
check_bad_profile_name() { # name value
  local name="$1" value="$2" dir
  dir="$(new_agent "bad-name-$name")"
  put_profile "$dir" default "$(profile_json true "$ROLES")"
  capture_in "$dir" resolve --profile "$value" --resolver "$WORK/stub-mixed.sh"
  check_single_line "bad profile name: $name"
  check_exit "bad profile name: $name exits with a usage status" "2"
  check_eq "bad profile name: $name result" "$(kv "$OUT" result)" "invalid"
  check_eq "bad profile name: $name reason" "$(kv "$OUT" reason)" "bad-profile-name"
}

check_bad_profile_name dot '.'
check_bad_profile_name parent-dir '..'
check_bad_profile_name separator 'a/b'
check_bad_profile_name whitespace 'fall back'

# --- resolve: profile content ---------------------------------------------

check_invalid() { # name json expected-reason
  local name="$1" json="$2" expected="$3" dir
  dir="$(new_agent "invalid-$name")"
  put_profile "$dir" default "$json"
  capture_in "$dir" resolve --resolver "$WORK/stub-ok.sh"
  check_single_line "invalid profile: $name"
  check_nonzero "invalid profile: $name"
  check_eq "invalid profile: $name result" "$(kv "$OUT" result)" "invalid"
  check_eq "invalid profile: $name reason" "$(kv "$OUT" reason)" "$expected"
}

check_invalid "broken-json" 'not json' bad-json
check_invalid "array" '[]' bad-record
check_invalid "roles-missing" '{"pr_fix_shared_with_impl":true}' bad-roles
check_invalid "missing-role" \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"pr-fix":'"$PRFIX"'}}' missing-role
check_invalid "role-not-object" \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":"openai-codex/gpt-6-astra/medium","pr-fix":'"$PRFIX"'}}' bad-role-spec
check_invalid "role-bad-thinking" \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":{"provider":"openai-codex","model":"gpt-6-astra","thinking":"extreme"},"pr-fix":'"$PRFIX"'}}' bad-role-spec
check_invalid "role-whitespace" \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":{"provider":"openai-codex","model":"gpt 6 astra","thinking":"medium"},"pr-fix":'"$PRFIX"'}}' bad-role-spec
check_invalid "shared-missing" \
  '{"roles":{"impl":'"$IMPL"',"review":'"$REVIEW"',"pr-fix":'"$PRFIX"'}}' bad-shared
check_invalid "shared-mismatch" \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":'"$REVIEW"',"pr-fix":'"$REVIEW"'}}' bad-shared

# A profile that still carries the removed version key stays usable, because
# unknown top-level keys are ignored.
D="$(new_agent version-key)"
put_profile "$D" default '{"version":1,"pr_fix_shared_with_impl":true,"roles":'"$ROLES"'}'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_exit "a leftover version key still resolves" "0"
check_eq "a leftover version key keeps the roles" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"

# A directory in place of the profile file is unreadable, not broken JSON.
D="$(new_agent unreadable)"
mkdir -p "$(asset "$D")/profiles/default.json"
capture_in "$D" resolve --resolver "$WORK/stub-ok.sh"
check_nonzero "unreadable profile"
check_eq "unreadable profile result" "$(kv "$OUT" result)" "invalid"
check_eq "unreadable profile reason" "$(kv "$OUT" reason)" "unreadable"

# A role that does not resolve keeps the profile unreusable.
D="$(new_agent unresolvable)"
put_profile "$D" default \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":'"$UNRESOLVABLE"',"pr-fix":'"$PRFIX"'}}'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_single_line "unresolvable role"
check_nonzero "unresolvable role"
check_eq "unresolvable role result" "$(kv "$OUT" result)" "unresolved"
check_eq "unresolvable role reason" "$(kv "$OUT" reason)" "role"
check_eq "unresolvable role is reported" "$(kv "$OUT" unresolved)" "review"
check_eq "unresolvable role token" "$(kv "$OUT" unresolved_result)" "unknown"
check_eq "unresolvable role keeps impl for the proposal" "$(kv "$OUT" impl)" "opencode-go/deepseek-v4.1-flash/high"

D="$(new_agent clamped)"
put_profile "$D" default \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":'"$CLAMPED"',"pr-fix":'"$PRFIX"'}}'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_nonzero "clamped role"
check_eq "clamped role token" "$(kv "$OUT" unresolved_result)" "clamped"

# A resolver that cannot run is unresolved, never a silent success.
D="$(new_agent missing-resolver)"
put_profile "$D" default "$(profile_json true "$ROLES")"
capture_in "$D" resolve --resolver "$WORK/absent-resolver.sh"
check_single_line "missing resolver"
check_nonzero "missing resolver"
check_eq "missing resolver result" "$(kv "$OUT" result)" "unresolved"
check_eq "missing resolver token" "$(kv "$OUT" unresolved_result)" "error"
capture_in "$D" resolve --resolver "$WORK/stub-noexec.sh"
check_nonzero "non-executable resolver"
check_eq "non-executable resolver token" "$(kv "$OUT" unresolved_result)" "error"

# The optional ui-tester is reusable when present and reported absent when a
# run requires it and the profile does not provide it.
D="$(new_agent ui-tester)"
put_profile "$D" default "$(profile_json false "$ROLES_UI_TESTER")"
capture_in "$D" resolve --require-role ui-tester --resolver "$WORK/stub-mixed.sh"
check_exit "required ui-tester present exits ok" "0"
check_eq "required ui-tester is reusable" "$(kv "$OUT" ui-tester)" "opencode-go/deepseek-v4-flash/max"
check_eq "required ui-tester keeps the shared flag" "$(kv "$OUT" pr_fix_shared_with_impl)" "false"

put_profile "$D" default "$(profile_json true "$ROLES")"
capture_in "$D" resolve --require-role ui-tester --resolver "$WORK/stub-mixed.sh"
check_nonzero "required ui-tester absent from the profile"
check_eq "required ui-tester result" "$(kv "$OUT" result)" "unresolved"
check_eq "required ui-tester is reported" "$(kv "$OUT" unresolved)" "ui-tester"
check_eq "required ui-tester reports absent" "$(kv "$OUT" unresolved_result)" "absent"

# Unknown top-level and role keys are ignored, so a later role name does not
# break this reader; the role is simply absent for --require-role.
D="$(new_agent unknown-keys)"
put_profile "$D" default \
  '{"note":"hand written","pr_fix_shared_with_impl":true,"roles":'"$ROLES"',"reviewer":'"$UI_TESTER"',"unknown":{"provider":"x"}}'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_exit "unknown keys still reuse the profile" "0"
check_eq "unknown role key is not a known role" "$(kv "$OUT" ui-tester)" ""

# The removed options are gone: the helper reports them as argument errors.
D="$(new_agent removed-options)"
capture_in "$D" resolve --repo-root "$WORK" --resolver "$WORK/stub-ok.sh"
check_exit "--repo-root is rejected" "2"
check_eq "--repo-root is rejected as usage" "$(kv "$OUT" reason)" "usage"
capture_in "$D" resolve --record "$WORK/x.json" --resolver "$WORK/stub-ok.sh"
check_exit "--record is rejected" "2"
capture_in "$D" resolve --origin-url "https://github.com/u7dev/x.git" --resolver "$WORK/stub-ok.sh"
check_exit "--origin-url is rejected" "2"

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

# write creates one profile and never touches active.
D="$(new_agent write-create)"
capture_in "$D" write --profile default --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_single_line "write creates the profile"
check_eq "write exits ok" "$RC" "0"
check_eq "write result" "$(kv "$OUT" result)" "ok"
check_eq "write wrote" "$(kv "$OUT" written)" "true"
check_eq "write profile" "$(kv "$OUT" profile)" "default"
check_eq "write roles" "$(kv "$OUT" roles)" "impl,review,pr-fix"
check_eq "write reports the target" "$(kv "$OUT" record)" "$(asset "$D")/profiles/default.json"
check_eq "write stores the shared flag" "$(json_field "$(asset "$D")/profiles/default.json" pr_fix_shared_with_impl)" "true"
check_eq "write stores no version" "$(json_field "$(asset "$D")/profiles/default.json" version)" ""
check_eq "write stores the impl model" "$(json_field "$(asset "$D")/profiles/default.json" roles.impl.model)" "deepseek-v4.1-flash"
check_eq "write stores the review thinking" "$(json_field "$(asset "$D")/profiles/default.json" roles.review.thinking)" "medium"
check_eq "write mode is 0600" "$(file_mode "$(asset "$D")/profiles/default.json")" "600"
check_not_contains "write leaves no temporary file" "$(ls -A "$(asset "$D")/profiles")" ".tmp"
if [ -e "$(asset "$D")/active" ]; then
  ng "write does not create active" "found $(asset "$D")/active"
else
  ok "write does not create active"
fi

# The written profile is reusable as-is.
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "the written profile resolves" "$(kv "$OUT" result)" "ok"

# write leaves an existing active alone.
D="$(new_agent write-keeps-active)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_profile "$D" fallback "$(profile_json true "$ROLES")"
put_active "$D" 'fallback\n'
capture_in "$D" write --profile default --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl false "${WRITE_TEAM[@]}" --role ui-tester=opencode-go/deepseek-v4-flash/max
check_eq "write replaces the profile" "$RC" "0"
check_eq "write stores the ui-tester" "$(json_field "$(asset "$D")/profiles/default.json" roles.ui-tester.model)" "deepseek-v4-flash"
check_eq "write replacement mode is 0600" "$(file_mode "$(asset "$D")/profiles/default.json")" "600"
check_eq "write replacement reports the shared flag" "$(json_field "$(asset "$D")/profiles/default.json" pr_fix_shared_with_impl)" "false"
check_eq "write does not change active" "$(active_content "$D")" "fallback"
check_eq "write keeps active mode 0600" "$(file_mode "$(asset "$D")/active")" "600"

# Rejected writes must not create or change the profile file.
D="$(new_agent write-rejected)"
capture_in "$D" write --profile default --resolver "$WORK/stub-mixed.sh" --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high \
  --role review=opencode-go/unresolvable/high \
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high
check_nonzero "write with unresolvable role"
check_eq "write with unresolvable role result" "$(kv "$OUT" result)" "unresolved"
check_eq "write with unresolvable role written" "$(kv "$OUT" written)" "false"
check_eq "write with unresolvable role names the role" "$(kv "$OUT" unresolved)" "review"
if [ -e "$(asset "$D")/profiles/default.json" ]; then
  ng "write with unresolvable role leaves no file" "found $(asset "$D")/profiles/default.json"
else
  ok "write with unresolvable role leaves no file"
fi

check_write_invalid() { # name expected-reason cli-args...
  local name="$1" expected="$2" dir
  shift 2
  dir="$(new_agent "write-invalid-$name")"
  capture_in "$dir" write --resolver "$WORK/stub-mixed.sh" "$@"
  check_nonzero "write invalid: $name"
  check_eq "write invalid: $name result" "$(kv "$OUT" result)" "invalid"
  check_eq "write invalid: $name reason" "$(kv "$OUT" reason)" "$expected"
}

check_write_invalid "without-profile" usage --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_write_invalid "dot-name" bad-profile-name --profile . --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_write_invalid "path-name" bad-profile-name --profile a/b --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}"
check_write_invalid "without-shared-flag" usage --profile default "${WRITE_TEAM[@]}"
check_write_invalid "non-boolean-shared-flag" usage --profile default --pr-fix-shared-with-impl maybe "${WRITE_TEAM[@]}"
check_write_invalid "without-roles" missing-role --profile default --pr-fix-shared-with-impl true
check_write_invalid "without-a-required-role" missing-role --profile default --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high --role review=openai-codex/gpt-6-astra/medium
check_write_invalid "unknown-role" unknown-role --profile default --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}" \
  --role reviewer=openai-codex/gpt-6-astra/medium
check_write_invalid "malformed-spec" bad-role-spec --profile default --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash --role review=openai-codex/gpt-6-astra/medium --role pr-fix=x/y/z
check_write_invalid "unknown-level" bad-role-spec --profile default --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/bogus --role review=openai-codex/gpt-6-astra/medium \
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high
check_write_invalid "duplicate-role" duplicate-role --profile default --pr-fix-shared-with-impl true "${WRITE_TEAM[@]}" \
  --role review=openai-codex/gpt-6-astra/medium
check_write_invalid "shared-mismatch" bad-shared --profile default --pr-fix-shared-with-impl true \
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
D="$(new_agent write-slash)"
capture_in "$D" write --profile default --resolver "$WORK/stub-echo.sh" \
  --pr-fix-shared-with-impl true \
  --role impl=openrouter/anthropic/claude-x/max \
  --role review=openai-codex/gpt-6-astra/medium \
  --role pr-fix=openrouter/anthropic/claude-x/max
check_eq "write accepts a model with a slash" "$RC" "0"
check_eq "write stores the slashed model" "$(json_field "$(asset "$D")/profiles/default.json" roles.impl.model)" "anthropic/claude-x"
check_eq "write stores the slashed provider" "$(json_field "$(asset "$D")/profiles/default.json" roles.impl.provider)" "openrouter"

# Argument errors keep the one-line contract and exit 2.
D="$(new_agent write-args)"
capture_in "$D" write --profile default --resolver "$WORK/stub-mixed.sh" --pr-fix-shared-with-impl true \
  "${WRITE_TEAM[@]}" --bogus
check_single_line "write rejects an unknown argument"
check_exit "write rejects an unknown argument with a usage status" "2"
check_eq "write rejects an unknown argument result" "$(kv "$OUT" result)" "invalid"
capture_in "$D" resolve --profile default --resolver "$WORK/stub-mixed.sh" --bogus
check_exit "resolve rejects an unknown argument with a usage status" "2"
capture_in "$D" resolve --profile default --resolver
check_exit "resolve rejects a dangling option with a usage status" "2"

# --- use -------------------------------------------------------------------

# use switches active to a validated profile.
D="$(new_agent use)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_profile "$D" fallback "$(profile_json false "$ROLES_UI_TESTER")"
capture_in "$D" use fallback --resolver "$WORK/stub-mixed.sh"
check_single_line "use fallback"
check_eq "use fallback exits ok" "$RC" "0"
check_eq "use fallback result" "$(kv "$OUT" result)" "ok"
check_eq "use fallback wrote" "$(kv "$OUT" written)" "true"
check_eq "use fallback profile" "$(kv "$OUT" profile)" "fallback"
check_eq "use fallback names active" "$(kv "$OUT" active)" "$(asset "$D")/active"
check_eq "use fallback writes the name" "$(active_content "$D")" "fallback"
check_eq "use fallback mode is 0600" "$(file_mode "$(asset "$D")/active")" "600"
check_not_contains "use leaves no temporary file" "$(ls -A "$(asset "$D")")" ".tmp"

# The selected profile is what resolve now reports.
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "use fallback changes the selection" "$(kv "$OUT" profile)" "fallback"
check_eq "use fallback changes the source" "$(kv "$OUT" source)" "active"

# use never rewrites the profiles.
before_profiles="$(cat "$(asset "$D")/profiles/default.json"; cat "$(asset "$D")/profiles/fallback.json")"
capture_in "$D" use default --resolver "$WORK/stub-mixed.sh"
check_eq "use default exits ok" "$RC" "0"
check_eq "use default writes the name" "$(active_content "$D")" "default"
check_eq "use default keeps active mode 0600" "$(file_mode "$(asset "$D")/active")" "600"
after_profiles="$(cat "$(asset "$D")/profiles/default.json"; cat "$(asset "$D")/profiles/fallback.json")"
check_eq "use does not rewrite the profiles" "$after_profiles" "$before_profiles"

# A missing or invalid profile never changes active.
D="$(new_agent use-rejected)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_profile "$D" broken 'not json'
put_profile "$D" unresolvable \
  '{"pr_fix_shared_with_impl":true,"roles":{"impl":'"$IMPL"',"review":'"$UNRESOLVABLE"',"pr-fix":'"$PRFIX"'}}'
put_active "$D" 'default\n'

capture_in "$D" use ghost --resolver "$WORK/stub-mixed.sh"
check_nonzero "use a missing profile"
check_eq "use a missing profile result" "$(kv "$OUT" result)" "missing"
check_eq "use a missing profile reason" "$(kv "$OUT" reason)" "missing-explicit-profile"
check_eq "use a missing profile wrote nothing" "$(kv "$OUT" written)" "false"
check_eq "use a missing profile keeps active" "$(active_content "$D")" "default"

capture_in "$D" use broken --resolver "$WORK/stub-mixed.sh"
check_nonzero "use a broken profile"
check_eq "use a broken profile result" "$(kv "$OUT" result)" "invalid"
check_eq "use a broken profile reason" "$(kv "$OUT" reason)" "bad-json"
check_eq "use a broken profile keeps active" "$(active_content "$D")" "default"

capture_in "$D" use unresolvable --resolver "$WORK/stub-mixed.sh"
check_nonzero "use an unresolvable profile"
check_eq "use an unresolvable profile result" "$(kv "$OUT" result)" "unresolved"
check_eq "use an unresolvable profile names the role" "$(kv "$OUT" unresolved)" "review"
check_eq "use an unresolvable profile keeps active" "$(active_content "$D")" "default"

capture_in "$D" use .. --resolver "$WORK/stub-mixed.sh"
check_exit "use a bad name exits with a usage status" "2"
check_eq "use a bad name result" "$(kv "$OUT" result)" "invalid"
check_eq "use a bad name reason" "$(kv "$OUT" reason)" "bad-profile-name"
check_eq "use a bad name keeps active" "$(active_content "$D")" "default"

capture_in "$D" use --resolver "$WORK/stub-mixed.sh"
check_exit "use without a name is a usage error" "2"
check_eq "use without a name keeps active" "$(active_content "$D")" "default"

# use replaces an existing active atomically and leaves no temporary file.
capture_in "$D" use default --resolver "$WORK/stub-mixed.sh"
check_eq "use replaces an existing active" "$(active_content "$D")" "default"
check_eq "use keeps the replaced active at 0600" "$(file_mode "$(asset "$D")/active")" "600"
check_not_contains "use leaves no temporary file next to active" "$(ls -A "$(asset "$D")")" ".tmp"

# --- bootstrap -------------------------------------------------------------

# SKILL.md allows bootstrap only when result=missing, profiles_present=false,
# and source=default. These assertions mirror that rule.
bootstrap_allowed() { # output
  [ "$(kv "$1" result)" = "missing" ] &&
    [ "$(kv "$1" reason)" = "no-profiles" ] &&
    [ "$(kv "$1" profiles_present)" = "false" ] &&
    [ "$(kv "$1" source)" = "default" ]
}

check_bootstrap_allowed() { # name
  if bootstrap_allowed "$OUT"; then
    ok "$1 allows bootstrap"
  else
    ng "$1 allows bootstrap" "output: $OUT"
  fi
}

check_bootstrap_blocked() { # name
  if bootstrap_allowed "$OUT"; then
    ng "$1 blocks bootstrap" "output: $OUT"
  else
    ok "$1 blocks bootstrap"
  fi
}

# 1. An empty profiles/ is the only state that bootstraps.
D="$(new_agent bootstrap-empty)"
mkdir -p "$(asset "$D")/profiles"
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "bootstrap: empty profiles result" "$(kv "$OUT" result)" "missing"
check_eq "bootstrap: empty profiles reason" "$(kv "$OUT" reason)" "no-profiles"
check_bootstrap_allowed "bootstrap: empty profiles"

# 2. Only fallback.json exists, so default is missing for a different reason.
D="$(new_agent bootstrap-fallback-only)"
put_profile "$D" fallback "$(profile_json true "$ROLES")"
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "bootstrap: fallback only result" "$(kv "$OUT" result)" "missing"
check_eq "bootstrap: fallback only reason" "$(kv "$OUT" reason)" "missing-selected-profile"
check_bootstrap_blocked "bootstrap: fallback only"

# 3. active names a missing profile.
D="$(new_agent bootstrap-active-missing)"
put_profile "$D" default "$(profile_json true "$ROLES")"
put_active "$D" 'nope\n'
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "bootstrap: active missing reason" "$(kv "$OUT" reason)" "missing-active-profile"
check_bootstrap_blocked "bootstrap: active missing"

# 4. active is empty, multi-line, or an invalid name.
for bad_active in '' 'a\nb\n' 'fall back\n'; do
  label="$(printf '%s' "$bad_active" | tr -d '\n' | tr ' ' '-')"
  [ -n "$label" ] || label="empty"
  D="$(new_agent "bootstrap-active-$label")"
  put_profile "$D" default "$(profile_json true "$ROLES")"
  put_active "$D" "$bad_active"
  capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
  check_eq "bootstrap: active '$label' reason" "$(kv "$OUT" reason)" "bad-active"
  check_bootstrap_blocked "bootstrap: active '$label'"
done

# 5. The run names an explicit profile that is missing.
D="$(new_agent bootstrap-explicit-missing)"
capture_in "$D" resolve --profile ghost --resolver "$WORK/stub-mixed.sh"
check_eq "bootstrap: explicit missing reason" "$(kv "$OUT" reason)" "missing-explicit-profile"
check_bootstrap_blocked "bootstrap: explicit missing"

# 6. An existing invalid profile is never overwritten, and it blocks bootstrap.
D="$(new_agent bootstrap-invalid)"
put_profile "$D" default 'not json'
before_invalid="$(cat "$(asset "$D")/profiles/default.json")"
capture_in "$D" resolve --resolver "$WORK/stub-mixed.sh"
check_eq "bootstrap: invalid profile result" "$(kv "$OUT" result)" "invalid"
check_eq "bootstrap: invalid profile reason" "$(kv "$OUT" reason)" "bad-json"
check_bootstrap_blocked "bootstrap: invalid profile"
capture_in "$D" write --profile default --resolver "$WORK/stub-mixed.sh" \
  --pr-fix-shared-with-impl true \
  --role impl=opencode-go/deepseek-v4.1-flash/high \
  --role review=opencode-go/unresolvable/high \
  --role pr-fix=opencode-go/deepseek-v4.1-flash/high
check_nonzero "bootstrap: a rejected write fails"
check_eq "bootstrap: the invalid profile is unchanged" "$(cat "$(asset "$D")/profiles/default.json")" "$before_invalid"

# --- skill documentation ---------------------------------------------------

SKILL_TEXT="$(cat "$SKILL_MD")"
TEAM_TEXT="$(section_text "$SKILL_MD" "Team profiles")"
KICKOFF_TEXT="$(section_text "$SKILL_MD" "Kickoff gate")"
SEQUENTIAL_TEXT="$(cat "$SEQUENTIAL_REFERENCE")"
MIGRATION_TEXT="$(cat "$MIGRATION_REFERENCE")"

check_contains "skill documents the profile helper" "$SKILL_TEXT" "team-record.sh"
check_contains "skill documents the user asset location" "$SKILL_TEXT" 'PI_CODING_AGENT_DIR'
check_contains "skill documents the profiles directory" "$SKILL_TEXT" 'profiles/<name>.json'
check_contains "skill documents the active file" "$SKILL_TEXT" '`active`'
check_contains "skill documents the selection order" "$SKILL_TEXT" "Resolution order is this run's explicit profile, then \`active\`, then \`default\`"
check_contains "skill documents the use command" "$SKILL_TEXT" "team-record.sh use <name>"
check_contains "skill documents the write command" "$SKILL_TEXT" "team-record.sh write --profile <name>"
check_contains "skill documents the required role option" "$SKILL_TEXT" "--require-role"
check_contains "skill shows the ui-tester role in the reuse line" "$SKILL_TEXT" "[ui-tester=<provider>/<model>/<thinking>]"
check_contains "skill documents the composition reuse gate" "$SKILL_TEXT" "states the composition never reuses it"
check_contains "skill documents the report origin" "$SKILL_TEXT" "origin of the used team specification"
check_contains "skill documents the profile source of the reuse line" "$KICKOFF_TEXT" "profile=<name>"
check_contains "skill documents the profile in the reuse line" "$KICKOFF_TEXT" \
  'profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking>'
check_contains "skill pins the whole reuse line" "$KICKOFF_TEXT" \
  '前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]'
check_contains "skill documents bootstrap from profiles_present" "$TEAM_TEXT" 'profiles_present=false'
check_contains "skill documents bootstrap from the source" "$TEAM_TEXT" 'source=default'
check_contains "skill documents bootstrap from the result" "$TEAM_TEXT" 'result=missing'
check_contains "skill documents bootstrap from the reason" "$TEAM_TEXT" '`reason=no-profiles`'
check_contains "skill documents the no-profile reason" "$TEAM_TEXT" 'no-profiles'
check_contains "skill documents the selected-profile reason" "$TEAM_TEXT" 'missing-selected-profile'
check_contains "skill documents the active-profile reason" "$TEAM_TEXT" 'missing-active-profile'
check_contains "skill documents the explicit-profile reason" "$TEAM_TEXT" 'missing-explicit-profile'
check_contains "skill documents the bad-active reason" "$TEAM_TEXT" 'bad-active'
check_contains "skill documents the bad-name reason" "$TEAM_TEXT" 'bad-profile-name'
check_contains "skill documents that active never falls back" "$TEAM_TEXT" 'never silently falls back to `default`'
check_contains "skill documents the run-only fallback word" "$TEAM_TEXT" 'fallback で'
check_contains "skill documents the persistent switch word" "$TEAM_TEXT" 'fallback に切り替えて'
check_contains "skill ties the persistent switch to use fallback" "$TEAM_TEXT" 'is `use fallback`'
check_contains "skill documents that an exclusion never rewrites a profile" "$TEAM_TEXT" \
  'a run that excludes the role omits it from this run'"'"'s team and keeps the stored profile as it is'
check_contains "skill keeps the reuse path for an overridden participation decision" "$KICKOFF_TEXT" \
  "A participation decision the user overrode is not such a statement either"
check_contains "skill says an excluded ui-tester stays stored" "$KICKOFF_TEXT" \
  'excluding a role never rewrites a profile'
check_contains "skill states the no-write contract for a settled team" "$KICKOFF_TEXT" \
  'a settled team is not written automatically'
check_contains "skill keeps the explicit-save contract" "$KICKOFF_TEXT" \
  'Every other save happens only on an explicit user instruction'
check_contains "skill keeps the bootstrap save" "$KICKOFF_TEXT" 'team-record.sh write --profile default'
check_contains "skill links the migration procedure" "$SKILL_TEXT" 'references/team-profile-migration.md'
check_contains "skill states that a profile has no version" "$TEAM_TEXT" 'There is no version field'
check_not_contains "skill does not document the old record anchor" "$SKILL_TEXT" '#approved-team-record'
check_not_contains "skill does not document the old record heading" "$SKILL_TEXT" '## Approved team record'
check_not_contains "skill does not document the removed repo root option" "$SKILL_TEXT" '--repo-root'
check_not_contains "skill does not document the removed origin option" "$SKILL_TEXT" '--origin-url'
check_not_contains "skill does not document the old teams path" "$SKILL_TEXT" 'pi-issue-pr-workflow/teams'
check_not_contains "skill does not document a version field" "$SKILL_TEXT" '"version": 1'

# The sequential-run reference follows the same rename and keeps one anchor.
check_contains "sequential runs relate the profiles to pane reuse" "$SEQUENTIAL_TEXT" \
  '## Relationship to the team profiles'
check_contains "sequential runs link the Team profiles section" "$SEQUENTIAL_TEXT" '../SKILL.md#team-profiles'
check_not_contains "sequential runs do not keep the old anchor" "$SEQUENTIAL_TEXT" '#approved-team-record'
check_not_contains "sequential runs do not say record" "$SEQUENTIAL_TEXT" 'approved team record'

# The migration reference is the documented procedure, not code.
check_contains "migration backs up the user asset" "$MIGRATION_TEXT" 'cp -a "$ASSET" "$ASSET.bak-$(date +%Y%m%d%H%M%S)"'
check_contains "migration maps a record to a profile" "$MIGRATION_TEXT" 'profiles/default.json'
check_contains "migration sets the manual file mode" "$MIGRATION_TEXT" 'chmod 600 "$ASSET"/profiles/*.json'
check_contains "migration resolves before deleting teams" "$MIGRATION_TEXT" 'rm -r "$ASSET"/teams'
check_contains "migration states active is optional" "$MIGRATION_TEXT" '`active` is optional'
check_contains "migration states the rollback scope" "$MIGRATION_TEXT" 'restores the skill revision only'
check_contains "migration states the asset restore" "$MIGRATION_TEXT" 'put the backup from step 1 back'

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
