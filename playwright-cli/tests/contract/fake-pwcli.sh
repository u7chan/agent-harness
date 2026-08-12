#!/usr/bin/env bash
set -euo pipefail

# Fake playwright-cli for contract tests. Scenario-driven via env vars:
#   FAKE_PWCLI_VERSION          --version output (default 0.1.18)
#   FAKE_PWCLI_SESSIONS         JSON array returned by `list` (default [])
#   FAKE_PWCLI_SCENARIO_<CMD>   per-command scenario (default ok)
#   FAKE_PWCLI_SURVIVING_CHILD=1  spawn a setsid child that outlives a hang

EMBEDDED_VERSION="1.63.0-alpha-2026-08-05"
REAL_CLI_FIXTURE="${FAKE_PWCLI_REAL_FIXTURE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/real-cli-fixture.json}"

help_payload() {
  local cmd="$1"
  jq --indent 2 --arg command "$cmd" '{help: (.help[$command] // "")}' "$REAL_CLI_FIXTURE"
}

FAKE_POSITIONALS=()
FAKE_OUTPUT=""
FAKE_FULL_PAGE="false"

parse_command_args() {
  local cmd="$1"
  shift
  FAKE_POSITIONALS=()
  FAKE_OUTPUT=""
  FAKE_FULL_PAGE="false"
  while (($# > 0)); do
    case "$1" in
      --filename)
        if [ "$cmd" != "screenshot" ] || [ "$#" -lt 2 ]; then
          jq -nc --arg option "filename" '{isError: true, error: ("Unknown option: --" + $option)}'
          return 1
        fi
        FAKE_OUTPUT="$2"
        shift 2
        ;;
      --full-page)
        if [ "$cmd" != "screenshot" ]; then
          jq -nc '{isError: true, error: "Unknown option: --full-page"}'
          return 1
        fi
        FAKE_FULL_PAGE="true"
        shift
        ;;
      --*)
        jq -nc --arg option "${1#--}" '{isError: true, error: ("Unknown option: --" + $option)}'
        return 1
        ;;
      *)
        FAKE_POSITIONALS+=("$1")
        shift
        ;;
    esac
  done
}

validate_positionals() {
  local cmd="$1" count="${#FAKE_POSITIONALS[@]}" min=0 max=0
  case "$cmd" in
    open|snapshot|find|tab-new|tab-close|console|screenshot) min=0; max=1 ;;
    goto|tab-select|check|uncheck|hover) min=1; max=1 ;;
    click) min=1; max=2 ;;
    fill|select) min=2; max=2 ;;
    list|close|go-back|go-forward|reload|tab-list) min=0; max=0 ;;
    *) min=0; max=0 ;;
  esac
  if [ "$count" -lt "$min" ] || [ "$count" -gt "$max" ]; then
    jq -nc --argjson expected "$max" --argjson received "$count" \
      '{isError: true, error: ("error: invalid argument count: expected " + ($expected|tostring) + ", received " + ($received|tostring))}'
    return 1
  fi
}

