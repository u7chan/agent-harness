#!/usr/bin/env bash
# Start a Pi team member in a Herdr worktree workspace pane and delegate the
# task file body to it in one command.
#
# Sequence: argument and task-file checks, scope check, optional profile
# resolution, `herdr agent start` with flags only, bounded readiness wait, pane
# rename, then the task body through the existing parent-delegate-async.sh
# wrapper (which appends the direct-parent return instruction and performs the
# same scope check again).
#
# The three agent flags come from one of two modes:
#   explicit  --provider/--model/--thinking are passed as given. The mode never
#             reads a profile, so it stays the one-off path for a role that a
#             profile does not carry yet.
#   profile   --role names a profile role and team-record.sh resolves its
#             provider/model/thinking. A missing, invalid, or unresolved role
#             stops the start (fail closed).
# Both modes print one `launch:` line to stderr and append the same line to the
# delegated body, before the return instruction.
#
# The worktree workspace and its pane must already exist; this script never
# creates, shares, or removes workspaces, worktrees, tabs, or panes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scope.sh
source "$script_dir/lib/scope.sh"
parent_script="$script_dir/parent-delegate-async.sh"
# Resolved from this script, never from the caller's cwd: profile mode must
# find the shared helper even when it is invoked from the worktree.
team_record="$script_dir/../../scripts/pi-development/team-record.sh"

# Bounded readiness wait, in milliseconds, for both `agent start` and
# `agent wait`. A started agent that is not interactive within this window
# fails the command instead of blocking forever.
startup_timeout_ms=60000

usage() {
  printf 'Usage: %s <pane-id> <agent-name> --provider <provider> --model <model> --thinking <level> <task-file>\n' "$0" >&2
  printf '       %s <pane-id> <agent-name> --role <profile-role> [--profile <name>] [--resolver <path>] <task-file>\n' "$0" >&2
  printf '\nThe explicit mode passes the three agent flags as given and never reads a profile.\n' >&2
  printf 'The profile mode resolves <profile-role> from\n' >&2
  printf '${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-development/profiles.\n' >&2
  printf '  --role <profile-role>  role to resolve (the documented orchestrator start is --role orchestrator)\n' >&2
  printf '  --profile <name>       profile to read; the default is active, then default\n' >&2
  printf '  --resolver <path>      model-spec resolver passed through unchanged; pass an absolute path\n' >&2
  printf '                         (advanced use and tests only)\n' >&2
  printf '\n<profile-role> is a profile role, not the `role: orchestrator` label of the task text.\n' >&2
  printf 'Both modes print and append this line; write it nowhere yourself:\n' >&2
  printf '  launch: profile=<name|-> role=<profile-role|-> spec=<provider>/<model>/<thinking> spec_source=<profile|explicit> origin=<explicit|active|default>\n' >&2
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

valid_thinking() {
  case "$1" in
    off|minimal|low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

# One `key=value` field of a team-record line. The helper keeps values free of
# whitespace, and the line is split without globbing, so a value is never
# expanded into filenames. A missing key returns nonzero.
record_field() { # line key
  local rest="$1" key="$2" token
  while [ -n "$rest" ]; do
    token="${rest%% *}"
    case "$token" in
      "$key"=*) printf '%s' "${token#*=}"; return 0 ;;
    esac
    case "$rest" in
      *' '*) rest="${rest#* }" ;;
      *) rest='' ;;
    esac
  done
  return 1
}

[ "$#" -ge 2 ] || usage
pane="$1"
agent_name="$2"
shift 2

