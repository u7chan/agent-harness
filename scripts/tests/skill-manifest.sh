#!/usr/bin/env bash
# Hermetic tests for scripts/check-skill-manifest.sh.
#
# Each case builds a throwaway repository root and asserts one accepted or
# rejected shape.  The real repository is checked separately by running the
# script itself in CI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-skill-manifest.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/skill-manifest-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || {
  printf 'FAIL: jq is required\n' >&2
  exit 1
}

# make_root <name> <skills-json> [<pi-skills-json>]
make_root() {
  local name="$1" manifest="$2" package="${3:-$2}" root="$WORK/$1"
  mkdir -p "$root"
  printf '%s\n' "$manifest" >"$root/skills.json"
  printf '{"name":"fixture","private":true,"pi":{"skills":%s}}\n' "$package" >"$root/package.json"
  printf '%s\n' "$root"
}

add_skill() {
  local root="$1" skill="$2"
  mkdir -p "$root/$skill"
  printf '# %s\n' "$skill" >"$root/$skill/SKILL.md"
}

run_check() {
  OUT="$("$CHECK" "$1" 2>&1)"
  STATUS=$?
}

check_ok() {
  local name="$1" root="$2"
  run_check "$root"
  if [ "$STATUS" -eq 0 ]; then ok "$name"; else ng "$name" "expected pass, got: $OUT"; fi
}

check_fail() {
  local name="$1" root="$2" needle="$3"
  run_check "$root"
  if [ "$STATUS" -eq 0 ]; then
    ng "$name" "expected failure"
  else
    case "$OUT" in
      *"$needle"*) ok "$name" ;;
      *) ng "$name" "expected '$needle' in: $OUT" ;;
    esac
  fi
}

# --- Accepted shape ---------------------------------------------------------
ROOT="$(make_root good '{"schema_version":1,"skills":["alpha","beta"]}' '["alpha","beta"]')"
add_skill "$ROOT" alpha
add_skill "$ROOT" beta
check_ok "valid manifest passes" "$ROOT"

# --- Rejected shapes --------------------------------------------------------
ROOT="$(make_root mismatch '{"schema_version":1,"skills":["alpha","beta"]}' '["alpha"]')"
add_skill "$ROOT" alpha
add_skill "$ROOT" beta
check_fail "pi.skills mirror is compared in both directions" "$ROOT" "must mirror skills.json"

ROOT="$(make_root nested '{"schema_version":1,"skills":["alpha"]}' '["alpha"]')"
add_skill "$ROOT" alpha
mkdir -p "$ROOT/group/inner"
printf '# inner\n' >"$ROOT/group/inner/SKILL.md"
check_fail "nested SKILL.md is rejected" "$ROOT" "nested more than one level"

ROOT="$(make_root missing-skill '{"schema_version":1,"skills":["alpha","beta"]}' '["alpha","beta"]')"
add_skill "$ROOT" alpha
check_fail "listed skill without SKILL.md is rejected" "$ROOT" "missing directory: beta"

ROOT="$(make_root empty-skill-dir '{"schema_version":1,"skills":["alpha","beta"]}' '["alpha","beta"]')"
add_skill "$ROOT" alpha
mkdir -p "$ROOT/beta"
check_fail "skill directory without SKILL.md is rejected" "$ROOT" "skill has no SKILL.md: beta"

ROOT="$(make_root unlisted '{"schema_version":1,"skills":["alpha"]}' '["alpha"]')"
add_skill "$ROOT" alpha
add_skill "$ROOT" gamma
check_fail "unlisted skill directory is rejected" "$ROOT" "not listed in skills.json: gamma"

ROOT="$(make_root unsorted '{"schema_version":1,"skills":["beta","alpha"]}' '["beta","alpha"]')"
add_skill "$ROOT" alpha
add_skill "$ROOT" beta
check_fail "unsorted manifest is rejected" "$ROOT" "must be sorted"

ROOT="$(make_root duplicate '{"schema_version":1,"skills":["alpha","alpha"]}' '["alpha","alpha"]')"
add_skill "$ROOT" alpha
check_fail "duplicate manifest entry is rejected" "$ROOT" "duplicate skill in skills.json: alpha"

ROOT="$(make_root traversal '{"schema_version":1,"skills":["../alpha"]}' '["../alpha"]')"
check_fail "path traversal in a skill name is rejected" "$ROOT" "invalid skill name"

ROOT="$(make_root hidden '{"schema_version":1,"skills":[".hidden"]}' '[".hidden"]')"
mkdir -p "$ROOT/.hidden"
printf '# h\n' >"$ROOT/.hidden/SKILL.md"
check_fail "dotted skill name is rejected" "$ROOT" "invalid skill name"

ROOT="$WORK/empty"
mkdir -p "$ROOT"
printf '{"schema_version":1,"skills":[]}\n' >"$ROOT/skills.json"
printf '{"name":"fixture","pi":{"skills":[]}}\n' >"$ROOT/package.json"
check_fail "empty skill set is rejected" "$ROOT" "non-empty skills array"

ROOT="$WORK/no-manifest"
mkdir -p "$ROOT"
printf '{"name":"fixture","pi":{"skills":[]}}\n' >"$ROOT/package.json"
check_fail "missing skills.json is rejected" "$ROOT" "missing"

ROOT="$(make_root bad-schema '{"schema_version":2,"skills":["alpha"]}' '["alpha"]')"
add_skill "$ROOT" alpha
check_fail "unsupported schema_version is rejected" "$ROOT" "schema_version 1"

ROOT="$(make_root no-pi '{"schema_version":1,"skills":["alpha"]}' 'null')"
add_skill "$ROOT" alpha
printf '{"name":"fixture"}\n' >"$ROOT/package.json"
check_fail "missing pi.skills mirror is rejected" "$ROOT" "pi.skills"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