default_response() {
  local cmd="$1" session="$2"
  local first="${FAKE_POSITIONALS[0]:-}" second="${FAKE_POSITIONALS[1]:-}"

  case "$cmd" in
    open)
      jq -nc --arg session "$session" '{session: $session, pid: 4242, result: {snapshot: "- page"}}'
      ;;
    close)
      jq -nc --arg session "$session" '{session: $session, status: "closed"}'
      ;;
    goto)
      jq -nc --arg url "$first" '{result: ("Navigated to " + $url), snapshot: "- page"}'
      ;;
    go-back|go-forward|reload)
      jq -nc '{result: "Navigation complete", snapshot: "- page"}'
      ;;
    snapshot)
      local size="${FAKE_PWCLI_SNAPSHOT_SIZE:-1000}"
      local html
      html="$(printf 'x%.0s' $(seq 1 "$size"))"
      jq -nc --arg snapshot "$html" '{snapshot: $snapshot}'
      ;;
    find)
      jq -nc --arg text "$first" '{result: ("No matches for " + $text)}'
      ;;
    tab-list)
      jq -nc '{result: "### Open tabs"}'
      ;;
    tab-new)
      jq -nc --arg url "$first" '{result: ("New tab " + $url), snapshot: "- page"}'
      ;;
    tab-select)
      jq -nc --arg index "$first" '{result: ("Selected tab " + $index), snapshot: "- page"}'
      ;;
    tab-close)
      jq -nc --arg index "$first" '{result: ("Closed tab " + $index)}'
      ;;
    console)
      jq -nc '{result: "### Console messages"}'
      ;;
    click|check|uncheck|hover)
      jq -nc '{result: "Action complete", snapshot: "- page"}'
      ;;
    fill)
      if [ -n "${FAKE_PWCLI_ECHO_FILE:-}" ]; then
        printf '%s' "$second" >> "$FAKE_PWCLI_ECHO_FILE"
      fi
      jq -nc '{result: "Filled target", snapshot: "- page"}'
      ;;
    select)
      jq -nc --arg option "$second" '{result: ("Selected " + $option), snapshot: "- page"}'
      ;;
    screenshot)
      if [ -n "$FAKE_OUTPUT" ]; then
        printf 'fake-png-bytes-%s' "$(basename "$FAKE_OUTPUT")" > "$FAKE_OUTPUT"
      fi
      jq -nc --arg file "$FAKE_OUTPUT" '{result: ("- [Screenshot](" + $file + ")")}'
      ;;
    list)
      jq -nc --argjson browsers "${FAKE_PWCLI_SESSIONS:-[]}" '{browsers: $browsers}'
      ;;
    *)
      jq -nc '{result: "ok"}'
      ;;
  esac
}

error_response() {
  local cmd="$1" code="$2" message="$3" precondition="${4:-false}"
  jq -nc \
    --arg code "$code" \
    --arg message "$message" \
    --argjson precondition "$precondition" \
    '{ok: false, isError: true, precondition: $precondition, error: {code: $code, message: $message}}'
}

