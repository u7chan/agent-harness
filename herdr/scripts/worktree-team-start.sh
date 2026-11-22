#!/usr/bin/env bash
# Start a team member (Pi or Claude) in a Herdr worktree workspace pane and
# delegate the task file body to it in one command.
#
# Sequence: argument and task-file checks, scope check, optional profile
# resolution, the shared launcher (`start-agent.sh`: specification validation,
# Claude authentication and workspace-trust preflight, `herdr agent start`,
# bounded readiness wait, the harness-specific effective-value check, and the
# `launch:`/`effective:` lines), pane rename, then the task body through the
# existing parent-delegate-async.sh wrapper (which appends the direct-parent
# return instruction and performs the same scope check again).
#
# The agent specification comes from one of two modes:
#   explicit  `--harness` selects pi (default) or claude, and that harness's own
#             flags are passed as given. The mode never reads a profile, so it
#             stays the one-off path for a role that a profile does not carry.
#   profile   `--role` names a profile role and team-record.sh resolves its
#             canonical `<harness>:<...>` specification. A missing, invalid, or
#             unresolved role stops the start (fail closed).
#
# Both modes hand the specification to the shared launcher, which owns the
# grammar, the launch arguments, the stop conditions, and the effective-value
# check. This script appends only what the launcher reported: its `launch:` and
# `effective:` lines.
#
# The worktree workspace and its pane must already exist; this script never
# creates, shares, or removes workspaces, worktrees, tabs, or panes.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scope.sh
source "$script_dir/lib/scope.sh"
# shellcheck source=lib/record.sh
source "$script_dir/lib/record.sh"
parent_script="$script_dir/parent-delegate-async.sh"
# Resolved from this script, never from the caller's cwd: both the shared
# launcher and profile mode must be found even when this script is invoked from
# the worktree.
start_agent="$script_dir/start-agent.sh"
team_record="$script_dir/../../scripts/pi-development/team-record.sh"

# Bounded readiness wait, in milliseconds, for both `agent start` and
# `agent wait`. A started agent that is not interactive within this window
# fails the command instead of blocking forever.
startup_timeout_ms=60000

usage() {
  printf 'Usage: %s <pane-id> <agent-name> [--harness pi] --provider <provider> --model <model> --thinking <level> <task-file>\n' "$0" >&2
  printf '       %s <pane-id> <agent-name> --harness claude --model <model> --effort <level> --permission-mode <mode> <task-file>\n' "$0" >&2
  printf '       %s <pane-id> <agent-name> --role <profile-role> [--profile <name>] [--resolver <path>] <task-file>\n' "$0" >&2
  printf '\nThe explicit mode passes the harness flags as given and never reads a profile.\n' >&2
  printf 'The profile mode resolves <profile-role> from\n' >&2
  printf '${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-development/profiles.\n' >&2
  printf '  --harness <harness>    pi (default) or claude; the harness decides which\n' >&2
  printf '                         explicit flags are accepted and which <level> values exist\n' >&2
  printf '  --provider/--model/--thinking           Pi explicit mode (all three)\n' >&2
  printf '  --model/--effort/--permission-mode      Claude explicit mode (all three)\n' >&2
  printf '  --role <profile-role>  role to resolve (the documented orchestrator start is --role orchestrator)\n' >&2
  printf '  --profile <name>       profile to read; the default is active, then default\n' >&2
  printf '  --resolver <path>      model-spec resolver passed through unchanged; pass an absolute path\n' >&2
  printf '                         (advanced use and tests only)\n' >&2
  printf 'An empty option value is a usage error, never "not specified".\n' >&2
  printf '\n<profile-role> is a profile role, not the `role: orchestrator` label of the task text.\n' >&2
  printf 'A profile role resolves to `pi:<provider>/<model>/<thinking>` or\n' >&2
  printf '`claude:<model>/<effort>/<permission_mode>`, and the shared launcher starts it.\n' >&2
  printf 'Both modes print these lines, and append them to the delegated body; write\n' >&2
  printf 'neither yourself:\n' >&2
  printf '  launch: profile=<name|-> role=<profile-role|-> harness=<pi|claude> spec=<harness>:<...> spec_source=<profile|explicit> origin=<explicit|active|default>\n' >&2
  printf '  effective: harness=<pi|claude> provider=<provider|-> model=<canonical model> effort=<level|-> thinking=<level|-> permission_requested=<mode|-> requested=<spec>\n' >&2
  printf 'The effective line is verified and printed by the launcher for both harnesses.\n' >&2
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

[ "$#" -ge 2 ] || usage
pane="$1"
agent_name="$2"
shift 2

harness=''
provider=''
model=''
thinking=''
effort=''
permission_mode=''
role=''
profile=''
resolver=''
task_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    # An explicitly empty value is an argument error, not an omitted option:
    # `--profile ""` must never fall back to `active`, and `--role ""` must
    # never turn a profile call into the explicit mode. Rejecting it here is
    # before mode selection, the resolver, and any herdr write.
    --harness) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; harness="$2"; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; provider="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; model="$2"; shift 2 ;;
    --thinking) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; thinking="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; effort="$2"; shift 2 ;;
    --permission-mode) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; permission_mode="$2"; shift 2 ;;
    --role) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; role="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; profile="$2"; shift 2 ;;
    --resolver) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; resolver="$2"; shift 2 ;;
    --) shift; [ "$#" -ge 1 ] || usage; [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
    -*) usage ;;
    *) [ -z "$task_file" ] || usage; task_file="$1"; shift ;;
  esac
