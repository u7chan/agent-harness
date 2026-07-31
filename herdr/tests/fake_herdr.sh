#!/usr/bin/env bash
set -euo pipefail

FAKE_STATE="${FAKE_STATE_DIR:-/tmp/herdr-fake-state}"
mkdir -p "$FAKE_STATE"
STATE_FILE="$FAKE_STATE/panes.json"
HISTORY_FILE="$FAKE_STATE/commands.jsonl"

_root_id() { echo "${HERDR_PANE_ID:-pane-1}"; }
_workspace_id() { echo "${HERDR_WORKSPACE_ID:-${FAKE_WORKSPACE_ID:-ws-fake-001}}"; }
_tab_id() { echo "${HERDR_TAB_ID:-tab-1}"; }
_terminal_cols() { echo "${FAKE_TERMINAL_COLS:-240}"; }
_terminal_rows() { echo "${FAKE_TERMINAL_ROWS:-40}"; }

_state_init() {
  if [ ! -s "$STATE_FILE" ]; then
    jq -nc \
      --arg root "$(_root_id)" --arg workspace "$(_workspace_id)" --arg tab "$(_tab_id)" \
      --argjson cols "$(_terminal_cols)" --argjson rows "$(_terminal_rows)" \
      '{workspace_id:$workspace,tab_id:$tab,next_id:2,panes:[{pane_id:$root,workspace_id:$workspace,tab_id:$tab,x:0,y:0,cols:$cols,rows:$rows,agent_status:"running"}]}' \
      > "$STATE_FILE"
  fi
}

_record() {
  local command="$1"
  shift
  jq -nc --arg command "$command" --args --argjson args "$(printf '%s\n' "$@" | jq -R -s 'split("\n")[:-1]')" '{command:$command,args:$args}' >> "$HISTORY_FILE"
}

_pane_json() {
  local pane_id="$1"
  jq -c --arg pane_id "$pane_id" '.panes[] | select(.pane_id == $pane_id)' "$STATE_FILE"
}

_pane_current() {
  _state_init
  case "${FAKE_PANE_CURRENT_MODE:-ok}" in
    fail) echo '{"id":"cli:pane:current","error":{"code":"PANE_CURRENT_FAILED","message":"simulated failure"}}' ;;
    unknown) echo 'not-json' ;;
    *)
      local pane
      pane="$(_pane_json "$(_root_id)")"
      jq -nc --argjson pane "$pane" '{id:"cli:pane:current",result:{pane:$pane}}'
      ;;
  esac
}

_pane_list() {
  _state_init
  case "${FAKE_LIST_MODE:-ok}" in
    fail) echo '{"id":"cli:pane:list","error":{"code":"PANE_LIST_FAILED","message":"simulated failure"}}' ;;
    unknown) echo '{}' ;;
    *) jq -c '{id:"cli:pane:list",result:{panes:.panes}}' "$STATE_FILE" ;;
  esac
}

_pane_layout() {
  local pane_id="$1"
  _state_init
  case "${FAKE_LAYOUT_MODE:-ok}" in
    fail) echo '{"id":"cli:pane:layout","error":{"code":"PANE_LAYOUT_FAILED","message":"simulated failure"}}' ;;
    unknown) echo '{}' ;;
    *)
      local pane
      pane="$(_pane_json "$pane_id")"
      if [ -z "$pane" ]; then
        echo '{"id":"cli:pane:layout","error":{"code":"PANE_NOT_FOUND","message":"pane not found"}}'
      else
        jq -nc --argjson pane "$pane" '{id:"cli:pane:layout",result:{layout:$pane,pane:$pane}}'
      fi
      ;;
  esac
}

_next_pane_id() {
  local result
  result="$(jq -r '.next_id' "$STATE_FILE")"
  jq '.next_id += 1' "$STATE_FILE" > "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  echo "fake-pane-$result"
}

_round_split_size() {
  local ratio="$1"
  local total="$2"
  awk -v r="$ratio" -v t="$total" 'BEGIN { printf "%d", int(r * t + 0.5) }'
}

