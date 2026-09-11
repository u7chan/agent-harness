#!/usr/bin/env bash
# Smoke tests for scripts/pw.sh. Uses a fake playwright-cli shim; never starts
# a real browser and never runs close-all / kill-all.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW="$SCRIPT_DIR/../scripts/pw.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pw-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
skip() { printf 'skip %s\n     %s\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

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

check_eq() {
  local name="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$name" || ng "$name" "got '$got', want '$want'"
}

# --- fake playwright-cli --------------------------------------------------
# Env knobs: SHIM_FAIL_ON (substring of argv -> exit 1), SHIM_RC (exit code),
# SHIM_BIG (huge snapshot), SHIM_NOSNAP (link to a missing file),
# SHIM_BODY (extra stdout line), SHIM_STDERR (extra stderr line).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/playwright-cli" <<'SHIM'
#!/usr/bin/env bash
# Records argv, emits an update banner on stderr and a snapshot path on stdout.
: > "$SHIM_ARGV"
for a in "$@"; do printf 'ARG[%s]\n' "$a" >> "$SHIM_ARGV"; done
printf 'ARGC=%d\n' "$#" >> "$SHIM_ARGV"
printf 'OUTPUT_DIR=%s\n' "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}" >> "$SHIM_ARGV"

cat >&2 <<'BANNER'
╔════════════════════════════════════════════════════════════════════╗
║ Update available for @playwright/cli: 0.1.18 → 0.1.19              ║
╚════════════════════════════════════════════════════════════════════╝
BANNER

cmd=""
for a in "$@"; do
  case "$a" in -*) ;; *) cmd="$a"; break ;; esac
done

[ -n "${SHIM_STDERR:-}" ] && echo "$SHIM_STDERR" >&2

joined="$*"
if [ -n "${SHIM_FAIL_ON:-}" ] && [[ "$joined" == *"$SHIM_FAIL_ON"* ]]; then
  echo "### Error"
  echo "Error: element not found"
  exit 1
fi
if [ -n "${SHIM_RC:-}" ]; then
  echo "### Error"
  echo "Error: shim rc=$SHIM_RC"
  exit "$SHIM_RC"
fi

case " $* " in
  *" --raw "*) echo '"Example Domain"'; exit 0 ;;
esac

output_dir="${PLAYWRIGHT_MCP_OUTPUT_DIR:-.playwright-cli}"
mkdir -p "$output_dir"
snap="$output_dir/page-${cmd}.yml"
{
  echo "- generic [ref=e1]: snapshot-of-${cmd}"
  echo "  - button \"OK\" [ref=e2]"
  if [ -n "${SHIM_BIG:-}" ]; then
    i=0
    while [ "$i" -lt 400 ]; do
      echo "  - link \"item-$i\" [ref=e$i]"
      i=$((i + 1))
    done
  fi
} > "$snap"
[ -n "${SHIM_NOSNAP:-}" ] && snap="$output_dir/page-does-not-exist.yml"

case " $* " in
  *" --json "*)
    printf '{\n  "snapshot": {\n    "file": "%s"\n  }\n}\n' "$snap"
    exit 0 ;;
esac
echo "### Page"
echo "- Page URL: https://example.com/"
[ -n "${SHIM_BODY:-}" ] && echo "$SHIM_BODY"
echo "### Snapshot"
echo "- [Snapshot]($snap)"
SHIM
chmod +x "$WORK/bin/playwright-cli"
export PATH="$WORK/bin:$PATH"
export SHIM_ARGV="$WORK/argv.txt"

cd "$WORK"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

artifact_id() {
  printf '%s\0%s' "$WORK" "$1" | sha256sum | cut -c1-16
}

artifact_dir() {
  printf '%s/playwright-cli/%s' "$TMPDIR" "$(artifact_id "$1")"
}

