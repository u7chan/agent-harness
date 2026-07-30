#!/usr/bin/env bash
set -euo pipefail

herdr_cli_outcome() {
  local raw="$1"
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then
    echo "unknown"
    return 0
  fi
  local error
  error="$(echo "$raw" | jq -r '.error.code // .error // empty' 2>/dev/null || true)"
  if [ -n "$error" ]; then
    echo "failed"
    return 0
  fi
  local result
  result="$(echo "$raw" | jq -e '.result != null' 2>/dev/null)" || result="false"
  if [ "$result" = "true" ]; then
    echo "ok"
    return 0
  fi
  echo "unknown"
}

herdr_cli_error_code() {
  local raw="$1"
  jq -r '.error.code // empty' 2>/dev/null <<< "$raw" || true
}

herdr_cli_wait_state() {
  local raw="$1"
  local outcome
  outcome="$(herdr_cli_outcome "$raw")"
  if [ "$outcome" = "unknown" ]; then
    echo "unknown"
    return 0
  fi
  if [ "$outcome" = "failed" ]; then
    local code
    code="$(herdr_cli_error_code "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$code" in
      *timeout*|*timed*out*|*deadline*) echo "waiting" ;;
      *) echo "failed" ;;
    esac
    return 0
  fi

  local status
  status="$(jq -r '.result.agent.status // .result.status // empty' 2>/dev/null <<< "$raw" || true)"
  status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]')"
  case "$status" in
    waiting|running|busy|in_progress|in-progress) echo "waiting" ;;
    failed|error|cancelled|canceled) echo "failed" ;;
    completed|complete|done|ok|idle|succeeded|success) echo "completed" ;;
    *) echo "unknown" ;;
  esac
}

herdr_cli_result_ok() {
  local raw="$1"
  [ "$(herdr_cli_outcome "$raw")" = "ok" ]
}

herdr_cli_result_failed() {
  local raw="$1"
  [ "$(herdr_cli_outcome "$raw")" = "failed" ]
}

herdr_cli_result_unknown() {
  local raw="$1"
  [ "$(herdr_cli_outcome "$raw")" = "unknown" ]
}

herdr_cli_extract_field() {
  local raw="$1"
  local expr="$2"
  echo "$raw" | jq -r "$expr" 2>/dev/null || echo ""
}

herdr_cli_safe_call() {
  herdr_cli_safe_call_timeout 0 "$@"
}

herdr_cli_safe_call_timeout() {
  local timeout_ms="$1"
  shift
  local raw="" rc=0
  if [ "$timeout_ms" -gt 0 ] 2>/dev/null; then
    local timeout_seconds
    timeout_seconds="$(awk -v ms="$timeout_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
    if raw="$(timeout --kill-after=1s "${timeout_seconds}s" "$@" 2>/dev/null)"; then
      rc=0
    else
      rc=$?
    fi
  else
    if raw="$("$@" 2>/dev/null)"; then
      rc=0
    else
      rc=$?
    fi
  fi
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo '{}'
    return 0
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<< "$raw"; then
    echo '{}'
    return 0
  fi
  jq -c -s '.[0]' <<< "$raw"
}

herdr_cli_timeout_remaining() {
  local deadline_ms="$1"
  local now
  now="$(herdr_cli_now_ms)"
  local remaining_ms=$((deadline_ms - now))
  if [ "$remaining_ms" -le 0 ]; then
    echo 0
  else
    echo "$remaining_ms"
  fi
}

herdr_cli_deadline_expired() {
  local deadline_ms="$1"
  local now
  now="$(herdr_cli_now_ms)"
  [ "$now" -ge "$deadline_ms" ]
}

herdr_cli_deadline_from_timeout() {
  local timeout_ms="$1"
  echo $(( $(herdr_cli_now_ms) + timeout_ms ))
}

herdr_cli_now_ms() {
  local epoch_ns
  epoch_ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$epoch_ns" =~ ^[0-9]{10,19}$ ]]; then
    echo $((10#$epoch_ns / 1000000))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

herdr_cli_call_before_deadline() {
  local deadline_ms="$1"
  shift
  local remaining
  remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
  if [ "$remaining" -le 0 ]; then
    echo '{}'
    return 0
  fi
  herdr_cli_safe_call_timeout "$remaining" "$@"
}