main() {
  local args=("$@")

  if [ -n "${FAKE_PWCLI_ARGV_FILE:-}" ]; then
    printf '%s\n' "${args[@]}" >> "$FAKE_PWCLI_ARGV_FILE"
  fi

  local cmd="" help_cmd="" session="default"
  local -a command_args=()
  local i=0
  for arg in "${args[@]}"; do
    if [ "$arg" = "--version" ]; then
      if [ "${FAKE_PWCLI_SCENARIO_version:-}" = "hang" ]; then
        trap '' TERM
        while :; do sleep 1; done
      fi
      printf '%s\n' "${FAKE_PWCLI_VERSION:-0.1.18}"
      exit 0
    fi
    if [ "$arg" = "--help" ] && [ -z "$help_cmd" ]; then
      help_cmd="${args[$((i + 1))]:-}"
    fi
    i=$((i + 1))
  done

  if [ -n "$help_cmd" ]; then
    if [ "${FAKE_PWCLI_SCENARIO_help:-}" = "hang" ]; then
      trap '' TERM
      while :; do sleep 1; done
    fi
    help_payload "$help_cmd"
    exit 0
  fi

  for arg in "${args[@]}"; do
    case "$arg" in
      --json|--raw) ;;
      -s=*) session="${arg#-s=}" ;;
      --session=*) session="${arg#--session=}" ;;
      *)
        if [ -z "$cmd" ]; then
          cmd="$arg"
        else
          command_args+=("$arg")
        fi
        ;;
    esac
  done

  if [ -z "$cmd" ]; then
    echo "playwright-cli: no command" >&2
    exit 2
  fi

  if ! parse_command_args "$cmd" "${command_args[@]}"; then
    exit 1
  fi
  if ! validate_positionals "$cmd"; then
    exit 1
  fi

  local scenario=""
  scenario="$(printenv "FAKE_PWCLI_SCENARIO_$cmd" 2>/dev/null || true)"
  # Per-command scenarios may also come from a file (env names cannot carry
  # hyphens, e.g. FAKE_PWCLI_SCENARIO_tab-close).
  if [ -z "$scenario" ] && [ -n "${FAKE_PWCLI_SCENARIO_FILE:-}" ] && [ -f "$FAKE_PWCLI_SCENARIO_FILE" ]; then
    scenario="$(grep -E "^${cmd}=" "$FAKE_PWCLI_SCENARIO_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  [ -n "$scenario" ] || scenario="ok"

  case "$scenario" in
    ok)
      default_response "$cmd" "$session"
      ;;
    error)
      error_response "$cmd" "SCENARIO_ERROR" "injected scenario error"
      exit 1
      ;;
    iserror-exit0)
      error_response "$cmd" "SCENARIO_ERROR" "injected scenario error"
      exit 0
      ;;
    precondition)
      case "$cmd" in
        tab-close)
          error_response "$cmd" "TAB_NOT_FOUND" "no tab at index" true
          ;;
        tab-select)
          error_response "$cmd" "TAB_NOT_FOUND" "no tab at index" true
          ;;
        click)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        fill)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        select)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        check)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        uncheck)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        hover)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        screenshot)
          error_response "$cmd" "TARGET_NOT_FOUND" "target not found" true
          ;;
        *)
          error_response "$cmd" "PRECONDITION_FAILED" "precondition failed" true
          ;;
      esac
      exit 1
      ;;
    empty)
      exit 0
      ;;
    broken)
      printf 'this is not json\n'
      exit 0
      ;;
    multi)
      printf '{"ok":true}\n{"ok":true}\n'
      exit 0
      ;;
    shape)
      printf '{"unexpected":"shape"}\n'
      exit 0
      ;;
    nonzero)
      default_response "$cmd" "$session"
      exit 3
      ;;
    signal)
      kill -KILL "$$"
      ;;
    not-open)
      jq -nc --arg session "$session" '{session: $session, status: "not-open"}'
      exit 0
      ;;
    stderr)
      echo "diagnostic stderr noise" >&2
      default_response "$cmd" "$session"
      ;;
    stderr-error)
      echo "diagnostic stderr noise" >&2
      error_response "$cmd" "SCENARIO_ERROR" "injected scenario error"
      exit 1
      ;;
    stderr-secret)
      local secret="${FAKE_PWCLI_SECRET:-s3cret}"
      echo "failed with value '$secret' visible" >&2
      error_response "$cmd" "SCENARIO_ERROR" "injected scenario error"
      exit 1
      ;;
    large)
      FAKE_PWCLI_SNAPSHOT_SIZE=70000 default_response "$cmd" "$session"
      ;;
    no-file)
      jq -nc '{result: "- [Screenshot](missing.png)"}'
      ;;
    bad-path)
      if [ -n "$FAKE_OUTPUT" ]; then
        printf 'fake-png-bytes-%s' "$(basename "$FAKE_OUTPUT")" > "$FAKE_OUTPUT"
      fi
      jq -nc --arg file "${FAKE_PWCLI_BAD_PATH:-/tmp/pwcli-evil.png}" '{result: ("- [Screenshot](" + $file + ")")}'
      ;;
    symlink-attack)
      if [ -n "$FAKE_OUTPUT" ]; then
        rm -f "$FAKE_OUTPUT"
        ln -s "${FAKE_PWCLI_ATTACK_TARGET:?missing attack target}" "$FAKE_OUTPUT"
      fi
      jq -nc --arg file "$FAKE_OUTPUT" '{result: ("- [Screenshot](" + $file + ")")}'
      ;;
    hang)
      if [ -n "${FAKE_PWCLI_SECRET:-}" ]; then
        printf 'hang secret: %s\n' "$FAKE_PWCLI_SECRET" >&2
      fi
      if [ "${FAKE_PWCLI_SURVIVING_CHILD:-0}" = "1" ]; then
        setsid sleep 300 >/dev/null 2>&1 &
        if [ -n "${FAKE_PWCLI_CHILD_PID_FILE:-}" ]; then
          printf '%s\n' "$!" > "$FAKE_PWCLI_CHILD_PID_FILE"
        fi
      fi
      trap '' TERM
      while :; do
        sleep 1
      done
      ;;
  esac
}

main "$@"