# --- 1. snapshot inlining -------------------------------------------------
out="$(PW_SESSION=t bash "$PW" click e2 2>/dev/null)"
check_contains "1a snapshot file content is inlined" "$out" 'button "OK" [ref=e2]'
check_not_contains "1b update banner is stripped" "$out" 'Update available'
err="$(PW_SESSION=t bash "$PW" click e2 2>&1 >/dev/null)"
check_not_contains "1c banner stripped from stderr too" "$err" 'Update available'
check_contains "1d output directory is passed outside the workspace" "$(cat "$SHIM_ARGV")" "OUTPUT_DIR=$(artifact_dir t)"
[ -f "$(artifact_dir t)/page-click.yml" ] && ok "1e snapshot is stored in the identified temp directory" || ng "1e snapshot is stored in the identified temp directory" "missing $(artifact_dir t)/page-click.yml"
[ ! -e "$WORK/.playwright-cli" ] && ok "1f workspace has no .playwright-cli artifact" || ng "1f workspace has no .playwright-cli artifact" "$WORK/.playwright-cli exists"

custom_artifact_dir="$WORK/custom-artifacts"
PW_ARTIFACT_DIR="$custom_artifact_dir" PW_SESSION=custom bash "$PW" click e2 >/dev/null 2>&1
[ -f "$custom_artifact_dir/page-click.yml" ] && ok "1g explicit PW_ARTIFACT_DIR is honored" || ng "1g explicit PW_ARTIFACT_DIR is honored" "missing $custom_artifact_dir/page-click.yml"

PW_SESSION=other bash "$PW" click e2 >/dev/null 2>&1
[ "$(artifact_dir t)" != "$(artifact_dir other)" ] && ok "1h artifact identifier includes the session" || ng "1h artifact identifier includes the session" "identifiers collided"
[ -f "$(artifact_dir other)/page-click.yml" ] && ok "1i distinct session uses a distinct temp directory" || ng "1i distinct session uses a distinct temp directory" "missing $(artifact_dir other)/page-click.yml"

# --- 2. truncation --------------------------------------------------------
out="$(SHIM_BIG=1 PW_SNAPSHOT_MAX=200 PW_SESSION=t bash "$PW" click e2 2>/dev/null)"
check_contains "2a truncated notice" "$out" 'truncated at 200 bytes'
check_contains "2b hints at find / --depth / partial snapshot" "$out" 'pw.sh snapshot --depth=N'

# --- 3. batch stops at first failure --------------------------------------
out="$(SHIM_FAIL_ON='click e2' PW_SESSION=t bash "$PW" - 2>&1 <<'EOF'
# comment line is skipped

fill e1 "a"
click e2
goto https://example.com/should-not-run
EOF
)"
rc=$?
[ "$rc" -ne 0 ] && ok "3a batch exits non-zero" || ng "3a batch exits non-zero" "rc=$rc"
check_contains "3b reports the failing line number" "$out" 'batch stopped at line 4'
check_not_contains "3c later line is not executed" "$out" 'should-not-run'
check_contains "3d inlines the LAST SUCCESSFUL snapshot (fill, not click)" "$out" 'snapshot-of-fill'
check_not_contains "3e does not inline the failing command's snapshot" "$out" 'snapshot-of-click'

# --- 4. quoted argument stays one argv element ----------------------------
PW_SESSION=t bash "$PW" - >/dev/null 2>&1 <<'EOF'
fill e1 "hello world"
EOF
argv="$(cat "$SHIM_ARGV")"
check_contains "4a quoted arg arrives intact" "$argv" 'ARG[hello world]'
check_contains "4b argc is 4 (-s=, fill, e1, text)" "$argv" 'ARGC=4'
check_contains "4c session flag is injected" "$argv" 'ARG[-s=t]'

# --- 5. headed auto-detection --------------------------------------------
PW_HEADED=1 PW_SESSION=t bash "$PW" open https://example.com/ >/dev/null 2>&1
check_contains "5a PW_HEADED=1 adds --headed" "$(cat "$SHIM_ARGV")" 'ARG[--headed]'

PW_HEADED=0 PW_SESSION=t bash "$PW" open https://example.com/ >/dev/null 2>&1
check_not_contains "5b PW_HEADED=0 omits --headed" "$(cat "$SHIM_ARGV")" 'ARG[--headed]'

DISPLAY='' PW_SESSION=t bash "$PW" open https://example.com/ >/dev/null 2>&1
check_not_contains "5c empty DISPLAY omits --headed" "$(cat "$SHIM_ARGV")" 'ARG[--headed]'

