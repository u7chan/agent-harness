#!/usr/bin/env bash
# Hermetic tests for scripts/mark.sh. Uses a fake playwright-cli shim through
# the real pw.sh wrapper: no browser, no network, no session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARK="$SCRIPT_DIR/../scripts/mark.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mark-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

check_eq() { # name got want
  if [ "$2" = "$3" ]; then ok "$1"; else ng "$1" "got '$2', want '$3'"; fi
}

check_contains() { # name hay needle
  case "$2" in *"$3"*) ok "$1" ;; *) ng "$1" "expected to contain: $3
--- output ---
$2" ;; esac
}

check_not_contains() { # name hay needle
  case "$2" in *"$3"*) ng "$1" "should NOT contain: $3" ;; *) ok "$1" ;; esac
}

mkdir -p "$WORK/bin" "$WORK/out" "$WORK/tmp" "$WORK/cwd"
export TMPDIR="$WORK/tmp"
export PATH="$WORK/bin:$PATH"
export FAKE_LOG="$WORK/argv"

# A 1x1 PNG. The width/height in `saved:` must come from this file, not from
# the rect the page reported.
PNG_1X1='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='

cat > "$WORK/bin/playwright-cli" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
: > "${FAKE_LOG:?}"
for a in "$@"; do printf 'ARG[%s]\n' "$a" >> "$FAKE_LOG"; done
printf 'OUTPUT_DIR=%s\n' "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}" >> "$FAKE_LOG"

emit() {
  printf '### Result\n%s\n### Ran Playwright code\n```js\nawait page.evaluate(...);\n```\n' \
    "$(printf '%s' "$1" | jq -Rs .)"
}

cmd=''; js=''
for a in "$@"; do
  case "$a" in
    -s=*|-*) continue ;;
  esac
  if [ -z "$cmd" ]; then cmd="$a"; elif [ "$cmd" = eval ] && [ -z "$js" ]; then js="$a"; fi
done

case "$cmd" in
  eval)
    case "$js" in
      *mark.sh:shot*) case "${FAKE_RECT:-ok}" in
          none) emit '{"ok":false,"code":"no-marks"}' ;;
          outside) emit '{"ok":false,"code":"outside"}' ;;
          *) emit '{"ok":true,"l":10,"t":20,"w":200,"h":100,"token":"tok-1"}' ;;
        esac ;;
      *mark.sh:drop-shot*) emit '{"ok":true}' ;;
      *mark.sh:clear*) case "${FAKE_CLEAR:-ok}" in
          ok) emit '{"ok":true,"cleared":2}' ;;
          zero) emit '{"ok":true,"cleared":0}' ;;
          closed) printf '### Error\nis not open\n' ;;
          *) printf '### Error\nboom\n' ;;
        esac ;;
      *mark.sh:mark*) case "${FAKE_MARK:-ok}" in
          hidden) emit '{"ok":false,"code":"hidden"}' ;;
          iframe) emit '{"ok":false,"code":"iframe"}' ;;
          outside) emit '{"ok":false,"code":"outside"}' ;;
          not-visible) emit '{"ok":false,"code":"not-visible"}' ;;
          weird) emit '{"ok":false,"code":"weird"}' ;;
          error) printf '### Error\nstrict mode violation\n' ;;
          *) emit '{"ok":true,"w":120,"h":60}' ;;
        esac ;;
      *) emit '{"ok":true}' ;;
    esac ;;
  screenshot)
    file=''
    for a in "$@"; do case "$a" in --filename=*) file="${a#--filename=}";; esac; done
    case "${FAKE_SHOT:-ok}" in
      fail) printf '### Error\nscreenshot failed\n'; exit 1 ;;
      noop) exit 0 ;;
      empty) [ -n "$file" ] && : > "$file"; exit 0 ;;
      *) [ -n "$file" ] && printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' | base64 -d > "$file"; exit 0 ;;
    esac ;;
  *) printf '### Error\nunsupported command: %s\n' "$cmd"; exit 1 ;;
esac
SHIM
chmod +x "$WORK/bin/playwright-cli"

OUT=''
RC=0
run() { # run <mark.sh args...>; fake behavior comes from exported FAKE_* vars
  : > "$FAKE_LOG"
  OUT="$( cd "$WORK/cwd" && env -u PW_ARTIFACT_DIR -u PLAYWRIGHT_MCP_OUTPUT_DIR \
    PW_SESSION=marktest bash "$MARK" "$@" 2>&1 )"
  RC=$?
}