_pane_split() {
  local target="" direction="" ratio="" cwd="" no_focus=false current=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane) target="${2:-}"; shift 2 ;;
      --current) current=true; target="$(_root_id)"; shift ;;
      --direction) direction="${2:-}"; shift 2 ;;
      --ratio) ratio="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      --no-focus) no_focus=true; shift ;;
      *) shift ;;
    esac
  done
  _state_init
  _record "pane.split" --pane "$target" --direction "$direction" --ratio "$ratio" --cwd "$cwd" --no-focus "$no_focus" --current "$current"
  case "${FAKE_SPLIT_MODE:-ok}" in
    fail)
      echo '{"id":"cli:pane:split","error":{"code":"PANE_SPLIT_FAILED","message":"simulated split failure"}}'
      return 0
      ;;
    no-op-unknown|not-executed|split-not-executed)
      echo '{}'
      return 0
      ;;
    malformed)
      echo 'not-json'
      return 0
      ;;
  esac

  local pane
  pane="$(_pane_json "$target")"
  if [ -z "$pane" ] || { [ "$direction" != "right" ] && [ "$direction" != "down" ]; }; then
    echo '{"id":"cli:pane:split","error":{"code":"PANE_SPLIT_INVALID","message":"invalid target or direction"}}'
    return 0
  fi
  local new_id old_x old_y old_cols old_rows retained created new_x new_y new_cols new_rows
  new_id="$(_next_pane_id)"
  old_x="$(jq -r '.x' <<< "$pane")"; old_y="$(jq -r '.y' <<< "$pane")"
  old_cols="$(jq -r '.cols' <<< "$pane")"; old_rows="$(jq -r '.rows' <<< "$pane")"
  if [ "$direction" = "right" ]; then
    retained="$(_round_split_size "$ratio" "$((old_cols - 1))")"
    created=$((old_cols - retained - 1))
    new_x=$((old_x + retained + 1)); new_y="$old_y"; new_cols="$created"; new_rows="$old_rows"
    jq --arg id "$target" --argjson cols "$retained" '.panes = [.panes[] | if .pane_id == $id then .cols = $cols else . end]' "$STATE_FILE" > "$STATE_FILE.tmp"
  else
    retained="$(_round_split_size "$ratio" "$((old_rows - 1))")"
    created=$((old_rows - retained - 1))
    new_x="$old_x"; new_y=$((old_y + retained + 1)); new_cols="$old_cols"; new_rows="$created"
    jq --arg id "$target" --argjson rows "$retained" '.panes = [.panes[] | if .pane_id == $id then .rows = $rows else . end]' "$STATE_FILE" > "$STATE_FILE.tmp"
  fi
  jq --arg id "$new_id" --arg workspace "$(_workspace_id)" --arg tab "$(_tab_id)" \
    --argjson x "$new_x" --argjson y "$new_y" --argjson cols "$new_cols" --argjson rows "$new_rows" \
    '.panes += [{pane_id:$id,workspace_id:$workspace,tab_id:$tab,x:$x,y:$y,cols:$cols,rows:$rows,agent_status:"unknown"}]' \
    "$STATE_FILE.tmp" > "$STATE_FILE"
  rm -f "$STATE_FILE.tmp"

  if [[ "${FAKE_SPLIT_MODE:-ok}" = "extra" || "${FAKE_SPLIT_MODE:-ok}" = "conflict-extra" || "${FAKE_SPLIT_MODE:-ok}" = "concurrent-extra" ]]; then
    local extra_id
    extra_id="$(_next_pane_id)"
    jq --arg id "$extra_id" --arg workspace "$(_workspace_id)" --arg tab "$(_tab_id)" \
      '.panes += [{pane_id:$id,workspace_id:$workspace,tab_id:$tab,x:0,y:0,cols:1,rows:1,agent_status:"unknown"}]' \
      "$STATE_FILE" > "$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  elif [[ "${FAKE_SPLIT_MODE:-ok}" = "other-change" || "${FAKE_SPLIT_MODE:-ok}" = "conflict-other" || "${FAKE_SPLIT_MODE:-ok}" = "concurrent-other" ]]; then
    jq --arg id "$(_root_id)" '.panes = [.panes[] | if .pane_id == $id then .x = .x + 1 else . end]' "$STATE_FILE" > "$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  fi

  case "${FAKE_SPLIT_MODE:-ok}" in
    unknown|no-response|response-missing|success-unknown) echo '{}' ;;
    *) jq -nc --arg id "$new_id" --arg workspace "$(_workspace_id)" --arg tab "$(_tab_id)" \
      '{id:"cli:pane:split",result:{pane:{pane_id:$id,workspace_id:$workspace,tab_id:$tab}}}' ;;
  esac
}

