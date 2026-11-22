#!/usr/bin/env bash
# Start one role agent (Pi or Claude) in an existing Herdr pane and confirm the
# specification it actually runs with.
#
# One start owns the whole sequence: argument, harness, specification,
# permission, and timeout validation, the Claude authentication and
# workspace-trust preflight, the per-pane Claude settings file and statusline
# probe, `herdr agent start`, the bounded readiness wait, the harness-specific
# effective-value check, and the `launch:`/`effective:` lines. Callers keep
# everything around the start: the shared launcher never renames the pane,
# never prompts the agent with the delegated task, never performs a scope
# check, and never creates, splits, or removes a pane or a workspace. Pi gets
# one startup probe because its session record appears only on the first turn.
#
# The specification is either one canonical role string (as `team-record.sh`
# prints it) or the harness's own flags:
#
#   pi      --provider <provider> --model <model> --thinking <level>
#   claude  --model <model> --effort <level> --permission-mode <mode>
#
# Both forms are parsed by the shared grammar in `scripts/pi-development/lib/team-record.mjs`
# through `lib/role-spec.mjs`, so the launcher never restates the split rules or
# the vocabularies. `--harness` must match the prefix of `--spec`; an explicit
# start without `--harness` is Pi.
#
# Verification is harness-specific. Pi's model and thinking level are read from
# the session record Herdr reports (`agent_session` with `kind=path`): the first
# `model_change` and `thinking_level_change` entries are the launch values, and
# a missing record or a mismatch stops the launch. `$PI_*` is never used.
# Claude exposes its model and effort only in the running session, so the
# launcher installs a statusline command that writes `.model.id` and
# `.effort.level` to a per-launch probe file, waits for a bounded time for a
# write carrying the launch's own nonce, and only then prints `effective:`.
#
# Output, all on stderr, in order: `probe: <path>` (Claude only, before the
# start), the `launch:` line (before `herdr agent start`), and, after a
# successful effective-value check, the `effective:` line. A failed launch is
# left in place: the caller decides whether to reuse or close the pane.
#
# Exit status: 0 started and verified; 1 validation, launch, or verification
# failure; 2 usage.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/record.sh
source "$script_dir/lib/record.sh"
role_spec_helper="$script_dir/lib/role-spec.mjs"
statusline_probe="$script_dir/claude-statusline-probe.sh"
# Resolved from this script, never from the caller's cwd: the Claude preflight
# must find the shared helper even when the launcher is invoked from a pane.
claude_auth="$script_dir/../../scripts/pi-development/claude-auth-status.sh"

default_timeout_ms=60000
default_probe_timeout_ms=10000
# `herdr agent start` refuses a longer bounded wait.
max_timeout_ms=300000

usage() {
  printf 'Usage: %s <pane-id> <agent-name> --spec <spec> [options]\n' "$0" >&2
  printf '       %s <pane-id> <agent-name> --harness pi --provider <provider> --model <model> --thinking <level> [options]\n' "$0" >&2
  printf '       %s <pane-id> <agent-name> --harness claude --model <model> --effort <level> --permission-mode <mode> [options]\n' "$0" >&2
  printf '\nStarts one role agent in an existing Herdr pane.\n' >&2
  printf '  --spec <spec>          `pi:<provider>/<model>/<thinking>` or\n' >&2
  printf '                         `claude:<model>/<effort>/<permission_mode>`; a value\n' >&2
  printf '                         without a harness prefix is read as Pi. Never combined\n' >&2
  printf '                         with the harness-specific flags.\n' >&2
  printf '  --harness <harness>    pi or claude. It must match the prefix of --spec; with\n' >&2
  printf '                         --spec and no --harness the harness comes from the\n' >&2
  printf '                         specification, and an explicit start defaults to pi.\n' >&2
  printf '  --provider/--model/--thinking           Pi explicit mode (all three)\n' >&2
  printf '  --model/--effort/--permission-mode      Claude explicit mode (all three)\n' >&2
  printf '  --profile <name>       profile named in the launch line (default -)\n' >&2
  printf '  --role <role>          profile role named in the launch line (default -)\n' >&2
  printf '  --spec-source <source> profile or explicit (default explicit)\n' >&2
  printf '  --origin <origin>      explicit, active, or default (default explicit)\n' >&2
  printf '  --timeout <ms>         bounded start and readiness wait (default %s)\n' "$default_timeout_ms" >&2
  printf '  --probe-timeout <ms>   bounded effective-value wait (default %s)\n' "$default_probe_timeout_ms" >&2
  printf '\nA flag of the other harness, a mixed or partial explicit mode, and an empty\n' >&2
  printf 'option value are usage errors, and nothing is started.\n' >&2
  printf 'This script prints `probe:`, `launch:`, and `effective:` lines to stderr;\n' >&2
  printf 'the caller appends the launch line and the effective line.\n' >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_pane() {
  [[ "$1" =~ ^[[:alnum:]_.-]+:[[:alnum:]_.-]+$ ]]
}

# Single-line tokens passed as agent start arguments. The value becomes one
# discrete argument, but agent start encodes it for the target shell, so reject
# anything outside an unreserved token shape before starting anything.
valid_flag_value() {
  [[ "$1" =~ ^[[:alnum:]_.:@+~/-]+$ ]]
}

valid_timeout() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  # A leading zero would otherwise be read as octal by the arithmetic below.
  [ "${#1}" -le 9 ] || return 1
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le "$max_timeout_ms" ]
}

