#!/usr/bin/env bash
set -euo pipefail

FAKE_STATE="${FAKE_STATE_DIR:-/tmp/herdr-fake-state}"
mkdir -p "$FAKE_STATE"

_pane_current() {
  cat <<'EOF'
{"schema_version":1,"status":"ok","result":{"pane":{"pane_id":"pane-1","workspace_id":"ws-fake-001","tab_id":"tab-1","agent":"opencode","agent_status":"running","cols":160}}}
EOF
}

_pane_split() {
  local pane_idx="${FAKE_PANE_IDX:-0}"
  FAKE_PANE_IDX=$((pane_idx + 1))
  local pid="fake-pane-${FAKE_PANE_IDX}"
  cat <<EOF
{"schema_version":1,"status":"ok","result":{"pane":{"pane_id":"$pid","workspace_id":"ws-fake-001","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_pane_get() {
  local pid="${1:-unknown}"
  cat <<EOF
{"schema_version":1,"status":"ok","result":{"pane":{"pane_id":"$pid","workspace_id":"ws-fake-001","tab_id":"tab-1","agent_status":"unknown"}}}
EOF
}

_agent_start() {
  local name="$1"
  local kind="$2"
  echo "${kind} ${name}" >> "$FAKE_STATE/started_agents.log"
  cat <<EOF
{"schema_version":1,"status":"ok","result":{"agent":{"name":"$name","kind":"$kind","status":"running"}}}
EOF
}

_agent_rename() {
  local pid="$1"
  local name="$2"
  echo "rename ${pid} ${name}" >> "$FAKE_STATE/started_agents.log"
  cat <<EOF
{"schema_version":1,"status":"ok","result":{"agent":{"name":"$name","pane_id":"$pid"}}}
EOF
}

_pane_label() {
  local pid="$1"
  local label="$2"
  echo "label ${pid} ${label}" >> "$FAKE_STATE/pane_labels.log"
}

_agent_prompt() {
  local target="$1"
  local text="$2"
  echo "$text" > "$FAKE_STATE/${target}.last_prompt"
  cat <<EOF
{"schema_version":1,"status":"ok","result":{"agent":{"name":"$target"},"message":"prompt sent"}}
EOF
}

_agent_wait() {
  local target="$1"
  cat <<EOF
{"schema_version":1,"status":"completed","result":{"agent":{"name":"$target","status":"completed"}}}
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
  echo '{"schema_version":1,"status":"ok","result":{"agents":[]}}'
}

_pane_close() {
  local pid="$1"
  echo '{"schema_version":1,"status":"ok"}'
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
        *) echo '{"status":"failed","error":"unknown pane command"}' ;;
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
              --wait|--timeout|30000|60000|[0-9]*) shift ;;
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
        *) echo '{"status":"failed","error":"unknown agent command"}' ;;
      esac
      ;;
    *)
      echo '{"status":"failed","error":"unknown command"}'
      ;;
  esac
}

main "$@"
