#!/usr/bin/env bash
set -euo pipefail

# Fake playwright-cli for contract tests. Scenario-driven via env vars:
#   FAKE_PWCLI_VERSION          --version output (default 0.1.18)
#   FAKE_PWCLI_SESSIONS         JSON array returned by `list` (default [])
#   FAKE_PWCLI_SCENARIO_<CMD>   per-command scenario (default ok)
#   FAKE_PWCLI_SURVIVING_CHILD=1  spawn a setsid child that outlives a hang

EMBEDDED_VERSION="1.63.0-alpha-2026-08-05"

help_payload() {
  local cmd="$1"
  jq -nc --arg command "$cmd" --arg payload "Usage: playwright-cli $cmd [options]" \
    '{command: $command, payload: $payload}'
}

default_response() {
  local cmd="$1"
  local name="" url="" kind="" value="" index="" text="" option="" output="" full_page="false"
  local prev=""
  local arg
  for arg in "$@"; do
    case "$prev" in
      --name) name="$arg" ;;
      --url) url="$arg" ;;
      --kind) kind="$arg" ;;
      --value) value="$arg" ;;
      --index) index="$arg" ;;
      --text) text="$arg" ;;
      --option) option="$arg" ;;
      --output) output="$arg" ;;
      --full-page) full_page="$arg" ;; 
    esac
    case "$arg" in
      --name|--url|--kind|--value|--index|--text|--option|--output|--full-page) prev="$arg" ;;
      *) prev="" ;;
    esac
  done

  case "$cmd" in
    open)
      jq -nc --arg name "$name" --arg v "$EMBEDDED_VERSION" '{status: "open", name: $name, version: $v}'
      ;;
    close)
      jq -nc --arg name "$name" '{status: "closed", name: $name}'
      ;;
    goto)
      jq -nc --arg url "$url" '{ok: true, data: {url: $url, ok: true}}'
      ;;
    go-back)
      jq -nc '{ok: true, data: {ok: true}}'
      ;;
    go-forward)
      jq -nc '{ok: true, data: {ok: true}}'
      ;;
    reload)
      jq -nc '{ok: true, data: {ok: true}}'
      ;;
    snapshot)
      local size="${FAKE_PWCLI_SNAPSHOT_SIZE:-1000}"
      local html
      html="$(printf 'x%.0s' $(seq 1 "$size"))"
      jq -nc --arg html "$html" '{ok: true, data: {snapshot: {html: $html}}}'
      ;;
    find)
      jq -nc --arg kind "$kind" --arg value "$value" '{ok: true, data: {matches: []}}'
      ;;
    tab-list)
      jq -nc '{ok: true, data: {tabs: []}}'
      ;;
    tab-new)
      jq -nc --arg url "$url" '{ok: true, data: {tab: {id: "tab-2", url: ($url // null), active: true}}}'
      ;;
    tab-select)
      jq -nc --arg index "$index" '{ok: true, data: {tab: {index: ($index | tonumber)}}}'
      ;;
    tab-close)
      jq -nc --arg index "$index" '{ok: true, data: {closed: ($index | tonumber)}}'
      ;;
    console)
      jq -nc '{ok: true, data: {messages: []}}'
      ;;
    click)
      jq -nc '{ok: true, data: {verified: true}}'
      ;;
    check)
      jq -nc '{ok: true, data: {verified: true}}'
      ;;
    uncheck)
      jq -nc '{ok: true, data: {verified: true}}'
      ;;
    hover)
      jq -nc '{ok: true, data: {verified: true}}'
      ;;
    fill)
      if [ -n "${FAKE_PWCLI_ECHO_FILE:-}" ]; then
        printf '%s' "$text" >> "$FAKE_PWCLI_ECHO_FILE"
      fi
      jq -nc '{ok: true, data: {verified: true}}'
      ;;
    select)
      jq -nc --arg option "$option" '{ok: true, data: {verified: true, option: $option}}'
      ;;
    screenshot)
      if [ -n "$output" ]; then
        printf 'fake-png-bytes-%s' "$(basename "$output")" > "$output"
      fi
      jq -nc --arg file "$output" '{ok: true, file: $file}'
      ;;
    no-file)
      jq -nc '{ok: true, file: ""}'
      ;;
    list)
      printf '%s\n' "${FAKE_PWCLI_SESSIONS:-[]}"
      ;;
    *)
      jq -nc '{ok: true, data: {}}'
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

  local cmd="" help_cmd=""
  local i=0
  for arg in "${args[@]}"; do
    if [ "$arg" = "--version" ]; then
      printf '%s\n' "${FAKE_PWCLI_VERSION:-0.1.18}"
      exit 0
    fi
    if [ "$arg" = "--help" ] && [ -z "$help_cmd" ]; then
      help_cmd="${args[$((i + 1))]:-}"
    fi
    if [ "$arg" = "--json" ]; then
      :
    elif [[ "$arg" != --* ]]; then
      [ -z "$cmd" ] && cmd="$arg"
    fi
    i=$((i + 1))
  done

  if [ -n "$help_cmd" ]; then
    help_payload "$help_cmd"
    exit 0
  fi

  if [ -z "$cmd" ]; then
    echo "playwright-cli: no command" >&2
    exit 2
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
      default_response "$cmd" "$@"
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
      default_response "$cmd" "$@"
      exit 3
      ;;
    signal)
      kill -KILL "$$"
      ;;
    not-open)
      jq -nc --arg name "$(printf '%s' "${args[*]}" | grep -oP '(?<=--name )[^ ]+' || true)" '{status: "not-open", name: $name}'
      exit 0
      ;;
    stderr)
      echo "diagnostic stderr noise" >&2
      default_response "$cmd" "$@"
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
      FAKE_PWCLI_SNAPSHOT_SIZE=70000 default_response "$cmd" "$@"
      ;;
    no-file)
      jq -nc '{ok: true, file: ""}'
      ;;
    hang)
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