# Quote tokens for the statusline command, which Claude runs through a shell.
# A value this cannot quote safely is reported instead of escaped by guesswork.
shell_quote() {
  local value out=''
  for value in "$@"; do
    case "$value" in
      *\'*) return 1 ;;
    esac
    out="${out}${out:+ }'${value}'"
  done
  printf '%s' "$out"
}

now_ms() {
  date +%s%3N
}

[ "$#" -ge 2 ] || usage
pane="$1"
agent_name="$2"
shift 2

spec=''
harness=''
harness_given=0
provider=''
model=''
thinking=''
effort=''
permission_mode=''
launch_profile='-'
launch_role='-'
spec_source='explicit'
origin='explicit'
timeout="$default_timeout_ms"
probe_timeout="$default_probe_timeout_ms"

while [ "$#" -gt 0 ]; do
  case "$1" in
    # An explicitly empty value is an argument error, not an omitted option:
    # `--spec ""` must never fall through to the explicit mode.
    --spec) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; spec="$2"; shift 2 ;;
    --harness) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; harness="$2"; harness_given=1; shift 2 ;;
    --provider) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; provider="$2"; shift 2 ;;
    --model) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; model="$2"; shift 2 ;;
    --thinking) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; thinking="$2"; shift 2 ;;
    --effort) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; effort="$2"; shift 2 ;;
    --permission-mode) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; permission_mode="$2"; shift 2 ;;
    --profile) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; launch_profile="$2"; shift 2 ;;
    --role) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; launch_role="$2"; shift 2 ;;
    --spec-source) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; spec_source="$2"; shift 2 ;;
    --origin) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; origin="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; timeout="$2"; shift 2 ;;
    --probe-timeout) [ "$#" -ge 2 ] || usage; [ -n "$2" ] || usage; probe_timeout="$2"; shift 2 ;;
    *) usage ;;
  esac
done

# Mode selection is fail closed. The harness owns which flags exist, so a flag
# of the other harness, a partial explicit mode, and a specification mixed with
# any harness flag are usage errors before any lookup or write.
if [ "$harness_given" -eq 1 ]; then
  case "$harness" in
    pi | claude) ;;
    *) usage ;;
  esac
fi
pi_flags=0
claude_flags=0
[ -z "$provider" ] || pi_flags=$((pi_flags + 1))
[ -z "$thinking" ] || pi_flags=$((pi_flags + 1))
[ -z "$effort" ] || claude_flags=$((claude_flags + 1))
[ -z "$permission_mode" ] || claude_flags=$((claude_flags + 1))

if [ -n "$spec" ]; then
  [ "$pi_flags" -eq 0 ] && [ "$claude_flags" -eq 0 ] || usage
  [ -z "$model" ] || usage
else
  if [ "$harness_given" -eq 0 ]; then
    harness='pi'
  fi
  if [ "$harness" = claude ]; then
    [ "$pi_flags" -eq 0 ] || usage
    [ "$claude_flags" -eq 2 ] || usage
  else
    [ "$claude_flags" -eq 0 ] || usage
    [ "$pi_flags" -eq 2 ] || usage
  fi
  [ -n "$model" ] || usage
fi

[ -n "$spec" ] || {
  if [ "${harness:-pi}" = claude ]; then
    spec="claude:${model}/${effort}/${permission_mode}"
  else
    spec="pi:${provider}/${model}/${thinking}"
  fi
}