_pane_get() {
  local pane_id="$1"
  _state_init
  local busy_count="${FAKE_PANE_GET_BUSY_COUNT:-0}" state_file="$FAKE_STATE/${pane_id}.pane_get_count" count=0
  [ ! -f "$state_file" ] || count="$(<"$state_file")"
  count=$((count + 1)); printf '%s\n' "$count" > "$state_file"
  if [ "$count" -le "$busy_count" ] 2>/dev/null; then
    jq -nc --arg id "$pane_id" --arg workspace "$(_workspace_id)" '{id:"cli:pane:get",result:{pane:{pane_id:$id,workspace_id:$workspace,agent_status:"agent_pane_busy"}}}'
    return 0
  fi
  local pane
  pane="$(_pane_json "$pane_id")"
  [ -n "$pane" ] || pane="$(jq -nc --arg id "$pane_id" '{pane_id:$id,agent_status:"unknown"}')"
  jq -nc --argjson pane "$pane" '{id:"cli:pane:get",result:{pane:$pane}}'
}

_pane_close() {
  local pane_id="$1"
  _state_init
  printf '%s\n' "$pane_id" >> "$FAKE_STATE/close_invocations.log"
  _record "pane.close" "$pane_id"
  case "${FAKE_CLOSE_MODE:-ok}" in
    fail) echo '{"id":"cli:pane:close","error":{"code":"CLOSE_FAILED","message":"simulated close failure"}}' ;;
    unknown) echo '{}' ;;
    *)
      jq --arg id "$pane_id" '.panes = [.panes[] | select(.pane_id != $id)]' "$STATE_FILE" > "$STATE_FILE.tmp"
      mv -f "$STATE_FILE.tmp" "$STATE_FILE"
      echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
      ;;
  esac
}

_pane_rename() {
  local pane_id="$1" label="$2"
  printf '%s %s\n' "$pane_id" "$label" >> "$FAKE_STATE/pane_labels.log"
  _record "pane.rename" "$pane_id" "$label"
  echo '{"id":"cli:pane:rename","result":{"type":"ok"}}'
}

_agent_start() {
  local name="$1" kind="$2" pane="$3"
  _record "agent.start" "$name" "$kind" "$pane"
  case "${FAKE_AGENT_START_MODE:-ok}" in
    fail) echo '{"id":"cli:agent:start","error":{"code":"AGENT_START_FAILED","message":"simulated failure"}}' ;;
    unknown) echo '{}' ;;
    *)
      printf '%s %s %s\n' "$kind" "$name" "$pane" >> "$FAKE_STATE/started_agents.log"
      jq -nc --arg name "$name" --arg kind "$kind" '{id:"cli:agent:start",result:{agent:{name:$name,kind:$kind,status:"running"}}}'
      ;;
  esac
}

_agent_rename() {
  local pane_id="$1" name="$2"
  _record "agent.rename" "$pane_id" "$name"
  printf 'rename %s %s\n' "$pane_id" "$name" >> "$FAKE_STATE/started_agents.log"
  jq -nc --arg name "$name" --arg pane "$pane_id" '{id:"cli:agent:rename",result:{agent:{name:$name,pane_id:$pane}}}'
}

