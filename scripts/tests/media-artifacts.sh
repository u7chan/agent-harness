#!/usr/bin/env bash
# Hermetic tests for scripts/check-media-artifacts.sh.
#
# Each case builds a throwaway repository root and asserts one accepted or
# rejected shape.  The real repository is checked separately by running the
# script itself in CI.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../check-media-artifacts.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/media-artifacts-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

# make_root <name> — an empty fixture root that already looks like this repo.
make_root() {
  local root="$WORK/$1"
  mkdir -p "$root/skill"
  printf '# skill\n' >"$root/skill/SKILL.md"
  printf '# repo\n' >"$root/README.md"
  printf '%s\n' "$root"
}

# add_file <root> <relative path> — a file with a media extension and no data.
add_file() {
  local root="$1" relative="$2"
  mkdir -p "$root/$(dirname "$relative")"
  printf 'binary\n' >"$root/$relative"
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

# --- Accepted shapes --------------------------------------------------------
check_ok "text-only tree passes" "$(make_root clean)"

ROOT="$(make_root names)"
printf 'image placeholder\n' >"$ROOT/notes.png.txt"
printf 'screenshot instructions\n' >"$ROOT/evidence.md"
check_ok "a media name inside a path or a longer suffix passes" "$ROOT"

ROOT="$(make_root git-dir)"
add_file "$ROOT" ".git/objects/ab/cdef.png"
check_ok "a media file under .git is pruned" "$ROOT"

ROOT="$(make_root documented-asset)"
add_file "$ROOT" "_docs/assets/diagram.png"
printf '# notes\n\n![diagram](assets/diagram.png)\n' >"$ROOT/_docs/notes.md"
check_ok "a documentation asset with a reference passes" "$ROOT"

ROOT="$(make_root nested-asset)"
add_file "$ROOT" "_docs/assets/set/diagram.mp4"
printf '# notes\n\n![diagram](assets/set/diagram.mp4)\n' >"$ROOT/_docs/notes.md"
check_ok "a nested documentation asset passes" "$ROOT"

ROOT="$(make_root html-asset)"
add_file "$ROOT" "_docs/assets/diagram.png"
printf '# notes\n\n<img src="assets/diagram.png" width="320">\n' >"$ROOT/_docs/notes.md"
check_ok "an HTML src counts as a link" "$ROOT"

ROOT="$(make_root fragment-asset)"
add_file "$ROOT" "_docs/assets/diagram.png"
printf '# notes\n\n[diagram](assets/diagram.png#figure-1)\n' >"$ROOT/_docs/notes.md"
check_ok "a fragment and query are ignored when matching" "$ROOT"

# --- Rejected shapes --------------------------------------------------------
ROOT="$(make_root root-png)"
add_file "$ROOT" "desktop.png"
check_fail "a screenshot at the repository root fails" "$ROOT" "desktop.png"

ROOT="$(make_root nested-jpeg)"
add_file "$ROOT" "skill/references/before.jpeg"
check_fail "a screenshot inside a skill fails" "$ROOT" "skill/references/before.jpeg"

ROOT="$(make_root recording)"
add_file "$ROOT" "review/summary.mp4"
check_fail "a recording fails" "$ROOT" "review/summary.mp4"

ROOT="$(make_root uppercase)"
add_file "$ROOT" "desktop.PNG"
check_fail "an upper-case extension fails" "$ROOT" "desktop.PNG"

ROOT="$(make_root spaced)"
add_file "$ROOT" "before shot.webm"
check_fail "a name with a space is reported verbatim" "$ROOT" "before shot.webm"

ROOT="$(make_root assets-sibling)"
add_file "$ROOT" "_docs/assets-not/near-miss.png"
check_fail "a directory that only starts with the asset path fails" "$ROOT" "_docs/assets-not/near-miss.png"

ROOT="$(make_root orphan-asset)"
add_file "$ROOT" "_docs/assets/unused.png"
printf '# notes\n' >"$ROOT/_docs/notes.md"
check_fail "an unlinked documentation asset fails" "$ROOT" "linked from a document"

# A name that already appears in prose is not a link.  Without this case the
# check accepts any screenshot whose filename a skill happens to mention, such
# as the example names in the playwright evidence procedure.
ROOT="$(make_root mentioned-asset)"
add_file "$ROOT" "_docs/assets/01-before.png"
printf '# notes\n\nName the file `01-before.png` when you save it.\n' >"$ROOT/_docs/notes.md"
check_fail "a prose mention is not a link" "$ROOT" "linked from a document"

# The asset directory cannot vouch for itself, or a README there turns it into
# an evidence sink that passes CI.
ROOT="$(make_root self-linked-asset)"
add_file "$ROOT" "_docs/assets/before.png"
printf '# assets\n\n![before](before.png)\n' >"$ROOT/_docs/assets/README.md"
check_fail "a link from inside the asset directory does not count" "$ROOT" "linked from a document"

ROOT="$(make_root artifact-in-assets)"
add_file "$ROOT" "_docs/assets/before.png"
printf '# notes\n\n![before](assets/before.png)\n' >"$ROOT/_docs/notes.md"
check_ok "the asset directory is an allowlist, not an evidence sink" "$ROOT"

# The message must name the destination, or the failure reads like a rule with
# no way to comply.
ROOT="$(make_root hint)"
add_file "$ROOT" "narrow.png"
run_check "$ROOT"
case "$OUT" in
  *PW_ARTIFACT_DIR*) ok "the failure names the artifact directory" ;;
  *) ng "the failure names the artifact directory" "missing PW_ARTIFACT_DIR in: $OUT" ;;
esac

# A missing root is an error, not a pass: an empty scan would otherwise hide a
# typo in the argument.
OUT="$("$CHECK" "$WORK/absent" 2>&1)"
if [ $? -ne 0 ]; then ok "a missing root fails"; else ng "a missing root fails" "expected failure, got: $OUT"; fi

printf '\n%s passed / %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