done

[ -z "$harness" ] || case "$harness" in
  pi | claude) ;;
  *) usage ;;
esac

# Mode selection is fail closed: a caller either names a profile role or
# supplies the selected harness's own complete explicit mode, never a mix and
# never neither. The harness decides which flags exist, so a flag of the other
# harness and a partial explicit mode are usage errors before anything runs.
pi_flags=0
claude_flags=0
[ -z "$provider" ] || pi_flags=$((pi_flags + 1))
[ -z "$thinking" ] || pi_flags=$((pi_flags + 1))
[ -z "$effort" ] || claude_flags=$((claude_flags + 1))
[ -z "$permission_mode" ] || claude_flags=$((claude_flags + 1))

mode=''
if [ -n "$role" ]; then
  [ -z "$harness" ] || usage
  [ "$pi_flags" -eq 0 ] && [ "$claude_flags" -eq 0 ] && [ -z "$model" ] || usage
  mode='profile'
else
  [ -z "$profile" ] && [ -z "$resolver" ] || usage
  harness="${harness:-pi}"
  if [ "$harness" = claude ]; then
    [ "$pi_flags" -eq 0 ] || usage
    [ "$claude_flags" -eq 2 ] || usage
  else
    [ "$claude_flags" -eq 0 ] || usage
    [ "$pi_flags" -eq 2 ] || usage
  fi
  [ -n "$model" ] || usage
  mode='explicit'
fi

[ -n "$task_file" ] || usage
valid_pane "$pane" || fail 'pane must be a pane ID'
[[ "$agent_name" =~ ^[[:alnum:]_.-]+$ ]] || fail 'agent name must match [A-Za-z0-9_.-]+'
[ -f "$task_file" ] || fail 'task file does not exist'
[ -r "$task_file" ] || fail 'task file is not readable'
[ -s "$task_file" ] || fail 'task file is empty'

[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'
[ -x "$parent_script" ] || fail 'parent-delegate-async.sh is required'
[ -x "$start_agent" ] || fail 'start-agent.sh is required'

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
spec=''
if [ "$mode" = 'profile' ]; then
  # Resolved after the scope check: a rejected edge stays exit code 3 and is
  # never reported as a profile error. The tool checks are profile-only, so the
  # explicit mode keeps its existing prerequisites.
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
  # The value is the canonical `<harness>:<...>` specification. Its grammar,
  # its harness prefix, and its start arguments belong to the shared launcher,
  # so this script passes it through without splitting it again.
  spec="$(record_field "$record" "$role")" || fail "team-record.sh reported no '$role' spec: $record"
  [ -n "$spec" ] || fail "team-record.sh reported an empty '$role' spec"
  [[ "$launch_profile" =~ ^[[:alnum:]_.-]+$ ]] || fail 'team-record.sh reported an unusable profile name'
  case "$launch_origin" in
    explicit | active | default) ;;
    *) fail 'team-record.sh reported an unusable source' ;;
  esac

  launch_role="$role"
  launch_spec_source='profile'
fi

start_args=("$pane" "$agent_name")
if [ "$mode" = 'profile' ]; then
  start_args+=(--spec "$spec")
else
  start_args+=(--harness "$harness")
  if [ "$harness" = claude ]; then
    start_args+=(--model "$model" --effort "$effort" --permission-mode "$permission_mode")
  else
    start_args+=(--provider "$provider" --model "$model" --thinking "$thinking")
  fi
fi
start_args+=(--profile "$launch_profile" --role "$launch_role"
  --spec-source "$launch_spec_source" --origin "$launch_origin"
  --timeout "$startup_timeout_ms")

agent_records=''
agent_status=0
agent_records="$("$start_agent" "${start_args[@]}" 2>&1 >/dev/null)" || agent_status=$?
if [ -n "$agent_records" ]; then
  printf '%s\n' "$agent_records" >&2
fi
# The launcher's own status is preserved: a usage error stays 2, and every
# launch or verification failure stays 1. Nothing is renamed or delegated when
# it fails, and the started pane is left in place.
[ "$agent_status" -eq 0 ] || exit "$agent_status"

launch_line="$(printf '%s\n' "$agent_records" | grep '^launch: ' | tail -n 1)" || launch_line=''
[ -n "$launch_line" ] || fail 'the shared launcher reported no launch: line'
# The last effective line is authoritative; the launcher prints one for both
# harnesses after it verifies the launched values.
effective_line="$(printf '%s\n' "$agent_records" | grep '^effective: ' | tail -n 1)" || effective_line=''
delegated_records="$launch_line"
if [ -n "$effective_line" ]; then
  delegated_records="${delegated_records}"$'\n'"${effective_line}"
fi

herdr pane rename "$pane" "$agent_name" >/dev/null ||
  fail "herdr pane rename failed for $pane"

body="$(cat "$task_file")"
# Appended for the wrapper to deliver before its own return instruction; the
# wrapper's contract is unchanged.
exec "$parent_script" "$pane" "${body}"$'\n\n'"${delegated_records}"
