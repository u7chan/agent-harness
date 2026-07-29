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
  cat <<'EOF'
{"id":"cli:pane:current","result":{"pane":{"pane_id":"pane-1","workspace_id":"ws-fake-001","tab_id":"tab-1","agent":"opencode","agent_status":"running","cols":160}}}
EOF
}

_pane_split() {
  local pid
  pid="$(_pane_next_id)"
  cat <<EOF
{"id":"cli:pane:split","result":{"pane":{"pane_id":"$pid","workspace_id":"ws-fake-001","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_pane_get() {
  local pid="${1:-unknown}"
  cat <<EOF
{"id":"cli:pane:get","result":{"pane":{"pane_id":"$pid","workspace_id":"ws-fake-001","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_agent_start() {
  local name="$1"
  local kind="$2"
  local mode="${FAKE_AGENT_START_MODE:-ok}"
  case "$mode" in
    fail)
      echo '{"id":"cli:agent:start","error":{"code":"AGENT_START_FAILED","message":"simulated failure"}}'
      ;;
    unknown)
      echo '{}'
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
  case "$mode" in
    fail)
      echo '{"id":"cli:agent:prompt","error":{"code":"PROMPT_FAILED","message":"simulated prompt failure"}}'
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
  cat <<EOF
{"id":"cli:agent:wait","result":{"agent":{"name":"$target","status":"completed"}}}
EOF
}

_agent_read() {
  local target="$1"
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
  case "$mode" in
    fail)
      echo '{"id":"cli:pane:close","error":{"code":"CLOSE_FAILED","message":"simulated close failure"}}'
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
        close) _pane_close "${1:-}" ;;
        label) _pane_label "${1:-}" "${2:-}" ;;
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
