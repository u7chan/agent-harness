#!/usr/bin/env bash
set -euo pipefail

_pw_env_action=""
_pw_env_permission=""
_pw_env_session="null"
_pw_env_request_id="null"
_pw_env_runtime="null"

pw_envelope_set_context() {
  _pw_env_action="$1"
  _pw_env_permission="$2"
  _pw_env_session="$3"
  _pw_env_request_id="$4"
  _pw_env_runtime="$5"
}

pw_envelope_base() {
  jq -nc \
    --arg action "$_pw_env_action" \
    --arg permission "$_pw_env_permission" \
    --argjson session "$_pw_env_session" \
    --argjson request_id "$_pw_env_request_id" \
    '{
      schema_version: 1,
      request_id: $request_id,
      action: $action,
      permission: $permission,
      session: $session
    }'
}

pw_envelope_ok() {
  local data="${1:-null}"
  local artifacts="${2:-[]}"
  local runtime="${3:-$_pw_env_runtime}"
  pw_envelope_base | jq -c \
    --argjson data "$data" \
    --argjson artifacts "$artifacts" \
    --argjson runtime "$runtime" \
    '. + {
      status: "ok",
      data: $data,
      artifacts: $artifacts,
      runtime: $runtime,
      error: null
    }'
}

pw_envelope_already_applied() {
  local data="${1:-null}"
  local artifacts="${2:-[]}"
  local runtime="${3:-$_pw_env_runtime}"
  pw_envelope_base | jq -c \
    --argjson data "$data" \
    --argjson artifacts "$artifacts" \
    --argjson runtime "$runtime" \
    '. + {
      status: "already_applied",
      data: $data,
      artifacts: $artifacts,
      runtime: $runtime,
      error: null
    }'
}

pw_envelope_unknown_outcome() {
  local phase="$1"
  local code="$2"
  local message="$3"
  local exit_code="${4:-null}"
  local signal="${5:-null}"
  local stderr_excerpt="${6:-null}"
  local data="${7:-null}"
  local artifacts="${8:-[]}"
  local runtime="${9:-$_pw_env_runtime}"
  pw_envelope_base | jq -c \
    --arg phase "$phase" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson exit_code "$exit_code" \
    --argjson signal "$signal" \
    --argjson stderr_excerpt "$stderr_excerpt" \
    --argjson data "$data" \
    --argjson artifacts "$artifacts" \
    --argjson runtime "$runtime" \
    '. + {
      status: "unknown_outcome",
      data: $data,
      artifacts: $artifacts,
      runtime: $runtime,
      error: {
        code: $code,
        phase: $phase,
        message: $message,
        retryable: false,
        exit_code: $exit_code,
        signal: $signal,
        stderr_excerpt: $stderr_excerpt
      }
    }'
}

pw_envelope_fail() {
  local phase="$1"
  local code="$2"
  local message="$3"
  local retryable="${4:-false}"
  local exit_code="${5:-null}"
  local signal="${6:-null}"
  local stderr_excerpt="${7:-null}"
  local data="${8:-null}"
  local artifacts="${9:-[]}"
  local runtime="${10:-$_pw_env_runtime}"
  pw_envelope_base | jq -c \
    --arg phase "$phase" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson retryable "$retryable" \
    --argjson exit_code "$exit_code" \
    --argjson signal "$signal" \
    --argjson stderr_excerpt "$stderr_excerpt" \
    --argjson data "$data" \
    --argjson artifacts "$artifacts" \
    --argjson runtime "$runtime" \
    '. + {
      status: "failed",
      data: $data,
      artifacts: $artifacts,
      runtime: $runtime,
      error: {
        code: $code,
        phase: $phase,
        message: $message,
        retryable: $retryable,
        exit_code: $exit_code,
        signal: $signal,
        stderr_excerpt: $stderr_excerpt
      }
    }'
}
