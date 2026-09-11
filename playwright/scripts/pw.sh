#!/usr/bin/env bash
# pw.sh - single entry point for the playwright-cli skill.
# Fixes the session name, strips the update banner, and inlines the snapshot
# file that playwright-cli only references by path.
set -euo pipefail

# Snapshots, storage state, and traces can contain sensitive page data. Keep
# files created by this wrapper private, including files created by the
# detached playwright-cli daemon.
umask 077

PW_BIN="${PW_BIN:-playwright-cli}"
# PW_BIN may hold extra words (e.g. "npx @playwright/cli"); keep it as an array.
read -r -a PW_CMD <<< "$PW_BIN"
PW_SESSION="${PW_SESSION:-playwright}"
PW_SNAPSHOT_MAX="${PW_SNAPSHOT_MAX:-12000}"

hash_input() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r
  else
    return 1
  fi
}

PW_ARTIFACT_DIR_AUTO=0
# playwright-cli writes automatically generated snapshots and other artifacts
# to PLAYWRIGHT_MCP_OUTPUT_DIR. Keep those artifacts out of the user's
# workspace by default, while allowing an explicit wrapper-level override.
if [ -n "${PW_ARTIFACT_DIR:-}" ]; then
  : "${PW_ARTIFACT_DIR}"
elif [ -n "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}" ]; then
  PW_ARTIFACT_DIR="$PLAYWRIGHT_MCP_OUTPUT_DIR"
else
  PW_ARTIFACT_DIR_AUTO=1
  PW_ARTIFACT_ID="$(printf '%s\0%s' "$(pwd -P)" "$PW_SESSION" | hash_input | cut -c1-16)" || {
    printf '[pw] ERROR: no SHA-256 command found (tried sha256sum, shasum, openssl)\n' >&2
    exit 1
  }
  PW_ARTIFACT_ROOT="${TMPDIR:-/tmp}/playwright-cli"
  PW_ARTIFACT_DIR="$PW_ARTIFACT_ROOT/$PW_ARTIFACT_ID"
fi

usage() {
  cat >&2 <<'EOF'
Usage:
  pw.sh <command> [args...]     run one playwright-cli command
  pw.sh - <<'EOF'               batch: one command per line, stops at first failure
  fill e1 "user@example.com"
  click e3
  EOF
  pw.sh open [url] [opts]       open with preflight (headed auto-detect)
  pw.sh recover                 close-all then kill-all (asks nothing; affects other sessions)

Env: PW_SESSION (default: playwright), PW_SNAPSHOT_MAX (default: 12000), PW_HEADED (1|0), PW_BIN, PW_ARTIFACT_DIR
EOF
  exit 2
}

fail() {
  printf '[pw] ERROR: %s\n' "$1" >&2
  exit 1
}

note() { printf '[pw] %s\n' "$1" >&2; }

ensure_private_dir() {
  local dir="$1" owner
  if [ -L "$dir" ]; then
    fail "artifact directory is a symlink: $dir"
  fi
  if [ ! -e "$dir" ]; then
    mkdir -m 700 "$dir" || fail "could not create artifact directory: $dir"
  fi
  [ -d "$dir" ] || fail "artifact path is not a directory: $dir"
  owner="$(stat -c '%u' "$dir" 2>/dev/null || stat -f '%u' "$dir" 2>/dev/null)" \
    || fail "could not inspect artifact directory owner: $dir"
  [ "$owner" = "$(id -u)" ] || fail "artifact directory is not owned by the current user: $dir"
  chmod 700 "$dir" || fail "could not secure artifact directory: $dir"
}

prepare_artifact_dir() {
  [ "$PW_ARTIFACT_DIR_AUTO" = 1 ] || return 0
  ensure_private_dir "$PW_ARTIFACT_ROOT"
  ensure_private_dir "$PW_ARTIFACT_DIR"
}

# One -e per glyph: BSD sed (macOS) has no \| alternation in BRE.
strip_banner() {
  sed -e '/^[[:space:]]*╔/d' -e '/^[[:space:]]*║/d' -e '/^[[:space:]]*╚/d'
}