# Sanity: the fixture PNG is what the tests expect.
if printf '%s' "$PNG_1X1" | base64 -d > "$WORK/probe.png" 2>/dev/null &&
  [ "$(od -An -tx1 -N8 "$WORK/probe.png" | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
  ok "fixture PNG decodes"
else
  ng "fixture PNG decodes" "base64/od are required for these tests"
fi

# The documented usage runs mark.sh directly, so it must stay executable.
if [ -x "$MARK" ]; then ok "mark.sh is executable"; else ng "mark.sh is executable" "chmod +x scripts/mark.sh"; fi

# --- marking ---------------------------------------------------------------

run before e1 余白なし
check_eq "before returns 0" "$RC" 0
check_contains "before reports the element size" "$OUT" "marked: 120x60"
check_contains "before uses the before color" "$(cat "$FAKE_LOG")" '#d6262b'
check_contains "before passes the session to pw.sh" "$(cat "$FAKE_LOG")" 'ARG[-s=marktest]'
check_contains "before goes through pw.sh (artifact dir set)" "$(cat "$FAKE_LOG")" 'OUTPUT_DIR=/'

run after e2 余白あり
check_eq "after returns 0" "$RC" 0
check_contains "after uses the after color" "$(cat "$FAKE_LOG")" '#1a8a3a'

run before e1 'say "hi"'
check_eq "label with quotes returns 0" "$RC" 0
check_contains "label is JSON-escaped before it reaches the page" "$(cat "$FAKE_LOG")" 'say \"hi\"'

run before e1 123456789
check_eq "9-character label is a usage error" "$RC" 2
check_contains "long label message" "$OUT" '1-8 characters'

run before e1
check_eq "missing label is a usage error" "$RC" 2

# --- marking failures ------------------------------------------------------

for mode in hidden iframe outside not-visible weird error; do
  FAKE_MARK="$mode" run before e1 ラベル
  check_eq "mark failure '$mode' returns 1" "$RC" 1
done
FAKE_MARK=hidden run before e1 ラベル
check_contains "hidden explains zero size" "$OUT" 'zero-size'
FAKE_MARK=iframe run before e1 ラベル
check_contains "iframe explains the iframe rule" "$OUT" 'iframe'
FAKE_MARK=not-visible run before e1 ラベル
check_contains "not-visible points at an unmarked capture" "$OUT" 'unmarked'

# --- capture ---------------------------------------------------------------

FAKE_RECT=none run shot "$WORK/out/before.png"
check_eq "shot without marks returns 1" "$RC" 1
check_contains "shot without marks explains why" "$OUT" 'no marks'

FAKE_RECT=outside run shot "$WORK/out/outside.png"
check_eq "shot with an empty crop returns 1" "$RC" 1

run before e1 余白なし
run shot "$WORK/out/ok.png"
check_eq "shot returns 0" "$RC" 0
check_contains "shot reports the PNG size, not the rect" "$OUT" '1 1'
check_contains "shot reports the file" "$OUT" "$WORK/out/ok.png"
[ -f "$WORK/out/ok.png" ] && ok "shot wrote the file" || ng "shot wrote the file" "missing"
check_eq "shot makes the artifact private" "$(stat -c%a "$WORK/out/ok.png" 2>/dev/null)" 600
check_contains "shot clears the marks after saving" "$(cat "$FAKE_LOG")" 'mark.sh:clear'

FAKE_SHOT=fail run shot "$WORK/out/fail.png"
check_eq "screenshot failure returns 1" "$RC" 1
check_contains "screenshot failure keeps the marks" "$OUT" 'Marks are kept'
check_contains "screenshot failure drops the shot helper" "$(cat "$FAKE_LOG")" 'mark.sh:drop-shot'
check_not_contains "screenshot failure does not clear the marks" "$(cat "$FAKE_LOG")" 'mark.sh:clear'

FAKE_SHOT=empty run shot "$WORK/out/empty.png"
check_eq "empty file returns 1" "$RC" 1
check_contains "empty file explains the PNG check" "$OUT" 'readable PNG'

FAKE_SHOT=noop run shot "$WORK/out/noop.png"
check_eq "missing file returns 1" "$RC" 1

# --- argument validation ---------------------------------------------------

run shot relative.png
check_eq "relative output is a usage error" "$RC" 2
check_contains "relative output asks for an absolute path" "$OUT" 'absolute'

run shot "$WORK/out/x.jpg"
check_eq "non-PNG output is a usage error" "$RC" 2

run shot "$WORK/out/x.png" abc
check_eq "non-numeric margin is a usage error" "$RC" 2

# --- clear -----------------------------------------------------------------

run clear
check_eq "clear returns 0" "$RC" 0
check_contains "clear reports the count" "$OUT" 'cleared: 2'

FAKE_CLEAR=zero run clear
check_eq "clear with no marks returns 0" "$RC" 0
check_contains "clear with no marks says zero" "$OUT" 'cleared: 0'

FAKE_CLEAR=closed run clear
check_eq "clear on a closed session returns 0" "$RC" 0
check_contains "clear on a closed session says nothing to clear" "$OUT" 'nothing to clear'

FAKE_CLEAR=fail run clear
check_eq "clear failure returns 1" "$RC" 1

# --- dispatch --------------------------------------------------------------

run
check_eq "no arguments is a usage error" "$RC" 2
check_contains "usage lists the commands" "$OUT" 'mark.sh before'

run nope
check_eq "unknown subcommand is a usage error" "$RC" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
