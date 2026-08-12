#!/usr/bin/env bash
set -euo pipefail

PW_ACTIONS_JSON="${PW_ACTIONS_JSON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/actions.json}"

# Resolved runtime globals
PW_CLI_PATH=""
PW_CLI_PACKAGE_JSON=""
PW_CLI_PACKAGE_NAME=""
PW_CLI_PACKAGE_VERSION=""
PW_CLI_EMBEDDED_VERSION=""
PW_CLI_CORE_VERSION=""
PW_CLI_VERSION_OUT=""
PW_HELP_FINGERPRINT_SHA256=""
PW_SESSIONS="[]"
PW_SPAWN_RC=0
PW_SPAWN_TIMED_OUT=0
PW_SPAWN_SIGNAL=""
PW_SPAWN_STDOUT=""
PW_SPAWN_STDERR=""
PW_SPAWN_PID=""
PW_CLI_CAPTURE_STDOUT=""
PW_CLI_CAPTURE_STDERR=""

pw_signal_name() {
  local code="$1"
  local name
  name="$(kill -l "$code" 2>/dev/null || true)"
  if [ -n "$name" ]; then
    printf '%s' "$name"
  else
    printf 'UNKNOWN'
  fi
}

pw_cleanup_spawn_files() {
  local file
  for file in "${PW_SPAWN_STDOUT:-}" "${PW_SPAWN_STDERR:-}"; do
    case "$file" in
      /tmp/pwcli-out-*|/tmp/pwcli-err-*) rm -f -- "$file" ;;
    esac
  done
  PW_SPAWN_STDOUT=""
  PW_SPAWN_STDERR=""
}

pw_descendant_pids() {
  local root_pid="$1"
  local frontier="$root_pid" descendants="" parent pid
  while [ -n "$frontier" ]; do
    local next=""
    while read -r pid parent; do
      [ -n "$pid" ] && [ -n "$parent" ] || continue
      case " $frontier " in
        *" $parent "*)
          descendants="${descendants:+$descendants }$pid"
          next="${next:+$next }$pid"
          ;;
      esac
    done < <(ps -eo pid=,ppid=)
    frontier="$next"
  done
  printf '%s' "$descendants"
}

pw_stop_spawn_pid() {
  local child="$1"
  [ -n "$child" ] || return 0
  local descendants
  descendants="$(pw_descendant_pids "$child")"
  kill -TERM -- "-$child" 2>/dev/null || true
  if [ -n "$descendants" ]; then
    kill -TERM $descendants 2>/dev/null || true
  fi
  local i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL -- "-$child" 2>/dev/null || true
  if [ -n "$descendants" ]; then
    kill -KILL $descendants 2>/dev/null || true
  fi
  set +e
  wait "$child" 2>/dev/null
  set -e
}

pw_terminate_active_spawn() {
  local child="${PW_SPAWN_PID:-}"
  if [ -n "$child" ]; then
    pw_stop_spawn_pid "$child"
    PW_SPAWN_PID=""
  fi
}

# Run every CLI process, including version/help/list probes, in an isolated
# process group with the same timeout and termination boundary as actions.
pw_spawn_cli() {
  local timeout_seconds="$1"
  shift
  pw_cleanup_spawn_files
  local out_file err_file
  out_file="$(mktemp /tmp/pwcli-out-XXXXXX)"
  PW_SPAWN_STDOUT="$out_file"
  err_file="$(mktemp /tmp/pwcli-err-XXXXXX)"
  PW_SPAWN_STDERR="$err_file"
  setsid "$@" >"$out_file" 2>"$err_file" &
  local child=$!
  PW_SPAWN_PID="$child"
  local rc=0 timed_out=0
  local deadline=$(( $(date +%s) + timeout_seconds ))
  while kill -0 "$child" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      timed_out=1
      break
    fi
    sleep 0.05
  done
  if [ "$timed_out" = "1" ]; then
    pw_stop_spawn_pid "$child"
    rc=124
  else
    set +e
    wait "$child" 2>/dev/null
    rc=$?
    set -e
  fi
  PW_SPAWN_PID=""
  PW_SPAWN_RC="$rc"
  PW_SPAWN_TIMED_OUT="$timed_out"
  if [ "$rc" -ge 128 ] && [ "$timed_out" = "0" ]; then
    PW_SPAWN_SIGNAL="$(pw_signal_name $((rc - 128)))"
  else
    PW_SPAWN_SIGNAL=""
  fi
}