# Value errors are not usage errors: the shape of the call was valid, but the
# value it carries cannot be launched.
valid_pane "$pane" || fail 'pane must be a pane ID'
[[ "$agent_name" =~ ^[[:alnum:]_.-]+$ ]] || fail 'agent name must match [A-Za-z0-9_.-]+'
[[ "$launch_profile" =~ ^[[:alnum:]_.-]+$ ]] || fail 'profile must match [A-Za-z0-9_.-]+'
[[ "$launch_role" =~ ^[[:alnum:]_.-]+$ ]] || fail 'role must match [A-Za-z0-9_.-]+'
case "$spec_source" in
  profile | explicit) ;;
  *) fail 'spec source must be profile or explicit' ;;
esac
case "$origin" in
  explicit | active | default) ;;
  *) fail 'origin must be explicit, active, or default' ;;
esac
valid_timeout "$timeout" || fail "timeout must be a whole number of milliseconds in 1..$max_timeout_ms"
valid_timeout "$probe_timeout" || fail "probe timeout must be a whole number of milliseconds in 1..$max_timeout_ms"
timeout="$((10#$timeout))"
probe_timeout="$((10#$probe_timeout))"

[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required to read Herdr and Claude state'
command -v node >/dev/null 2>&1 || fail 'node is required to parse a role specification'
[ -r "$role_spec_helper" ] || fail 'lib/role-spec.mjs is required'

parsed=''
parsed="$(node "$role_spec_helper" "$spec" 2>/dev/null)" ||
  fail "not a usable role specification: ${spec}"

parsed_harness="$(jq -r '.harness // ""' <<< "$parsed")"
[ -n "$parsed_harness" ] || fail "not a usable role specification: ${spec}"
# The printed harness must be the prefix of the printed specification: the
# launch line states both, and a mismatch would describe an agent that cannot
# be verified.
spec="$(jq -r '.spec // ""' <<< "$parsed")"
case "$spec" in
  "$parsed_harness":*) ;;
  *) fail "the specification prefix and its harness disagree: ${spec}" ;;
esac
if [ "$harness_given" -eq 1 ] && [ "$harness" != "$parsed_harness" ]; then
  fail "harness=${harness} does not match the specification prefix: ${spec}"
fi
harness="$parsed_harness"

if [ "$harness" = claude ]; then
  model="$(jq -r '.model // ""' <<< "$parsed")"
  effort="$(jq -r '.effort // ""' <<< "$parsed")"
  permission_mode="$(jq -r '.permission_mode // ""' <<< "$parsed")"
  valid_flag_value "$model" || fail 'model must be a single-line token'
  valid_flag_value "$effort" || fail 'effort must be a single-line token'
  valid_flag_value "$permission_mode" || fail 'permission mode must be a single-line token'
else
  provider="$(jq -r '.provider // ""' <<< "$parsed")"
  model="$(jq -r '.model // ""' <<< "$parsed")"
  thinking="$(jq -r '.thinking // ""' <<< "$parsed")"
  valid_flag_value "$provider" || fail 'provider must be a single-line token'
  valid_flag_value "$model" || fail 'model must be a single-line token'
  valid_flag_value "$thinking" || fail 'thinking must be a single-line token'
fi

launch_line="launch: profile=${launch_profile} role=${launch_role} harness=${harness} spec=${spec} spec_source=${spec_source} origin=${origin}"

