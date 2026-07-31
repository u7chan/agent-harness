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

herdr_cli_text_call_timeout() {
  local timeout_ms="$1"
  shift
  if [ "$timeout_ms" -le 0 ] 2>/dev/null; then
    echo ""
    return 0
  fi
  local timeout_seconds
  timeout_seconds="$(awk -v ms="$timeout_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
  local output rc=0
  output="$(timeout --kill-after=1s "${timeout_seconds}s" "$@" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo ""
  else
    printf '%s\n' "$output"
  fi
}

herdr_cli_version_at_least() {
  local version="$1"
  local major minor patch
  IFS=. read -r major minor patch <<< "$version"
  if [ "${major:-0}" -gt 0 ]; then
    return 0
  fi
  if [ "${major:-0}" -lt 0 ] || [ "${minor:-0}" -lt 7 ]; then
    return 1
  fi
  if [ "${minor:-0}" -gt 7 ]; then
    return 0
  fi
  [ "${patch:-0}" -ge 5 ]
}

herdr_cli_require_capabilities() {
  local deadline_ms="$1"
  local remaining version version_number
  remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
  version="$(herdr_cli_text_call_timeout "$remaining" herdr --version)"
  version_number="$(printf '%s\n' "$version" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ -z "$version_number" ] || ! herdr_cli_version_at_least "$version_number"; then
    return 1
  fi

  local help_text
  remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
  help_text="$(herdr_cli_text_call_timeout "$remaining" herdr pane layout --help)"
  printf '%s\n' "$help_text" | grep -q -- '--pane' || return 1
  remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
  help_text="$(herdr_cli_text_call_timeout "$remaining" herdr pane split --help)"
  for option in --pane --direction --ratio --cwd --no-focus; do
    printf '%s\n' "$help_text" | grep -q -- "$option" || return 1
  done
  remaining="$(herdr_cli_timeout_remaining "$deadline_ms")"
  help_text="$(herdr_cli_text_call_timeout "$remaining" herdr agent start --help)"
  printf '%s\n' "$help_text" | grep -q -- '--pane' || return 1
}

herdr_cli_pane_list_before_deadline() {
  local deadline_ms="$1"
  local workspace_id="$2"
  herdr_cli_call_before_deadline "$deadline_ms" herdr pane list --workspace "$workspace_id"
}

herdr_cli_pane_layout_before_deadline() {
  local deadline_ms="$1"
  local pane_id="$2"
  herdr_cli_call_before_deadline "$deadline_ms" herdr pane layout --pane "$pane_id"
}

herdr_cli_pane_split_before_deadline() {
  local deadline_ms="$1"
  local pane_id="$2"
  local direction="$3"
  local ratio="$4"
  herdr_cli_call_before_deadline "$deadline_ms" herdr pane split --pane "$pane_id" \
    --direction "$direction" --ratio "$ratio" --cwd "$PWD" --no-focus
}

herdr_cli_detect_agent_kind() {
  local pane_id="$1"
  local pane_info agent_kind
  pane_info="$(herdr_cli_safe_call_timeout 3000 herdr pane get "$pane_id")"
  if [ "$(herdr_cli_outcome "$pane_info")" = "ok" ]; then
    agent_kind="$(jq -r '.result.pane.agent_kind // empty' <<< "$pane_info")"
    printf '%s\n' "${agent_kind:-}"
  else
    echo ""
  fi
}
