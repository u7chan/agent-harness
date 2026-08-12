#!/usr/bin/env bash
set -euo pipefail

# Constrained CLI dispatch: builds an argv array from validated input and the
# catalog mapping, spawns the CLI in its own process group, and classifies the
# result against the fixed precedence. No string evaluation is ever performed.

PW_SPAWN_RC=0
PW_SPAWN_TIMED_OUT=0
PW_SPAWN_SIGNAL=""
PW_SPAWN_STDOUT=""
PW_SPAWN_STDERR=""
PW_RESULT_STATUS=""
PW_RESULT_PHASE=""
PW_RESULT_CODE=""
PW_RESULT_MESSAGE=""
PW_RESULT_RETRYABLE="false"
PW_RESULT_EXIT_CODE="null"
PW_RESULT_SIGNAL="null"
PW_RESULT_DATA="null"
PW_RESULT_ARTIFACTS="[]"
PW_RESULT_STDERR_EXCERPT="null"

# Build the argv JSON array for an action. @playwright/cli@0.1.18 takes the
# session as a global `-s=<name>` argument and most command inputs positionally.
pw_build_argv_json() {
  local action_def="$1" input="$2" session="$3" runtime_fields="$4" cli_path="$5"
  jq -cn \
    --argjson a "$action_def" \
    --argjson input "$input" \
    --arg session "$session" \
    --argjson runtime_fields "$runtime_fields" \
    --arg cli "$cli_path" \
    '
    def haspath($path):
      if ($path | length) == 0 then true
      elif type != "object" then false
      elif (has($path[0]) | not) then false
      else .[$path[0]] | haspath($path[1:])
      end;
    def source_value($arg):
      if $arg.from == "field" then
        ($arg.field | split(".")) as $path |
        if ($input | haspath($path)) then {present: true, value: ($input | getpath($path))}
        else {present: false, value: null} end
      elif $arg.from == "runtime" then
        ($arg.field | split(".")) as $path |
        if ($runtime_fields | haspath($path)) then {present: true, value: ($runtime_fields | getpath($path))}
        else {present: false, value: null} end
      else {present: false, value: null}
      end;
    [$cli] +
    ($a.cli_flags // ["--json"]) +
    (if $a.session == "required" then ["-s=" + $session] else [] end) +
    [$a.cli_command] +
    [$a.cli_arguments[] as $arg |
      source_value($arg) as $source |
      if ($source.present | not) then []
      elif $arg.boolean == true then
        if $source.value == true then [$arg.flag] else [] end
      elif $arg.flag != null then [$arg.flag, ($source.value | tostring)]
      else [($source.value | tostring)]
      end
      | .[]
    ]
  '
}

# Read the spawn outputs into result fields.
pw_collect_spawn_output() {
  local out_size
  out_size="$(stat -c%s "$PW_SPAWN_STDOUT")"
  if [ "$out_size" -gt 0 ]; then
    PW_RESULT_STDOUT_RAW="$(cat "$PW_SPAWN_STDOUT")"
  else
    PW_RESULT_STDOUT_RAW=""
  fi
}

pw_stdout_valid_json() {
  if [ -z "$PW_RESULT_STDOUT_RAW" ]; then
    return 1
  fi
  # exactly one well-formed JSON document
  if ! jq -e 'length == 1' -s <<< "$PW_RESULT_STDOUT_RAW" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Redact known sensitive input values from a diagnostic excerpt.
# Values are read from a temp file, one per line, to survive whitespace.
pw_redact_text() {
  local text="$1" values_file="$2"
  if [ -s "$values_file" ]; then
    local value
    while IFS= read -r value; do
      [ -n "$value" ] || continue
      text="${text//"$value"/[REDACTED]}"
    done < "$values_file"
  fi
  printf '%s' "$text"
}

pw_stderr_excerpt() {
  local file="$1"
  local limit=1024
  shift
  if [ ! -s "$file" ]; then
    printf 'null'
    return 0
  fi
  local text
  text="$(head -c "$limit" "$file" || true)"
  text="$(pw_redact_text "$text" "$1")"
  jq -nc --arg text "$text" '$text'
}

# Collect sensitive input values for an action into a temp file.
pw_sensitive_values_file() {
  local action_def="$1" input="$2" values_file="$3"
  : > "$values_file"
  local fields
  fields="$(jq -r '.sensitive_fields[]?' <<< "$action_def")"
  [ -n "$fields" ] || return 0
  local f
  while read -r f; do
    [ -n "$f" ] || continue
    jq -r --arg f "$f" 'if has($f) and (.[$f] | type == "string") then .[$f] else empty end' <<< "$input" >> "$values_file"
  done <<< "$fields"
}

# Classify the spawn result using the fixed result precedence.
# Globals used: PW_SPAWN_RC/TIMED_OUT/SIGNAL, action metadata, PW_RESULT_STDOUT_RAW.
pw_classify_result() {
  local is_write="$1" adapter_kind="$2" precondition_codes="$3" failure_semantics="$4" session="$5"
  PW_RESULT_STATUS=""
  PW_RESULT_PHASE=""
  PW_RESULT_CODE=""
  PW_RESULT_MESSAGE=""
  PW_RESULT_RETRYABLE="false"
  PW_RESULT_EXIT_CODE="null"
  PW_RESULT_SIGNAL="null"
  PW_RESULT_DATA="null"

  # 1. timeout / signal
  if [ "$PW_SPAWN_TIMED_OUT" = "1" ]; then
    if [ "$is_write" = "true" ]; then
      PW_RESULT_STATUS="unknown_outcome"
    else
      PW_RESULT_STATUS="failed"
    fi
    PW_RESULT_PHASE="timeout"
    PW_RESULT_CODE="CLI_TIMEOUT"
    PW_RESULT_MESSAGE="playwright-cli did not finish within the timeout"
    return 0
  fi
  if [ -n "$PW_SPAWN_SIGNAL" ]; then
    if [ "$is_write" = "true" ]; then
      PW_RESULT_STATUS="unknown_outcome"
    else
      PW_RESULT_STATUS="failed"
    fi
    PW_RESULT_PHASE="signal"
    PW_RESULT_CODE="CLI_SIGNAL"
    PW_RESULT_MESSAGE="playwright-cli terminated by signal"
    PW_RESULT_SIGNAL="$(jq -nc --arg s "$PW_SPAWN_SIGNAL" '$s')"
    return 0
  fi

  # 2. empty / broken / multiple JSON on stdout
  if ! pw_stdout_valid_json; then
    if [ -z "$PW_RESULT_STDOUT_RAW" ]; then
      PW_RESULT_CODE="EMPTY_OUTPUT"
      PW_RESULT_MESSAGE="playwright-cli produced no stdout"
    else
      PW_RESULT_CODE="INVALID_JSON_OUTPUT"
      PW_RESULT_MESSAGE="playwright-cli stdout is not a single valid JSON document"
    fi
    if [ "$is_write" = "true" ]; then
      PW_RESULT_STATUS="unknown_outcome"
    else
      PW_RESULT_STATUS="failed"
    fi
    PW_RESULT_PHASE="decode"
    return 0
  fi

  local stdout_json
  stdout_json="$(cat "$PW_SPAWN_STDOUT")"

  # 3. non-zero exit: execution error regardless of a valid-looking body
  if [ "$PW_SPAWN_RC" -ne 0 ]; then
    pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics"
    return 0
  fi

  # 4. adapter-specific shape verification
  case "$adapter_kind" in
    list)
      if jq -e 'type == "object" and (.browsers | type == "array")' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{sessions: .browsers}' <<< "$stdout_json")"
      else
        PW_RESULT_STATUS="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="SHAPE_MISMATCH"
        PW_RESULT_MESSAGE="expected a session list from playwright-cli list"
      fi
      ;;
    open)
      if jq -e --arg session "$session" '.session == $session and (.pid | type == "number") and has("result")' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{status: "open", name: .session, pid, result}' <<< "$stdout_json")"
      else
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics" "OPEN_FAILED" "playwright-cli open did not report an open session"
      fi
      ;;
    close)
      if jq -e --arg session "$session" '.session == $session and .status == "closed"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{status, name: .session}' <<< "$stdout_json")"
      elif jq -e --arg session "$session" '.session == $session and .status == "not-open"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_CODE="CLOSE_NOT_OPEN"
        PW_RESULT_MESSAGE="playwright-cli close reported the session is not open"
      else
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics" "CLOSE_FAILED" "playwright-cli close did not report a closed session"
      fi
      ;;
    tool-result)
      if jq -e 'type == "object" and (.isError != true) and (has("result") or has("snapshot"))' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '.' <<< "$stdout_json")"
      elif jq -e '.isError == true' <<< "$stdout_json" >/dev/null 2>&1; then
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics"
      else
        PW_RESULT_STATUS="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="SHAPE_MISMATCH"
        PW_RESULT_MESSAGE="playwright-cli output does not match the tool-result shape"
        if [ "$is_write" = "true" ]; then
          PW_RESULT_STATUS="unknown_outcome"
        fi
      fi
      ;;
    snapshot)
      if jq -e 'type == "object" and (.isError != true) and has("snapshot")' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '.' <<< "$stdout_json")"
      elif jq -e '.isError == true' <<< "$stdout_json" >/dev/null 2>&1; then
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics"
      else
        PW_RESULT_STATUS="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="SHAPE_MISMATCH"
        PW_RESULT_MESSAGE="playwright-cli output does not match the snapshot shape"
      fi
      ;;
    screenshot)
      if jq -e 'type == "object" and (.isError != true) and has("result")' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '.' <<< "$stdout_json")"
      elif jq -e '.isError == true' <<< "$stdout_json" >/dev/null 2>&1; then
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics"
      else
        PW_RESULT_STATUS="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="SHAPE_MISMATCH"
        PW_RESULT_MESSAGE="playwright-cli output does not match the screenshot shape"
        if [ "$is_write" = "true" ]; then
          PW_RESULT_STATUS="unknown_outcome"
        fi
      fi
      ;;
  esac
  return 0
}

