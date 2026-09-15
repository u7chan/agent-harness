#!/usr/bin/env bash
# Start a Pi team member in a Herdr worktree workspace pane and delegate the
# task file body to it in one command.
#
# Sequence: scope check, `herdr agent start` with flags only, bounded
# readiness wait, pane rename, then the task body through the existing
# parent-delegate-async.sh wrapper (which appends the direct-parent return
# instruction and performs the same scope check again).
#
# The worktree workspace and its pane must already exist; this script never
# creates, shares, or removes workspaces, worktrees, tabs, or panes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scope.sh
source "$script_dir/lib/scope.sh"
parent_script="$script_dir/parent-delegate-async.sh"

# Bounded readiness wait, in milliseconds, for both `agent start` and
# `agent wait`. A started agent that is not interactive within this window
# fails the command instead of blocking forever.
startup_timeout_ms=60000

usage() {
  printf 'Usage: %s <pane-id> <agent-name> --provider <provider> --model <model> --thinking <level> <task-file>\n' "$0" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_workspace() {
  [[ "$1" =~ ^[[:alnum:]_.-]+$ ]]
}

valid_pane() {
  [[ "$1" =~ ^[[:alnum:]_.-]+:[[:alnum:]_.-]+$ ]]
}

# Single-line tokens passed as agent start arguments. The value becomes one
# discrete argument, but agent start encodes them for the target shell, so
# reject anything outside an unreserved token shape before starting anything.
valid_flag_value() {
  [[ "$1" =~ ^[[:alnum:]_.:@+~/-]+$ ]]
}

[ "$#" -ge 2 ] || usage
pane="$1"
agent_name="$2"
shift 2

provider=''
model=''
thinking=''
task_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || usage; provider="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || usage; model="$2"; shift 2 ;;
    --thinking) [ "$#" -ge 2 ] || usage; thinking="$2"; shift 2 ;;
    --) shift; [ "$#" -ge 1 ] || usage; [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
    -*) usage ;;
    *) [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
  esac
done

[ -n "$provider" ] && [ -n "$model" ] && [ -n "$thinking" ] && [ -n "$task_file" ] || usage

valid_pane "$pane" || fail 'pane must be a pane ID'
[[ "$agent_name" =~ ^[[:alnum:]_.-]+$ ]] || fail 'agent name must match [A-Za-z0-9_.-]+'
valid_flag_value "$provider" || fail 'provider must be a single-line token'
valid_flag_value "$model" || fail 'model must be a single-line token'
case "$thinking" in
  off|minimal|low|medium|high|xhigh|max) ;;
  *) fail 'thinking must be one of off, minimal, low, medium, high, xhigh, max' ;;
esac
[ -f "$task_file" ] || fail 'task file does not exist'
[ -r "$task_file" ] || fail 'task file is not readable'
[ -s "$task_file" ] || fail 'task file is empty'

[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'
[ -x "$parent_script" ] || fail 'parent-delegate-async.sh is required'

parent_pane="${HERDR_PANE_ID:-}"
workspace="${HERDR_WORKSPACE_ID:-}"
valid_pane "$parent_pane" || fail 'HERDR_PANE_ID must be a valid pane ID'
valid_workspace "$workspace" || fail 'HERDR_WORKSPACE_ID must be a valid workspace ID'
[ "${parent_pane%%:*}" = "$workspace" ] || fail 'HERDR_PANE_ID must belong to HERDR_WORKSPACE_ID'

target_workspace="${pane%%:*}"
[ "$pane" != "$parent_pane" ] || scope_reject self-pane
if [ "$target_workspace" != "$workspace" ]; then
  scope_require "$workspace" "$target_workspace"
fi

herdr agent start "$agent_name" --kind pi --pane "$pane" --timeout "$startup_timeout_ms" \
  -- --provider "$provider" --model "$model" --thinking "$thinking" >/dev/null ||
  fail "herdr agent start failed for $agent_name in $pane"

herdr agent wait "$pane" --until idle --until done --until blocked \
  --timeout "$startup_timeout_ms" >/dev/null ||
  fail "$agent_name in $pane did not become ready within ${startup_timeout_ms}ms"

herdr pane rename "$pane" "$agent_name" >/dev/null

exec "$parent_script" "$pane" "$(cat "$task_file")"