# Drop the "- [Snapshot](path)" line (and a bare "### Snapshot" heading directly
# above it) so nothing invites a follow-up Read. inline_snapshot prints its own
# heading. An inline `snapshot` response keeps its heading: the line after it is
# ```yaml, not a link.
drop_snapshot_link() {
  # $!N: never N on the last line (POSIX/BSD sed would drop it instead of printing).
  sed -e '/^### Snapshot$/{$!N
/\[Snapshot\](/d
}' -e '/\[Snapshot\](/d'
}

require_bin() {
  command -v "${PW_CMD[0]}" >/dev/null 2>&1 || fail "$PW_BIN not found.
  install globally: npm install -g @playwright/cli
  or one-off:       PW_BIN='npx @playwright/cli' $0 ..."
}

# tokenize <line> -> TOKENS array. Interprets '...' and "..." quoting only;
# backslashes are literal, and a quote cannot be nested inside the same kind.
tokenize() {
  local line="$1"
  local n=${#line} i=0 ch cur='' started=0 quote=''
  TOKENS=()
  while ((i < n)); do
    ch="${line:i:1}"
    if [ -n "$quote" ]; then
      if [ "$ch" = "$quote" ]; then quote=''; else cur+="$ch"; fi
      started=1
    else
      case "$ch" in
        '"'|"'") quote="$ch"; started=1 ;;
        ' '|$'\t') if ((started)); then TOKENS+=("$cur"); cur=''; started=0; fi ;;
        *) cur+="$ch"; started=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  [ -n "$quote" ] && return 1
  ((started)) && TOKENS+=("$cur")
  return 0
}

# Emit the snapshot file referenced by the captured stdout, truncating if large.
inline_snapshot() {
  local out_file="$1" path size
  # Markdown form: "- [Snapshot](path)". --json form: {"snapshot": {"file": "path"}}.
  path="$(sed -n \
    -e 's/.*\[Snapshot\](\([^)]*\)).*/\1/p' \
    -e 's/.*"file":[[:space:]]*"\([^"]*\.yml\)".*/\1/p' \
    "$out_file" | tail -n 1)"
  [ -n "$path" ] || return 0
  [ -f "$path" ] || { note "snapshot file missing: $path"; return 0; }
  size="$(wc -c <"$path" | tr -d ' ')"
  printf '\n### Snapshot (%s, %s bytes)\n' "$path" "$size"
  if [ "$size" -gt "$PW_SNAPSHOT_MAX" ]; then
    head -c "$PW_SNAPSHOT_MAX" "$path"
    printf '\n... truncated at %s bytes. Narrow it down with: pw.sh find <text>, pw.sh snapshot --depth=N, pw.sh snapshot <ref>\n' "$PW_SNAPSHOT_MAX"
  else
    cat "$path"
  fi
}

# run_one <inline:0|1> <args...> -> prints output, returns playwright-cli exit code.
# Sets LAST_OUT to the captured stdout file (caller owns TMP_DIR cleanup).
run_one() {
  local inline="$1"; shift
  local out="$TMP_DIR/out.$RUN_SEQ" err="$TMP_DIR/err.$RUN_SEQ" rc=0
  RUN_SEQ=$((RUN_SEQ + 1))
  prepare_artifact_dir
  set +e
  PLAYWRIGHT_MCP_OUTPUT_DIR="$PW_ARTIFACT_DIR" \
    "${PW_CMD[@]}" "-s=$PW_SESSION" "$@" >"$out" 2>"$err" </dev/null
  rc=$?
  set -e
  strip_banner <"$out" | drop_snapshot_link
  strip_banner <"$err" >&2
  LAST_OUT="$out"
  # "is not open" is the ordinary error for "not opened yet" / "closed" / "opened
  # from another workspace dir". It is not a broken session; do not send the
  # agent to recover (which kills every session on the host).
  if grep -q 'is not open' "$out" "$err"; then
    note 'not open. run: pw.sh open <url> from the same cwd you opened it in'
  elif grep -qE 'Session closed|EADDRINUSE' "$out" "$err"; then
    note 'session broken? try: pw.sh recover (confirm with the user first) then pw.sh open <url>'
  fi
  # Only trust stderr, or an "### Error"/"Error" line on stdout: page text can
  # legitimately contain the phrase.
  if grep -q 'is not installed' "$err" || grep -q '^\(###[[:space:]]*\)\?Error.*is not installed' "$out"; then
    note "browser missing. run: $PW_BIN install-browser chromium"
    return 1
  fi
  [ "$inline" = 1 ] && inline_snapshot "$out"
  return "$rc"
}

decide_headed() {
  case "${PW_HEADED:-}" in
    1) note "headed=true (PW_HEADED=1)"; echo 1; return ;;
    0) note "headed=false (PW_HEADED=0)"; echo 0; return ;;
  esac
  if [ -z "${DISPLAY:-}" ]; then
    note "headed=false (no DISPLAY)"; echo 0; return
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then
    if [ -d /mnt/wslg ]; then
      note "headed=true (DISPLAY=$DISPLAY, WSLg)"; echo 1
    else
      note "headed=false (DISPLAY=$DISPLAY but no /mnt/wslg)"; echo 0
    fi
    return
  fi
  note "headed=true (DISPLAY=$DISPLAY)"; echo 1
}