provider=''
model=''
thinking=''
role=''
profile=''
resolver=''
task_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || usage; provider="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || usage; model="$2"; shift 2 ;;
    --thinking) [ "$#" -ge 2 ] || usage; thinking="$2"; shift 2 ;;
    --role) [ "$#" -ge 2 ] || usage; role="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --resolver) [ "$#" -ge 2 ] || usage; resolver="$2"; shift 2 ;;
    --) shift; [ "$#" -ge 1 ] || usage; [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
    -*) usage ;;
    *) [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
  esac
done

# Mode selection is fail closed: a caller either supplies all three explicit
# values or names a profile role, never a mix and never neither. The
# all-or-none check it replaces used to run before the scope check; profile
# mode has no explicit values, so the mode is decided here instead.
explicit_count=0
if [ -n "$provider" ]; then explicit_count=$((explicit_count + 1)); fi
if [ -n "$model" ]; then explicit_count=$((explicit_count + 1)); fi
if [ -n "$thinking" ]; then explicit_count=$((explicit_count + 1)); fi

mode=''
if [ -n "$role" ]; then
  [ "$explicit_count" -eq 0 ] || usage
  mode='profile'
else
  [ -z "$profile" ] && [ -z "$resolver" ] || usage
  [ "$explicit_count" -eq 3 ] || usage
  mode='explicit'
fi

[ -n "$task_file" ] || usage
valid_pane "$pane" || fail 'pane must be a pane ID'
[[ "$agent_name" =~ ^[[:alnum:]_.-]+$ ]] || fail 'agent name must match [A-Za-z0-9_.-]+'
if [ "$mode" = 'explicit' ]; then
  valid_flag_value "$provider" || fail 'provider must be a single-line token'
  valid_flag_value "$model" || fail 'model must be a single-line token'
  valid_thinking "$thinking" || fail 'thinking must be one of off, minimal, low, medium, high, xhigh, max'
fi
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

launch_profile='-'
launch_role='-'
launch_spec_source='explicit'
launch_origin='explicit'
if [ "$mode" = 'profile' ]; then
  # Resolved after the scope check: a rejected edge stays exit code 3 and is
  # never reported as a profile error. The tool checks are profile-only, so the
  # explicit mode keeps its existing prerequisites.
  command -v node >/dev/null 2>&1 || fail 'node is required for --role profile mode'
  [ -x "$team_record" ] || fail 'team-record.sh is required for --role profile mode'

  record_args=(resolve --only-role "$role")
  [ -z "$profile" ] || record_args+=(--profile "$profile")
  [ -z "$resolver" ] || record_args+=(--resolver "$resolver")

  record=''
  record_status=0
  record="$("$team_record" "${record_args[@]}")" || record_status=$?
  if [ "$record_status" -eq 2 ]; then
    # `--role` is not a profile role (or the profile name is invalid): the
    # helper's usage status is this script's usage status.
    printf 'ERROR: %s\n' "${record:-team-record.sh rejected the profile arguments}" >&2
    usage
  fi
  [ "$record_status" -eq 0 ] || fail "profile resolution failed: ${record:-team-record.sh produced no record}"

  record_result="$(record_field "$record" result)" || fail "team-record.sh reported no result: $record"
  [ "$record_result" = ok ] || fail "profile resolution did not succeed: $record"
  launch_profile="$(record_field "$record" profile)" || fail "team-record.sh reported no profile: $record"
  launch_origin="$(record_field "$record" source)" || fail "team-record.sh reported no source: $record"
  spec="$(record_field "$record" "$role")" || fail "team-record.sh reported no '$role' spec: $record"

  # Same split rule as parseRoleSpec: the provider is the first segment, the
  # thinking level the last one, and the rest is the model, so a model ID may
  # contain `/`.
  case "$spec" in
    */*/*) ;;
    *) fail "team-record.sh reported an unusable '$role' spec: $spec" ;;
  esac
  provider="${spec%%/*}"
  remainder="${spec#*/}"
  thinking="${remainder##*/}"
  model="${remainder%/*}"
  if [ -z "$provider" ] || [ -z "$model" ] || [ -z "$thinking" ]; then
    fail "team-record.sh reported an unusable '$role' spec: $spec"
  fi
  valid_flag_value "$provider" || fail 'the resolved provider must be a single-line token'
  valid_flag_value "$model" || fail 'the resolved model must be a single-line token'
  valid_thinking "$thinking" || fail 'the resolved thinking must be one of off, minimal, low, medium, high, xhigh, max'
  [[ "$launch_profile" =~ ^[[:alnum:]_.-]+$ ]] || fail 'team-record.sh reported an unusable profile name'
  case "$launch_origin" in
    explicit|active|default) ;;
    *) fail 'team-record.sh reported an unusable source' ;;
  esac

  launch_role="$role"
  launch_spec_source='profile'
fi

launch_line="launch: profile=${launch_profile} role=${launch_role} spec=${provider}/${model}/${thinking} spec_source=${launch_spec_source} origin=${launch_origin}"
printf '%s\n' "$launch_line" >&2

herdr agent start "$agent_name" --kind pi --pane "$pane" --timeout "$startup_timeout_ms" \
  -- --provider "$provider" --model "$model" --thinking "$thinking" >/dev/null ||
  fail "herdr agent start failed for $agent_name in $pane"

herdr agent wait "$pane" --until idle --until done --until blocked \
  --timeout "$startup_timeout_ms" >/dev/null ||
  fail "$agent_name in $pane did not become ready within ${startup_timeout_ms}ms"

herdr pane rename "$pane" "$agent_name" >/dev/null

body="$(cat "$task_file")"
# Appended for the wrapper to deliver before its own return instruction; the
# wrapper's contract is unchanged.
exec "$parent_script" "$pane" "${body}"$'\n\n'"${launch_line}"