_agent_prompt() {
  local target="$1" text="$2"
  _record "agent.prompt" "$target"
  printf '%s\n' "$target" >> "$FAKE_STATE/prompt_invocations.log"
  case "${FAKE_PROMPT_MODE:-ok}" in
    fail) echo '{"id":"cli:agent:prompt","error":{"code":"PROMPT_FAILED","message":"simulated prompt failure"}}' ;;
    timeout) echo '{"id":"cli:agent:prompt","error":{"code":"PROMPT_TIMEOUT","message":"simulated prompt timeout"}}' ;;
    unknown) echo '{}' ;;
    *)
      printf '%s\n' "$text" > "$FAKE_STATE/${target}.last_prompt"
      jq -nc --arg target "$target" '{id:"cli:agent:prompt",result:{agent:{name:$target},message:"prompt sent"}}'
      ;;
  esac
}

_agent_wait() {
  local target="$1"
  case "${FAKE_WAIT_MODE:-ok}" in
    timeout) echo '{"id":"cli:agent:wait","error":{"code":"WAIT_TIMEOUT","message":"simulated timeout"}}' ;;
    fail) echo '{"id":"cli:agent:wait","error":{"code":"WAIT_FAILED","message":"simulated failure"}}' ;;
    *) jq -nc --arg target "$target" '{id:"cli:agent:wait",result:{agent:{name:$target,status:"completed"}}}' ;;
  esac
}

_agent_read() {
  local target="$1"
  if [ "${FAKE_READ_MODE:-ok}" = "fail" ]; then
    echo '{"id":"cli:agent:read","error":{"code":"READ_FAILED","message":"simulated failure"}}'
  else
    echo "Fake output from $target"
  fi
}

main() {
  if [ "${1:-}" = "--version" ]; then
    echo "herdr 0.7.5"
    return 0
  fi
  local command="${1:-}"
  shift || true
  case "$command" in
    pane)
      local sub="${1:-}"; shift || true
      if [ "${1:-}" = "--help" ]; then
        case "$sub" in
          layout) echo 'Usage: pane layout --pane PANE_ID' ;;
          split) echo 'Usage: pane split --pane PANE_ID --direction DIRECTION --ratio RATIO --cwd DIR --no-focus' ;;
          *) echo 'pane help' ;;
        esac
        return 0
      fi
      case "$sub" in
        current) _pane_current ;;
        list) _pane_list ;;
        layout)
          local pane_id=""
          while [ $# -gt 0 ]; do [ "$1" = "--pane" ] && pane_id="${2:-}" && shift 2 || shift; done
          _record "pane.layout" --pane "$pane_id"
          _pane_layout "$pane_id"
          ;;
        split) _pane_split "$@" ;;
        get) _pane_get "${1:-}" ;;
        close) _pane_close "${1:-}" ;;
        rename) _pane_rename "${1:-}" "${2:-}" ;;
        *) echo '{"id":"cli:pane:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown pane command"}}' ;;
      esac
      ;;
    agent)
      local sub="${1:-}"; shift || true
      if [ "${1:-}" = "--help" ]; then
        [ "$sub" = "start" ] && echo 'Usage: agent start NAME --kind KIND --pane PANE_ID' || echo 'agent help'
        return 0
      fi
      case "$sub" in
        start)
          local name="" kind="" pane=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --kind) kind="${2:-}"; shift 2 ;;
              --pane) pane="${2:-}"; shift 2 ;;
              *) name="$1"; shift ;;
            esac
          done
          _agent_start "$name" "$kind" "$pane"
          ;;
        rename) _agent_rename "${1:-}" "${2:-}" ;;
        prompt)
          local target="" text=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --wait) shift ;;
              --timeout) shift 2 ;;
              *)
                if [ -z "$target" ]; then target="$1"; elif [ -z "$text" ]; then text="$1"; fi
                shift ;;
            esac
          done
          _agent_prompt "$target" "$text"
          ;;
        wait) _agent_wait "${1:-}" ;;
        read) _agent_read "${1:-}" ;;
        list) echo '{"id":"cli:agent:list","result":{"agents":[]}}' ;;
        *) echo '{"id":"cli:agent:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown agent command"}}' ;;
      esac
      ;;
    *) echo '{"id":"cli:error","error":{"code":"UNKNOWN_COMMAND","message":"unknown command"}}' ;;
  esac
}

main "$@"
