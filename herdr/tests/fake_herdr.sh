#!/usr/bin/env bash
set -euo pipefail

FAKE_STATE="${FAKE_STATE_DIR:-/tmp/herdr-fake-state}"
mkdir -p "$FAKE_STATE"

_pane_counter_file() {
  echo "$FAKE_STATE/.pane_counter"
}

_pane_next_id() {
  local counter_file
  counter_file="$(_pane_counter_file)"
  local count=0
  if [ -f "$counter_file" ]; then
    count="$(cat "$counter_file")"
  fi
  count=$((count + 1))
  echo "$count" > "$counter_file"
  echo "fake-pane-${count}"
}

_pane_current() {
  local workspace_id="${FAKE_WORKSPACE_ID:-ws-fake-001}"
  case "${FAKE_PANE_CURRENT_MODE:-ok}" in
    fail)
      echo '{"id":"cli:pane:current","error":{"code":"PANE_CURRENT_FAILED","message":"simulated failure"}}'
      return 0
      ;;
    unknown)
      echo 'not-json'
      return 0
      ;;
  esac
  cat <<EOF
{"id":"cli:pane:current","result":{"pane":{"pane_id":"pane-1","workspace_id":"$workspace_id","tab_id":"tab-1","agent":"opencode","agent_status":"running","cols":160}}}
EOF
}

_pane_split() {
  local sleep_seconds="${FAKE_SPLIT_SLEEP:-0}"
  if [ "$sleep_seconds" != "0" ]; then
    sleep "$sleep_seconds"
  fi
  case "${FAKE_SPLIT_MODE:-ok}" in
    fail)
      echo '{"id":"cli:pane:split","error":{"code":"PANE_SPLIT_FAILED","message":"simulated split failure"}}'
      return 0
      ;;
    unknown)
      echo '{}'
      return 0
      ;;
  esac
  local pid
  pid="$(_pane_next_id)"
  local workspace_id="${FAKE_WORKSPACE_ID:-ws-fake-001}"
  cat <<EOF
{"id":"cli:pane:split","result":{"pane":{"pane_id":"$pid","workspace_id":"$workspace_id","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_pane_get() {
  local pid="${1:-unknown}"
  local workspace_id="${FAKE_WORKSPACE_ID:-ws-fake-001}"
  [ "${FAKE_PANE_GET_SLEEP:-0}" = "0" ] || sleep "$FAKE_PANE_GET_SLEEP"
  local busy_count="${FAKE_PANE_GET_BUSY_COUNT:-0}"
  if [ "$busy_count" -gt 0 ] 2>/dev/null; then
    local state_file="$FAKE_STATE/${pid}.pane_get_count"
    local count=0
    [ ! -f "$state_file" ] || count="$(cat "$state_file")"
    count=$((count + 1))
    echo "$count" > "$state_file"
    if [ "$count" -le "$busy_count" ]; then
      cat <<EOF
{"id":"cli:pane:get","result":{"pane":{"pane_id":"$pid","workspace_id":"$workspace_id","agent_status":"agent_pane_busy"}}}
EOF
      return 0
    fi
  fi
  cat <<EOF
{"id":"cli:pane:get","result":{"pane":{"pane_id":"$pid","workspace_id":"$workspace_id","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_agent_start() {
  local name="$1"
  local kind="$2"
  local mode="${FAKE_AGENT_START_MODE:-ok}"
  [ "${FAKE_AGENT_START_SLEEP:-0}" = "0" ] || sleep "$FAKE_AGENT_START_SLEEP"
  case "$mode" in
    fail)
      echo '{"id":"cli:agent:start","error":{"code":"AGENT_START_FAILED","message":"simulated failure"}}'
      ;;
    unknown)
      echo '{}'
      ;;
    busy-once)
      local busy_file="$FAKE_STATE/.agent_start_busy_once"
      if [ ! -f "$busy_file" ]; then
        touch "$busy_file"
        echo '{"id":"cli:agent:start","error":{"code":"agent_pane_busy","message":"simulated transient busy"}}'
      else
        echo "${kind} ${name}" >> "$FAKE_STATE/started_agents.log"
        cat <<EOF
{"id":"cli:agent:start","result":{"agent":{"name":"$name","kind":"$kind","status":"running"}}}
EOF
      fi
      ;;
    *)
      echo "${kind} ${name}" >> "$FAKE_STATE/started_agents.log"
      cat <<EOF
{"id":"cli:agent:start","result":{"agent":{"name":"$name","kind":"$kind","status":"running"}}}
EOF
      ;;
  esac
}

_agent_rename() {
  local pid="$1"
  local name="$2"
  echo "rename ${pid} ${name}" >> "$FAKE_STATE/started_agents.log"
  cat <<EOF
{"id":"cli:agent:rename","result":{"agent":{"name":"$name","pane_id":"$pid"}}}
EOF
}

_pane_label() {
  local pid="$1"
  local label="$2"
  echo "label ${pid} ${label}" >> "$FAKE_STATE/pane_labels.log"
  cat <<EOF
{"id":"cli:pane:label","result":{"type":"ok"}}
EOF
}

_agent_prompt() {
  local target="$1"
  local text="$2"
  local mode="${FAKE_PROMPT_MODE:-ok}"
  [ "${FAKE_PROMPT_SLEEP:-0}" = "0" ] || sleep "$FAKE_PROMPT_SLEEP"
  printf '%s\n' "$target" >> "$FAKE_STATE/prompt_invocations.log"
  case "$mode" in
    fail)
      echo '{"id":"cli:agent:prompt","error":{"code":"PROMPT_FAILED","message":"simulated prompt failure"}}'
      ;;
    timeout)
      echo '{"id":"cli:agent:prompt","error":{"code":"PROMPT_TIMEOUT","message":"simulated prompt timeout"}}'
      ;;
    unknown)
      echo '{}'
      ;;
    *)
      echo "$text" > "$FAKE_STATE/${target}.last_prompt"
      cat <<EOF
{"id":"cli:agent:prompt","result":{"agent":{"name":"$target"},"message":"prompt sent"}}
EOF
      ;;
  esac
}