# Classify an execution error (isError or non-zero exit) per precedence rule 6.
pw_set_execution_error() {
  local is_write="$1" stdout_json="$2" precondition_codes="$3" failure_semantics="$4"
  local fallback_code="${5:-CLI_ERROR}" fallback_message="${6:-playwright-cli reported an error}"
  local cli_code
  cli_code="$(jq -r 'if (.error | type) == "object" then .error.code // empty else empty end' <<< "$stdout_json" 2>/dev/null || true)"
  [ -n "$cli_code" ] || cli_code="$fallback_code"
  local message
  message="$(jq -r 'if (.error | type) == "string" then .error elif (.error | type) == "object" then .error.message // empty else empty end' <<< "$stdout_json" 2>/dev/null || true)"
  [ -n "$message" ] || message="$fallback_message"

  local is_precondition="false"
  if [ "$is_write" = "true" ]; then
    is_precondition="$(jq -nc --arg code "$cli_code" --argjson codes "$precondition_codes" \
      '($codes | index($code)) != null')"
  fi

  if [ "$is_write" != "true" ] || [ "$is_precondition" = "true" ] || [ "$failure_semantics" = "definite" ]; then
    PW_RESULT_STATUS="failed"
    PW_RESULT_PHASE="execution"
    PW_RESULT_CODE="$cli_code"
    PW_RESULT_MESSAGE="$message"
  else
    PW_RESULT_STATUS="unknown_outcome"
    PW_RESULT_PHASE="execution"
    PW_RESULT_CODE="CLI_ERROR_UNCERTAIN"
    PW_RESULT_MESSAGE="playwright-cli reported an error whose applicability cannot be determined"
  fi
}

# Append an artifact metadata entry to the result artifacts array.
pw_result_add_artifact() {
  local metadata="$1"
  PW_RESULT_ARTIFACTS="$(jq -c --argjson m "$metadata" '. + [$m]' <<< "$PW_RESULT_ARTIFACTS")"
}