pw_runtime_timeout_seconds() {
  printf '%s' "${PWCLI_TIMEOUT_SECONDS:-30}"
}

# Capture a short-lived diagnostic invocation and remove its raw files before
# returning. Action invocations keep the files until result adaptation ends.
pw_capture_cli() {
  local timeout_seconds="$1"
  shift
  pw_spawn_cli "$timeout_seconds" "$@"
  PW_CLI_CAPTURE_STDOUT="$(cat "$PW_SPAWN_STDOUT")"
  PW_CLI_CAPTURE_STDERR="$(cat "$PW_SPAWN_STDERR")"
  local rc="$PW_SPAWN_RC" timed_out="$PW_SPAWN_TIMED_OUT"
  pw_cleanup_spawn_files
  [ "$timed_out" = "0" ] && [ "$rc" = "0" ]
}

pw_default_runtime_id() {
  jq -r '.compatibility.default_runtime' "$PW_ACTIONS_JSON"
}

pw_runtime_allowlist() {
  jq -c --arg id "$(pw_default_runtime_id)" '.compatibility.runtimes[$id]' "$PW_ACTIONS_JSON"
}

pw_catalog_commands() {
  jq -r --arg id "$(pw_default_runtime_id)" '.compatibility.runtimes[$id].help_fingerprint_commands[]' "$PW_ACTIONS_JSON"
}

pw_catalog_limits() {
  jq -c '.limits' "$PW_ACTIONS_JSON"
}

pw_resolve_cli() {
  local candidate="${PWCLI_BIN:-}"
  if [ -z "$candidate" ]; then
    candidate="$(command -v playwright-cli 2>/dev/null || true)"
  fi
  if [ -z "$candidate" ]; then
    PW_CLI_PATH=""
    return 1
  fi
  if [ ! -x "$candidate" ] && ! command -v "$candidate" >/dev/null 2>&1; then
    PW_CLI_PATH=""
    return 1
  fi
  PW_CLI_PATH="$(realpath "$candidate")"
  return 0
}

pw_resolve_package_json() {
  local dir
  dir="$(dirname "$PW_CLI_PATH")"
  local i
  for i in 0 1 2 3 4; do
    if [ -f "$dir/package.json" ]; then
      PW_CLI_PACKAGE_JSON="$dir/package.json"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  PW_CLI_PACKAGE_JSON=""
  return 1
}

# Read package metadata and --version into the PW_CLI_* globals.
# Returns 0 when every value is resolved, 1 otherwise.
pw_read_versions() {
  pw_resolve_package_json || return 1
  local pkg
  pkg="$(jq -c '{name: (.name // ""), version: (.version // ""), playwright: (.dependencies.playwright // ""), playwright_core: (.dependencies["playwright-core"] // "")}' "$PW_CLI_PACKAGE_JSON")"
  PW_CLI_PACKAGE_NAME="$(jq -r '.name' <<< "$pkg")"
  PW_CLI_PACKAGE_VERSION="$(jq -r '.version' <<< "$pkg")"
  PW_CLI_EMBEDDED_VERSION="$(jq -r '.playwright' <<< "$pkg")"
  PW_CLI_CORE_VERSION="$(jq -r '.playwright_core' <<< "$pkg")"
  PW_CLI_VERSION_OUT=""
  if pw_capture_cli "$(pw_runtime_timeout_seconds)" env NO_UPDATE_NOTIFIER=1 "$PW_CLI_PATH" --version; then
    PW_CLI_VERSION_OUT="$PW_CLI_CAPTURE_STDOUT"
  fi
  [ -n "$PW_CLI_PACKAGE_NAME" ] || return 1
  [ -n "$PW_CLI_PACKAGE_VERSION" ] || return 1
  [ -n "$PW_CLI_EMBEDDED_VERSION" ] || return 1
  [ -n "$PW_CLI_CORE_VERSION" ] || return 1
  [ -n "$PW_CLI_VERSION_OUT" ] || return 1
  return 0
}