hdr="$(DISPLAY='' PW_SESSION=t bash "$PW" open https://example.com/ 2>&1 >/dev/null)"
check_contains "5d reports the decision on stderr" "$hdr" '[pw] headed=false (no DISPLAY)'

if [ -d /mnt/wslg ] && grep -qi microsoft /proc/version 2>/dev/null; then
  hdr="$(DISPLAY=':0' PW_SESSION=t bash "$PW" open https://example.com/ 2>&1 >/dev/null)"
  check_contains "5e WSLg + DISPLAY -> headed" "$hdr" '[pw] headed=true (DISPLAY=:0, WSLg)'
  check_contains "5f WSLg + DISPLAY passes --headed" "$(cat "$SHIM_ARGV")" 'ARG[--headed]'
else
  skip "5e/5f WSLg + DISPLAY -> headed" "not a WSL2 host with /mnt/wslg"
fi

PW_SESSION=t bash "$PW" open --headed https://example.com/ >/dev/null 2>&1
check_eq "5g explicit --headed is not duplicated" \
  "$(grep -c 'ARG\[--headed\]' "$SHIM_ARGV")" "1"

# --- 6. missing binary ----------------------------------------------------
out="$(PW_BIN=playwright-cli-absent PW_SESSION=t bash "$PW" open 2>&1)"
rc=$?
[ "$rc" -eq 1 ] && ok "6a exits 1 when playwright-cli is absent" || ng "6a exits 1 when absent" "rc=$rc"
check_contains "6b shows install hint" "$out" 'npm install -g @playwright/cli'

# --- 7. --json output form ------------------------------------------------
out="$(PW_SESSION=t bash "$PW" click e2 --json 2>/dev/null)"
check_contains "7a --json: snapshot.file path is inlined" "$out" 'button "OK" [ref=e2]'
check_contains "7b --json: original JSON is kept" "$out" '"snapshot"'

# --- 8. tokenizer (S1: whitespace, S2: quotes only) -----------------------
printf '  click e3 \n' | PW_SESSION=t bash "$PW" - >/dev/null 2>&1
check_eq "8a leading+trailing whitespace adds no empty arg" \
  "$(sed -n 's/^ARGC=//p' "$SHIM_ARGV")" "3"

printf 'fill e1 "it'"'"'s"\n' | PW_SESSION=t bash "$PW" - >/dev/null 2>&1
argv="$(cat "$SHIM_ARGV")"
check_contains "8b apostrophe inside \"...\" survives" "$argv" "ARG[it's]"
check_contains "8c ... as a single argument" "$argv" 'ARGC=4'

printf 'fill e1 a\\b\n' | PW_SESSION=t bash "$PW" - >/dev/null 2>&1
check_contains "8d backslash is literal (documented)" "$(cat "$SHIM_ARGV")" 'ARG[a\b]'

out="$(printf 'fill e1 "a"\nfill e2 "unterminated\n' | PW_SESSION=t bash "$PW" - 2>&1)"
rc=$?
[ "$rc" -eq 1 ] && ok "8e unterminated quote exits 1" || ng "8e unterminated quote exits 1" "rc=$rc"
check_contains "8f unterminated quote names the line" "$out" 'line 2: unterminated quote'
check_contains "8g unterminated quote still inlines last good snapshot" "$out" 'snapshot-of-fill'

# --- 9. batch `open` gets the headed preflight (S6) ------------------------
out="$(PW_HEADED=1 PW_SESSION=t bash "$PW" - 2>&1 >/dev/null <<'EOF'
open https://example.com/
EOF
)"
check_contains "9a batch open adds --headed" "$(cat "$SHIM_ARGV")" 'ARG[--headed]'
check_contains "9b batch open logs the decision" "$out" '[pw] headed=true (PW_HEADED=1)'

# --- 10. "is not installed" detection (N1) --------------------------------
out="$(SHIM_BODY='- paragraph: Chromium is not installed on this machine' \
  PW_SESSION=t bash "$PW" click e2 2>&1)"
rc=$?
check_eq "10a page text 'is not installed' does not fail the run" "$rc" "0"
check_not_contains "10b ... and prints no browser-missing note" "$out" 'browser missing'

