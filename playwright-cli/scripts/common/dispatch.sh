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

# Build the argv JSON array for an action:
# [cli-path, <cli_flags>, <cli_command>, <flag, value>, ...]
pw_build_argv_json() {
  local action_def="$1" input="$2" session="$3" runtime_fields="$4" cli_path="$5"
  jq -cn \
    --argjson a "$action_def" \
    --argjson input "$input" \
    --arg session "$session" \
    --argjson runtime_fields "$runtime_fields" \
    --arg cli "$cli_path" \
    '
    [$cli] +
    ($a.cli_flags // ["--json"]) +
    [$a.cli_command] +
    [$a.cli_arguments[] as $arg |
      (if $arg.from == "session" then [$session]
       elif $arg.from == "field" then
         (if ($arg.optional == true) and (($input | has($arg.field)) | not) then []
          else [$input | getpath(($arg.field | split(".")))] end)
       elif $arg.from == "runtime" then
         (if ($runtime_fields | has($arg.field)) then [$runtime_fields[$arg.field]] else [] end)
       else [] end) as $values |
      if ($values | length) > 0 then [$arg.flag, $values[0]] else [] end
      | .[]
    ]
  '
}

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

# Spawn the CLI process group and wait up to the timeout.
pw_spawn_cli() {
  local timeout_seconds="$1"
  shift
  local out_file err_file
  out_file="$(mktemp /tmp/pwcli-out-XXXXXX)"
  err_file="$(mktemp /tmp/pwcli-err-XXXXXX)"
  setsid "$@" >"$out_file" 2>"$err_file" &
  local child=$!
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
    kill -TERM -- "-$child" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$child" 2>/dev/null || true
    set +e
    wait "$child" 2>/dev/null
    rc=124
    set -e
  else
    set +e
    wait "$child"
    rc=$?
    set -e
  fi
  PW_SPAWN_RC="$rc"
  PW_SPAWN_TIMED_OUT="$timed_out"
  PW_SPAWN_STDOUT="$out_file"
  PW_SPAWN_STDERR="$err_file"
  if [ "$rc" -ge 128 ] && [ "$timed_out" = "0" ]; then
    PW_SPAWN_SIGNAL="$(pw_signal_name $((rc - 128)))"
  else
    PW_SPAWN_SIGNAL=""
  fi
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
      if jq -e 'type == "array"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{sessions: .}' <<< "$stdout_json")"
      else
        PW_RESULT_STATUS="failed"
        PW_RESULT_PHASE="verification"
        PW_RESULT_CODE="SHAPE_MISMATCH"
        PW_RESULT_MESSAGE="expected a session list from playwright-cli list"
      fi
      ;;
    open)
      if jq -e '.status == "open"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{status: .status, name: .name, version: .version}' <<< "$stdout_json")"
      else
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics" "OPEN_FAILED" "playwright-cli open did not report an open session"
      fi
      ;;
    close)
      if jq -e '.status == "closed"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{status: .status, name: .name}' <<< "$stdout_json")"
      elif jq -e '.status == "not-open"' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_CODE="CLOSE_NOT_OPEN"
        PW_RESULT_MESSAGE="playwright-cli close reported the session is not open"
      else
        pw_set_execution_error "$is_write" "$stdout_json" "$precondition_codes" "$failure_semantics" "CLOSE_FAILED" "playwright-cli close did not report a closed session"
      fi
      ;;
    tool-result|snapshot)
      if jq -e '.ok == true and (.isError != true)' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '.data // null' <<< "$stdout_json")"
      elif jq -e '(.ok == false) or (.isError == true)' <<< "$stdout_json" >/dev/null 2>&1; then
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
    screenshot)
      if jq -e '.ok == true and (.isError != true)' <<< "$stdout_json" >/dev/null 2>&1; then
        PW_RESULT_STATUS="ok"
        PW_RESULT_DATA="$(jq -c '{file: (.file // null), error: null}' <<< "$stdout_json")"
      elif jq -e '(.ok == false) or (.isError == true)' <<< "$stdout_json" >/dev/null 2>&1; then
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
  cli_code="$(jq -r '.error.code // empty' <<< "$stdout_json" 2>/dev/null || true)"
  [ -n "$cli_code" ] || cli_code="$fallback_code"
  local message
  message="$(jq -r '.error.message // empty' <<< "$stdout_json" 2>/dev/null || true)"
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