# Produce the canonical help fingerprint JSON array:
# [{"command": ..., "payload": ...}] key-sorted and ordered by command.
pw_help_fingerprint() {
  local cli="$1"
  local cmd payload items="[]"
  while read -r cmd; do
    if ! pw_capture_cli "$(pw_runtime_timeout_seconds)" env NO_UPDATE_NOTIFIER=1 "$cli" --help "$cmd" --json; then
      return 1
    fi
    payload="$PW_CLI_CAPTURE_STDOUT"
    items="$(jq -c --arg command "$cmd" --arg payload "$payload" '. + [{command: $command, payload: $payload}]' <<< "$items")"
  done < <(pw_catalog_commands)
  jq -S 'sort_by(.command)' <<< "$items"
}

pw_help_fingerprint_sha256() {
  pw_help_fingerprint "$1" | sha256sum | cut -d' ' -f1
}

# Resolve the help fingerprint with a per-runtime cache. The cache key binds
# the CLI path, its mtime, and its version. The cache directory can be
# overridden via PWCLI_CACHE_DIR (used by contract tests to share one cache).
pw_resolve_help_fingerprint() {
  local cli="$1"
  local mtime
  mtime="$(stat -c%Y "$cli")"
  local commands_digest key
  commands_digest="$(pw_catalog_commands | sha256sum | cut -d' ' -f1)"
  key="$(printf '%s|%s|%s|%s' "$cli" "$mtime" "${PW_CLI_VERSION_OUT:-}" "$commands_digest" | sha256sum | cut -c1-16)"
  local cache_dir="${PWCLI_CACHE_DIR:-$PWD/.playwright-cli/agent-harness/cache}"
  local cache_file="$cache_dir/fingerprint-$key"
  if [ -f "$cache_file" ]; then
    PW_HELP_FINGERPRINT_SHA256="$(cat "$cache_file")"
    return 0
  fi
  local fp
  if ! fp="$(pw_help_fingerprint_sha256 "$cli")"; then
    PW_HELP_FINGERPRINT_SHA256=""
    return 1
  fi
  PW_HELP_FINGERPRINT_SHA256="$fp"
  mkdir -p -m 0700 "$cache_dir"
  umask 077
  printf '%s\n' "$fp" > "$cache_file"
  return 0
}

# Run `playwright-cli --json list` and normalize its `browsers` array into
# PW_SESSIONS. @playwright/cli@0.1.18 returns {"browsers": [...]}, not an array.
pw_session_list() {
  local out
  if ! pw_capture_cli "$(pw_runtime_timeout_seconds)" env NO_UPDATE_NOTIFIER=1 "$PW_CLI_PATH" --json list; then
    PW_SESSIONS="[]"
    return 1
  fi
  out="$PW_CLI_CAPTURE_STDOUT"
  if ! jq -e 'type == "object" and (.browsers | type == "array")' <<< "$out" >/dev/null 2>&1; then
    PW_SESSIONS="[]"
    return 1
  fi
  PW_SESSIONS="$(jq -c '.browsers' <<< "$out")"
  return 0
}

pw_session_version() {
  local session="$1"
  jq -c --arg name "$session" '[.[] | select(.name == $name)] | if length > 0 then .[0] else null end' <<< "$PW_SESSIONS"
}

pw_session_is_live() {
  local session="$1"
  local found
  found="$(jq -c --arg name "$session" '[.[] | select(.name == $name)] | length' <<< "$PW_SESSIONS")"
  [ "$found" != "0" ]
}

# Check that a live session is compatible with the allowlist runtime.
pw_session_compatible() {
  local session="$1"
  local allowlist
  allowlist="$(pw_runtime_allowlist)"
  jq -e --arg name "$session" --argjson al "$allowlist" \
    '[.[] | select(.name == $name)] | length > 0 and (.[0].compatible == true) and (.[0].version == $al.embedded_playwright_version)' \
    <<< "$PW_SESSIONS" >/dev/null 2>&1
}