out="$(SHIM_STDERR='Browser "chromium" is not installed' PW_SESSION=t bash "$PW" click e2 2>&1)"
rc=$?
check_eq "10c stderr 'is not installed' fails the run" "$rc" "1"
check_contains "10d ... and prints the install-browser note" "$out" 'install-browser chromium'

# --- 11. snapshot link line is dropped (N2) -------------------------------
out="$(PW_SESSION=t bash "$PW" click e2 2>/dev/null)"
check_not_contains "11a link line is dropped once expanded" "$out" '[Snapshot]('
check_eq "11b exactly one Snapshot heading" \
  "$(printf '%s\n' "$out" | grep -c '^### Snapshot')" "1"

out="$(PW_SESSION=t bash "$PW" - 2>/dev/null <<'EOF'
fill e1 "a"
click e2
EOF
)"
check_not_contains "11c batch intermediate output has no link line" "$out" '[Snapshot]('

# --- 12. exit code passthrough --------------------------------------------
SHIM_RC=3 PW_SESSION=t bash "$PW" click e2 >/dev/null 2>&1
check_eq "12a single command passes the exit code through" "$?" "3"

SHIM_RC=4 PW_SESSION=t bash "$PW" - >/dev/null 2>&1 <<'EOF'
click e2
EOF
check_eq "12b batch passes the exit code through" "$?" "4"

# --- 13. missing snapshot file --------------------------------------------
out="$(SHIM_NOSNAP=1 PW_SESSION=t bash "$PW" click e2 2>&1)"
rc=$?
check_eq "13a missing snapshot file does not fail the run" "$rc" "0"
check_contains "13b ... and says so" "$out" 'snapshot file missing'

# --- 14. --raw passthrough ------------------------------------------------
out="$(PW_SESSION=t bash "$PW" --raw eval "document.title" 2>/dev/null)"
check_eq "14a --raw output passes through untouched" "$out" '"Example Domain"'
check_contains "14b --raw reaches the CLI" "$(cat "$SHIM_ARGV")" 'ARG[--raw]'

# --- 15. session-broken hints (S3) ----------------------------------------
out="$(SHIM_STDERR="The browser 't' is not open, please run open first" \
  PW_SESSION=t bash "$PW" click e2 2>&1)"
check_contains "15a 'is not open' points at open, same cwd" "$out" 'not open. run: pw.sh open <url> from the same cwd'
check_not_contains "15b 'is not open' does NOT suggest recover" "$out" 'recover'

out="$(SHIM_STDERR='Error: Session closed' PW_SESSION=t bash "$PW" click e2 2>&1)"
check_contains "15c 'Session closed' suggests recover" "$out" 'pw.sh recover'

# --- 16. default session name (PW_SESSION unset) --------------------------
env -u PW_SESSION bash "$PW" click e2 >/dev/null 2>&1
check_contains "16a default session is playwright" "$(cat "$SHIM_ARGV")" 'ARG[-s=playwright]'

out="$(env -u PW_SESSION bash "$PW" --help 2>&1)"
check_contains "16b usage text advertises the playwright default" "$out" 'PW_SESSION (default: playwright)'

# --- 17. default browser preflight ----------------------------------------
PW_HEADED=0 PW_SESSION=t bash "$PW" open https://example.com/ >/dev/null 2>&1
check_contains "17a open adds bundled Chromium by default" \
  "$(cat "$SHIM_ARGV")" 'ARG[--browser=chromium]'

PW_HEADED=0 PW_SESSION=t bash "$PW" open https://example.com/ --browser=firefox >/dev/null 2>&1
argv="$(cat "$SHIM_ARGV")"
check_contains "17b explicit browser is passed through" "$argv" 'ARG[--browser=firefox]'
check_not_contains "17c explicit browser does not add Chromium" "$argv" 'ARG[--browser=chromium]'

PW_HEADED=0 PW_SESSION=t bash "$PW" - >/dev/null 2>&1 <<'EOF'
open https://example.com/
EOF
check_contains "17d batch open adds bundled Chromium by default" \
  "$(cat "$SHIM_ARGV")" 'ARG[--browser=chromium]'

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
