#!/usr/bin/env bash
set -euo pipefail

_empty_json_obj="{}"

envelope_ok() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  jq -nc \
    --arg action "$action" \
    --argjson target "$target_json" \
    --argjson data "$data_json" \
    '{
      schema_version: 1,
      status: "ok",
      action: $action,
      actor: "user",
      target: $target,
      data: $data
    }'
}

envelope_already_applied() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  jq -nc \
    --arg action "$action" \
    --argjson target "$target_json" \
    --argjson data "$data_json" \
    '{
      schema_version: 1,
      status: "already_applied",
      action: $action,
      actor: "user",
      target: $target,
      data: $data
    }'
}

envelope_unknown_outcome() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  jq -nc \
    --arg action "$action" \
    --argjson target "$target_json" \
    --argjson data "$data_json" \
    '{
      schema_version: 1,
      status: "unknown_outcome",
      action: $action,
      actor: "user",
      target: $target,
      data: $data
    }'
}

envelope_waiting() {
  local action="$1"
  local target_json="$2"
  local data_json="$3"

  [ -z "$target_json" ] && target_json="$_empty_json_obj"
  [ -z "$data_json" ] && data_json="$_empty_json_obj"

  jq -nc \
    --arg action "$action" \
    --argjson target "$target_json" \
    --argjson data "$data_json" \
    '{
      schema_version: 1,
      status: "waiting",
      action: $action,
      actor: "user",
      target: $target,
      data: $data
    }'
}

herdr_read_input() {
  local arg="$1"
  if [ -f "$arg" ]; then
    cat "$arg"
  else
    echo "$arg"
  fi
}

envelope_fail() {
  local action="$1"
  local code="$2"
  local message="$3"
  local retryable="${4:-false}"
  local target_json="${5:-null}"
  local data_json="${6:-null}"

  jq -nc \
    --arg action "$action" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson retryable "$retryable" \
    --argjson target "$target_json" \
    --argjson data "$data_json" \
    '{
      schema_version: 1,
      status: "failed",
      action: $action,
      actor: "user",
      target: $target,
      data: $data,
      error: {
        code: $code,
        message: $message,
        retryable: $retryable
      }
    }'
}
