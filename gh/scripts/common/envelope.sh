#!/usr/bin/env bash
set -euo pipefail

_empty_json_obj="{}"

# Emit the common envelope without passing the data payload as a command
# argument: the OS caps a single exec argument (Linux MAX_ARG_STRLEN is
# 128 KiB), so a large read response would fail with "Argument list too long".
# The data flows through a temp file instead; the emitted JSON is unchanged.
_envelope_emit() {
  local status="$1"
  local action="$2"
  local target_json="$3"
  local data_json="$4"

  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/gh-envelope-XXXXXX")" || return 1
  printf '%s' "$data_json" > "$tmp"
  jq -nc \
    --arg status "$status" \
    --arg action "$action" \
    --argjson target "$target_json" \
    --slurpfile data "$tmp" \
    '{
      schema_version: 1,
      status: $status,
      action: $action,
      actor: "user",
      target: $target,
      data: $data[0]
    }' || rc=$?
  rm -f "$tmp"
  return "$rc"
}

envelope_ok() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  _envelope_emit "ok" "$action" "$target_json" "$data_json"
}

envelope_already_applied() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  _envelope_emit "already_applied" "$action" "$target_json" "$data_json"
}

envelope_unknown_outcome() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  _envelope_emit "unknown_outcome" "$action" "$target_json" "$data_json"
}

envelope_fail() {
  local action="$1"
  local code="$2"
  local message="$3"
  local retryable="${4:-false}"

  jq -nc \
    --arg action "$action" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson retryable "$retryable" \
    '{
      schema_version: 1,
      status: "failed",
      action: $action,
      actor: "user",
      target: null,
      data: null,
      error: {
        code: $code,
        message: $message,
        retryable: $retryable
      }
    }'
}