_agent_wait() {
  local target="$1"
  case "${FAKE_WAIT_MODE:-ok}" in
    timeout)
      echo '{"id":"cli:agent:wait","error":{"code":"WAIT_TIMEOUT","message":"simulated timeout"}}'
      ;;
    fail)
      echo '{"id":"cli:agent:wait","error":{"code":"WAIT_FAILED","message":"simulated failure"}}'
      ;;
    empty)
      return 0
      ;;
    malformed|unknown)
      echo 'not-json'
      ;;
    missing_status)
      echo '{"id":"cli:agent:wait","result":{"agent":{"name":"test"}}}'
      ;;
    unknown_status)
      echo '{"id":"cli:agent:wait","result":{"agent":{"name":"test","status":"weird_state"}}}'
      ;;
    type_ok)
      echo '{"id":"cli:agent:wait","result":{"agent":{"name":"x"},"type":"ok"}}'
      ;;
    type_completed)
      echo '{"id":"cli:agent:wait","result":{"type":"completed"}}'
      ;;
    *) cat <<EOF
{"id":"cli:agent:wait","result":{"agent":{"name":"$target","status":"completed"}}}
EOF
      ;;
  esac
}

_agent_read() {
  local target="$1"
  case "${FAKE_READ_MODE:-ok}" in
    fail)
      echo '{"id":"cli:agent:read","error":{"code":"READ_FAILED","message":"simulated failure"}}'
      return 0
      ;;
    unknown)
      return 1
      ;;
  esac
  if [ -f "$FAKE_STATE/${target}.last_prompt" ]; then
    echo "Fake output from $target"
  else
    echo ""
  fi
}

_agent_list() {
  echo '{"id":"cli:agent:list","result":{"agents":[]}}'
}

_pane_close() {
  local pid="$1"
  local mode="${FAKE_CLOSE_MODE:-ok}"
  printf '%s\n' "$pid" >> "$FAKE_STATE/close_invocations.log"
  if [ "$mode" = "mixed" ]; then
    case "$pid" in
      *-1) mode="ok" ;;
      *-2) mode="fail" ;;
      *) mode="unknown" ;;
    esac
  fi
  case "$mode" in
    fail)
      echo '{"id":"cli:pane:close","error":{"code":"CLOSE_FAILED","message":"simulated close failure"}}'
      ;;
    not_found)
      echo '{"id":"cli:pane:close","error":{"code":"PANE_NOT_FOUND","message":"pane not found"}}'
      ;;
    unknown)
      echo '{}'
      ;;
    *)
      cat <<EOF
{"id":"cli:pane:close","result":{"type":"ok"}}
EOF
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    pane)
      local sub="${1:-}"; shift || true
      case "$sub" in
        current) _pane_current ;;
        split) _pane_split ;;
        get) _pane_get "${1:-}" ;;
        list)
          local pane_count=0
          [ ! -f "$FAKE_STATE/.pane_counter" ] || pane_count="$(cat "$FAKE_STATE/.pane_counter")"
          local panes='[]' pane_index
          for ((pane_index = 1; pane_index <= pane_count; pane_index++)); do
            panes="$(jq -c --arg id "fake-pane-$pane_index" '. + [{pane_id:$id}]' <<< "$panes")"
          done
          jq -nc --argjson panes "$panes" '{id:"cli:pane:list",result:{panes:$panes}}'
          ;;
        close) _pane_close "${1:-}" ;;
        rename) _pane_label "${1:-}" "${2:-}" ;;
        *) echo '{"id":"cli:pane:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown pane command"}}' ;;
      esac
      ;;
    agent)
      local sub="${1:-}"; shift || true
      case "$sub" in
        start)
          local name=""; local kind=""; local pane=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --kind) kind="$2"; shift 2 ;;
              --pane) pane="$2"; shift 2 ;;
              --timeout) shift 2 ;;
              *) name="$1"; shift ;;
            esac
          done
          _agent_start "$name" "$kind"
          ;;
        rename) _agent_rename "${1:-}" "${2:-}" ;;
        prompt)
          local target=""; local text=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --wait|--timeout|[0-9]*) shift ;;
              *)
                if [ -z "$target" ]; then target="$1"
                elif [ -z "$text" ]; then text="$1"
                fi
                shift ;;
            esac
          done
          _agent_prompt "$target" "$text"
          ;;
        wait)
          local target=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --timeout) shift 2 ;;
              [0-9]*) shift ;;
              *)
                if [ -z "$target" ]; then target="$1"; fi
                shift ;;
            esac
          done
          _agent_wait "$target"
          ;;
        read)
          local target=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --source|--lines) shift 2 ;;
              recent-unwrapped|[0-9]*) shift ;;
              *)
                if [ -z "$target" ]; then target="$1"; fi
                shift ;;
            esac
          done
          _agent_read "$target"
          ;;
        list) _agent_list ;;
        *) echo '{"id":"cli:agent:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown agent command"}}' ;;
      esac
      ;;
    *)
      echo '{"id":"cli:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown command"}}'
      ;;
  esac
}

main "$@"
