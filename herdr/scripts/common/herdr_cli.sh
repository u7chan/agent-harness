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
  local result
  result="$("$@" 2>/dev/null | jq -c '.' 2>/dev/null || echo '')"
  if [ -z "$result" ]; then
    echo '{}'
  else
    echo "$result"
  fi
}

herdr_cli_timeout_remaining() {
  local deadline_epoch="$1"
  local now
  now="$(date +%s)"
  local remaining_ms=$(( (deadline_epoch - now) * 1000 ))
  if [ "$remaining_ms" -lt 1000 ]; then
    echo 0
  else
    echo "$remaining_ms"
  fi
}

herdr_cli_deadline_expired() {
  local deadline_epoch="$1"
  local now
  now="$(date +%s)"
  [ "$now" -ge "$deadline_epoch" ]
}

herdr_cli_deadline_from_timeout() {
  local timeout_ms="$1"
  local deadline
  deadline=$(($(date +%s) + timeout_ms / 1000 + 1))
  echo "$deadline"
}