probe_file=''
settings_file=''
nonce=''
if [ "$harness" = claude ]; then
  # Authentication and config-directory preflight. The helper prints only the
  # login state and the config directory; a failure stops before any lookup
  # that could start something.
  command -v claude >/dev/null 2>&1 || fail 'claude is required for a Claude start'
  [ -x "$claude_auth" ] || fail 'scripts/pi-development/claude-auth-status.sh is required for a Claude start'
  auth_record=''
  auth_record="$("$claude_auth")" || auth_rc=$?
  [ "${auth_rc:-0}" -eq 0 ] || fail "Claude is not ready to start: ${auth_record:-claude-auth-status.sh printed no record}"
  auth_result="$(record_field "$auth_record" result)" || auth_result=''
  [ "$auth_result" = ok ] || fail "Claude is not ready to start: ${auth_record}"
  auth_config_dir="$(record_field "$auth_record" configDirectory)" || auth_config_dir=''
  case "${CLAUDE_CONFIG_DIR:-}" in
    '') config_dir="$auth_config_dir" ;;
    /*) config_dir="$CLAUDE_CONFIG_DIR" ;;
    *) fail "CLAUDE_CONFIG_DIR must be an absolute path: ${CLAUDE_CONFIG_DIR}" ;;
  esac
  case "$config_dir" in
    /*) ;;
    *) fail "the Claude config directory must be an absolute path: ${config_dir:-<none>}" ;;
  esac
  case "$config_dir" in
    *[[:space:][:cntrl:]]*) fail "the Claude config directory contains an unusable character: ${config_dir}" ;;
  esac
  valid_flag_value "$config_dir" || fail "the Claude config directory must be a single-line token: ${config_dir}"

  # Trust is read-only and fail closed: the launcher never writes the trust
  # file and never passes --dangerously-skip-permissions, so an untrusted
  # workspace stops here even when the CLI would otherwise prompt.
  pane_json=''
  pane_json="$(herdr pane get "$pane" 2>/dev/null)" || fail "cannot inspect pane ${pane}"
  # `foreground_cwd` is the directory the pane's foreground process runs in, so
  # a shell sitting in another directory is not mistaken for the agent's
  # workspace. An absent or empty value falls back to `cwd`.
  pane_cwd="$(jq -r '.result.pane | (.foreground_cwd // "") as $foreground
    | if $foreground == "" then (.cwd // "") else $foreground end' \
    <<< "$pane_json" 2>/dev/null)" || pane_cwd=''
  [ -n "$pane_cwd" ] || fail "pane ${pane} reported no working directory"
  real_cwd="$(realpath -m -- "$pane_cwd" 2>/dev/null)" || real_cwd=''
  case "$real_cwd" in
    /*) ;;
    *) fail "cannot normalize the working directory of pane ${pane}: ${pane_cwd}" ;;
  esac
  # The state file is `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`, not
  # `<config-dir>/.claude.json` in the default case: measured on 2.1.328, a
  # fresh `CLAUDE_CONFIG_DIR` gets `<dir>/.claude.json`, while the default
  # config directory Claude reports is `<home>/.claude` and the state file stays
  # at `<home>/.claude.json`. The reported directory holds settings and skills,
  # so the trust file sits one level above it only when the variable is unset.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    trust_file="$CLAUDE_CONFIG_DIR/.claude.json"
  else
    trust_file="$(dirname -- "$config_dir")/.claude.json"
  fi
  # A missing file, invalid JSON, a missing project key, and `false` are all
  # unapproved: only an explicit `true` approves the directory.
  if ! jq -e --arg dir "$real_cwd" \
    '(.projects // {}) | has($dir) and (.[$dir].hasTrustDialogAccepted == true)' \
    "$trust_file" >/dev/null 2>&1; then
    printf 'claude-trust: %s が未承認です。そのディレクトリで claude を一度起動し、trust を承認してから再実行してください。\n' "$real_cwd" >&2
    exit 1
  fi

  # A per-pane settings file replaces the statusline for this delegated pane
  # only, and the probe file starts empty so a leftover record from an earlier
  # session in the same pane can never be read as this launch's values.
  probe_dir="${TMPDIR:-/tmp}/agent-harness/claude-spec"
  mkdir -p -- "$probe_dir" || fail "cannot create the probe directory: ${probe_dir}"
  chmod 700 -- "$probe_dir" || fail "cannot restrict the probe directory: ${probe_dir}"
  safe_pane="${pane//[^[:alnum:]_.-]/_}"
  probe_file="$probe_dir/${safe_pane}.json"
  settings_file="$probe_dir/${safe_pane}.settings.json"
  valid_flag_value "$probe_file" || fail "the probe file must be a single-line token: ${probe_file}"
  valid_flag_value "$settings_file" || fail "the settings file must be a single-line token: ${settings_file}"
  [ -x "$statusline_probe" ] || fail 'claude-statusline-probe.sh is required for a Claude start'
  rm -f -- "$probe_file" || fail "cannot remove the previous probe file: ${probe_file}"
  nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || fail 'cannot generate a launch nonce'
  status_command="$(shell_quote "$statusline_probe" "$probe_file" "$nonce")" ||
    fail 'the probe path cannot be quoted for the statusline command'
  settings_temporary="${settings_file}.$$.tmp"
  if ! jq -n --arg command "$status_command" \
    '{statusLine: {type: "command", command: $command, refreshInterval: 1}}' \
    > "$settings_temporary"; then
    rm -f -- "$settings_temporary"
    fail "cannot write the Claude settings file: ${settings_file}"
  fi
  if ! chmod 600 -- "$settings_temporary"; then
    rm -f -- "$settings_temporary"
    fail "cannot restrict the Claude settings file: ${settings_file}"
  fi
  mv -f -- "$settings_temporary" "$settings_file" ||
    fail "cannot write the Claude settings file: ${settings_file}"
  printf 'probe: %s\n' "$probe_file" >&2
fi

printf '%s\n' "$launch_line" >&2

if [ "$harness" = claude ]; then
  herdr agent start "$agent_name" --kind claude --pane "$pane" --timeout "$timeout" \
    -- --model "$model" --effort "$effort" --permission-mode "$permission_mode" \
    --settings "$settings_file" >/dev/null ||
    fail "herdr agent start failed for ${agent_name} in ${pane}"
else
  herdr agent start "$agent_name" --kind pi --pane "$pane" --timeout "$timeout" \
    -- --provider "$provider" --model "$model" --thinking "$thinking" >/dev/null ||
    fail "herdr agent start failed for ${agent_name} in ${pane}"
fi

wait_output=''
wait_output="$(herdr agent wait "$pane" --until idle --until done --until blocked \
  --timeout "$timeout" 2>/dev/null)" ||
  fail "${agent_name} in ${pane} did not become ready within ${timeout}ms"
# `blocked` is a ready-looking state that must not receive work: the pane is
# left in place for a human to resolve the prompt.
if grep -Eq '"agent_status"[[:space:]]*:[[:space:]]*"blocked"' <<< "$wait_output"; then
  fail "${agent_name} in ${pane} is blocked; resolve the prompt in the pane before starting it again"
fi

if [ "$harness" = pi ]; then
  # Herdr reports the session record the launched Pi agent writes. Only a
  # `kind=path` value is usable; an absent record, another kind, or a record
  # that never carries the launch values stops instead of guessing from
  # `$PI_*` or the pane footer. One deadline covers the path lookup, the probe,
  # and the record read so a slow path cannot grant a second full wait.
  pi_started="$(now_ms)"
  session_path=''
  while :; do
    session_json=''
    session_json="$(herdr pane get "$pane" 2>/dev/null)" || session_json=''
    session_kind="$(jq -r '.result.pane.agent_session.kind // ""' <<< "$session_json" 2>/dev/null)" || session_kind=''
    session_candidate="$(jq -r '.result.pane.agent_session.value // ""' <<< "$session_json" 2>/dev/null)" || session_candidate=''
    if [ "$session_kind" = path ] && [ -n "$session_candidate" ]; then
      session_path="$session_candidate"
      break
    fi
    [ "$(( $(now_ms) - pi_started ))" -lt "$probe_timeout" ] || break
    sleep 0.2
  done
  case "$session_path" in
    /*) ;;
    *) fail "the Pi session did not report a usable agent_session path within ${probe_timeout}ms" ;;
  esac

  # Pi writes its session record on the first turn, not at startup. A minimal
  # startup probe makes the record appear without consuming the task body; the
  # probe's reply stays in the session and the caller's task follows it.
  if [ ! -s "$session_path" ]; then
    [ "$(( $(now_ms) - pi_started ))" -lt "$probe_timeout" ] ||
      fail "the Pi session record did not appear within ${probe_timeout}ms (session: ${session_path})"
    herdr agent prompt "$pane" \
      'Startup check from the shared launcher: reply with OK only and take no other action.' \
      >/dev/null 2>&1 ||
      fail "the Pi session could not be prompted to write its startup record"
  fi

  # Read the record line by line and stop as soon as the first model_change
  # and thinking_level_change are known. An unreadable or incomplete entry
  # before both are known is a failure, not a line to skip; a later value must
  # never stand in for a broken initial one.
  launched_provider=''
  launched_model=''
  launched_thinking=''
  record_error=''
  while :; do
    if [ -s "$session_path" ]; then
      record_error=''
      while IFS= read -r session_line; do
        [ -n "$session_line" ] || continue
        session_entry=''
        session_entry="$(jq -c . <<< "$session_line" 2>/dev/null)" || {
          record_error='unreadable entry'
          break
        }
        session_type="$(jq -r '.type // ""' <<< "$session_entry" 2>/dev/null)" || session_type=''
        case "$session_type" in
          model_change)
            if [ -z "$launched_provider" ] && [ -z "$launched_model" ]; then
              launched_provider="$(jq -r '.provider // ""' <<< "$session_entry" 2>/dev/null)" || launched_provider=''
              launched_model="$(jq -r '.modelId // ""' <<< "$session_entry" 2>/dev/null)" || launched_model=''
              if [ -z "$launched_provider" ] || [ -z "$launched_model" ]; then
                record_error='incomplete model_change'
                break
              fi
            fi
            ;;
          thinking_level_change)
            if [ -z "$launched_thinking" ]; then
              launched_thinking="$(jq -r '.thinkingLevel // ""' <<< "$session_entry" 2>/dev/null)" || launched_thinking=''
              if [ -z "$launched_thinking" ]; then
                record_error='incomplete thinking_level_change'
                break
              fi
            fi
            ;;
        esac
        if [ -n "$launched_provider" ] && [ -n "$launched_model" ] && [ -n "$launched_thinking" ]; then
          break
        fi
      done < "$session_path"
      if [ -n "$record_error" ]; then
        fail "the Pi session record is unreadable: ${record_error} (session: ${session_path})"
      fi
      if [ -n "$launched_provider" ] && [ -n "$launched_model" ] && [ -n "$launched_thinking" ]; then
        break
      fi
    fi
    [ "$(( $(now_ms) - pi_started ))" -lt "$probe_timeout" ] || break
    sleep 0.2
  done
  if [ -z "$launched_provider" ] || [ -z "$launched_model" ] || [ -z "$launched_thinking" ]; then
    fail "the Pi session record did not report model and thinking values within ${probe_timeout}ms (session: ${session_path})"
  fi
  if [ "$launched_provider" != "$provider" ] || [ "$launched_model" != "$model" ] || [ "$launched_thinking" != "$thinking" ]; then
    fail "the launched Pi session does not match the requested specification: launched=${launched_provider}/${launched_model}/${launched_thinking} requested=${spec}"
  fi
  printf 'effective: harness=pi provider=%s model=%s effort=- thinking=%s permission_requested=- requested=%s\n' \
    "$launched_provider" "$launched_model" "$launched_thinking" "$spec" >&2
fi

if [ "$harness" = claude ]; then
  probe_state='missing'
  probe_started="$(now_ms)"
  while :; do
    if [ -s "$probe_file" ]; then
      probe_state="$(jq -r --arg nonce "$nonce" \
        'if (.nonce // "") == $nonce then "ready" else "stale" end' \
        "$probe_file" 2>/dev/null)" || probe_state='missing'
    else
      probe_state='missing'
    fi
    [ "$probe_state" = ready ] && break
    [ "$(( $(now_ms) - probe_started ))" -lt "$probe_timeout" ] || break
    sleep 0.2
  done
  case "$probe_state" in
    ready) ;;
    stale)
      fail "the Claude statusline probe holds another launch's record (probe: ${probe_file})"
      ;;
    *)
      fail "the Claude statusline probe did not report ${pane} within ${probe_timeout}ms (probe: ${probe_file})"
      ;;
  esac

  launched_model="$(jq -r '.model // ""' "$probe_file" 2>/dev/null)" || launched_model=''
  launched_effort="$(jq -r '.effort // ""' "$probe_file" 2>/dev/null)" || launched_effort=''
  [ -n "$launched_effort" ] ||
    fail "the launched Claude session did not report an effort level (probe: ${probe_file})"
  [[ "$launched_model" =~ ^[[:alnum:]][[:alnum:]._:@+/-]*$ ]] ||
    fail "the launched Claude session reported no usable model (probe: ${probe_file})"
  # A stored canonical model ID is a promise the launched session must keep. An
  # explicit start may name an alias, so its reported canonical model is the
  # result instead of a mismatch.
  if [ "$spec_source" = profile ] && [ "$launched_model" != "$model" ]; then
    fail "the launched Claude model does not match the requested specification: launched=${launched_model} requested=${spec}"
  fi
  if [ "$launched_effort" != "$effort" ]; then
    fail "the launched Claude effort does not match the requested specification: launched=${launched_effort} requested=${spec}"
  fi
  printf 'effective: harness=claude provider=- model=%s effort=%s thinking=- permission_requested=%s requested=%s\n' \
    "$launched_model" "$launched_effort" "$permission_mode" "$spec" >&2
fi

exit 0