# maybe_add_headed open [args...] -> OPEN_ARGS (always non-empty, so no
# empty-array expansion under `set -u` on bash 3.2).
maybe_add_headed() {
  local a has=0
  OPEN_ARGS=()
  for a in "$@"; do
    if [ "$a" = "--headed" ]; then has=1; fi
    OPEN_ARGS+=("$a")
  done
  if [ "$has" = 0 ] && [ "$(decide_headed)" = 1 ]; then
    OPEN_ARGS+=("--headed")
  fi
}

# maybe_add_browser open [args...] -> OPEN_ARGS (always non-empty, so no
# empty-array expansion under `set -u` on bash 3.2).
maybe_add_browser() {
  local a has=0
  OPEN_ARGS=()
  for a in "$@"; do
    case "$a" in
      --browser|--browser=*) has=1 ;;
    esac
    OPEN_ARGS+=("$a")
  done
  if [ "$has" = 0 ]; then
    OPEN_ARGS+=("--browser=chromium")
  fi
}

cmd_open() {
  require_bin
  maybe_add_headed open "$@"
  maybe_add_browser "${OPEN_ARGS[@]}"
  run_one 1 "${OPEN_ARGS[@]}"
}

cmd_batch() {
  require_bin
  local lineno=0 rc=0 ran_any=0 last_ok_out=''
  local line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      ''|'#'*) continue ;;
    esac
    if ! tokenize "$trimmed"; then
      [ -n "$last_ok_out" ] && inline_snapshot "$last_ok_out"
      fail "line $lineno: unterminated quote: $line"
    fi
    [ "${#TOKENS[@]}" -gt 0 ] || continue
    printf '### $ pw.sh %s\n' "$trimmed"
    ran_any=1
    rc=0
    # `open` in a batch still gets the headed preflight.
    if [ "${TOKENS[0]}" = open ]; then
      maybe_add_headed "${TOKENS[@]}"
      maybe_add_browser "${OPEN_ARGS[@]}"
      run_one 0 "${OPEN_ARGS[@]}" || rc=$?
    else
      run_one 0 "${TOKENS[@]}" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      printf '[pw] batch stopped at line %d: %s (exit %d)\n' "$lineno" "$trimmed" "$rc" >&2
      [ -n "$last_ok_out" ] && inline_snapshot "$last_ok_out"
      return "$rc"
    fi
    last_ok_out="$LAST_OUT"
  done
  [ "$ran_any" = 1 ] || fail 'batch got no commands on stdin'
  [ -n "$last_ok_out" ] && inline_snapshot "$last_ok_out"
  return 0
}

cmd_recover() {
  require_bin
  note 'running close-all (this workspace) then kill-all (every session on this host)'
  set +e
  "${PW_CMD[@]}" close-all </dev/null 2>&1 | strip_banner
  "${PW_CMD[@]}" kill-all </dev/null 2>&1 | strip_banner
  set -e
  return 0
}

main() {
  [ "$#" -ge 1 ] || usage
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pw-XXXXXX")"
  trap 'rm -rf "$TMP_DIR"' EXIT
  RUN_SEQ=0
  LAST_OUT=''

  case "$1" in
    -h|--help|help) usage ;;
    -) shift; cmd_batch ;;
    open) shift; cmd_open "$@" ;;
    recover) shift; cmd_recover ;;
    *) require_bin; run_one 1 "$@" ;;
  esac
}

main "$@"