# Full preflight: resolve the CLI, exact-match the allowlist contract
# (package name, CLI version, embedded versions, help fingerprint), and
# refresh the live session list.
# Returns 0 when the runtime is verified; 1 with PW_PREFLIGHT_CODE and
# PW_PREFLIGHT_MESSAGE set on any failure.
pw_preflight() {
  PW_PREFLIGHT_CODE=""
  PW_PREFLIGHT_MESSAGE=""
  if ! pw_resolve_cli; then
    PW_PREFLIGHT_CODE="RUNTIME_UNRESOLVED"
    PW_PREFLIGHT_MESSAGE="playwright-cli executable could not be resolved"
    return 1
  fi
  if ! pw_read_versions; then
    PW_PREFLIGHT_CODE="VERSION_UNVERIFIABLE"
    PW_PREFLIGHT_MESSAGE="CLI package version or embedded Playwright version could not be determined"
    return 1
  fi
  local allowlist
  allowlist="$(pw_runtime_allowlist)"
  local expected_package expected_version expected_embedded expected_core expected_fingerprint
  expected_package="$(jq -r '.cli_package' <<< "$allowlist")"
  expected_version="$(jq -r '.cli_version' <<< "$allowlist")"
  expected_embedded="$(jq -r '.embedded_playwright_version' <<< "$allowlist")"
  expected_core="$(jq -r '.embedded_playwright_core_version' <<< "$allowlist")"
  expected_fingerprint="$(jq -r '.help_fingerprint_sha256' <<< "$allowlist")"

  if [ "$PW_CLI_PACKAGE_NAME" != "$expected_package" ]; then
    PW_PREFLIGHT_CODE="UNSUPPORTED_RUNTIME_VERSION"
    PW_PREFLIGHT_MESSAGE="CLI package '$PW_CLI_PACKAGE_NAME' is not allowlisted (expected '$expected_package')"
    return 1
  fi
  if [ "$PW_CLI_PACKAGE_VERSION" != "$expected_version" ] || [ "$PW_CLI_VERSION_OUT" != "$expected_version" ]; then
    PW_PREFLIGHT_CODE="UNSUPPORTED_RUNTIME_VERSION"
    PW_PREFLIGHT_MESSAGE="CLI version '$PW_CLI_PACKAGE_VERSION' is not allowlisted (expected '$expected_version')"
    return 1
  fi
  if [ "$PW_CLI_EMBEDDED_VERSION" != "$expected_embedded" ]; then
    PW_PREFLIGHT_CODE="UNSUPPORTED_RUNTIME_VERSION"
    PW_PREFLIGHT_MESSAGE="embedded playwright version '$PW_CLI_EMBEDDED_VERSION' is not allowlisted (expected '$expected_embedded')"
    return 1
  fi
  if [ "$PW_CLI_CORE_VERSION" != "$expected_core" ]; then
    PW_PREFLIGHT_CODE="UNSUPPORTED_RUNTIME_VERSION"
    PW_PREFLIGHT_MESSAGE="embedded playwright-core version '$PW_CLI_CORE_VERSION' is not allowlisted (expected '$expected_core')"
    return 1
  fi
  if ! pw_resolve_help_fingerprint "$PW_CLI_PATH"; then
    PW_PREFLIGHT_CODE="VERSION_UNVERIFIABLE"
    PW_PREFLIGHT_MESSAGE="CLI help contract is unavailable"
    return 1
  fi
  if [ "$PW_HELP_FINGERPRINT_SHA256" != "$expected_fingerprint" ]; then
    PW_PREFLIGHT_CODE="UNSUPPORTED_RUNTIME_VERSION"
    PW_PREFLIGHT_MESSAGE="CLI help fingerprint does not match the allowlist"
    return 1
  fi
  if ! pw_session_list; then
    PW_PREFLIGHT_CODE="VERSION_UNVERIFIABLE"
    PW_PREFLIGHT_MESSAGE="playwright-cli session list is unavailable"
    return 1
  fi
  return 0
}

# Diagnostic-only resolution used by runtime.check and recovery.observe.
pw_resolve_diagnostics() {
  PW_PREFLIGHT_CODE=""
  PW_PREFLIGHT_MESSAGE=""
  if ! pw_resolve_cli; then
    PW_PREFLIGHT_CODE="RUNTIME_UNRESOLVED"
    PW_PREFLIGHT_MESSAGE="playwright-cli executable could not be resolved"
    return 1
  fi
  pw_read_versions || true
  if [ -n "$PW_CLI_PATH" ] && [ -n "$PW_CLI_VERSION_OUT" ]; then
    pw_resolve_help_fingerprint "$PW_CLI_PATH" || true
  fi
  pw_session_list || true
  return 0
}
