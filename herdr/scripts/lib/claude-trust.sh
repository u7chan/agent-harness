#!/usr/bin/env bash
# Claude workspace-trust state: which file holds the record and what one
# directory's record says.
#
# Sourced by start-agent.sh (read-only preflight) and claude-trust.sh (the
# human-run writer). The resolution rule and the state vocabulary have one
# definition here, so the launcher and the writer cannot disagree about which
# file is read, how a path is normalized, or what an unapproved directory is.
#
# The launcher keeps its read-only, fail-closed rounding: every state other
# than `true` is unapproved. The writer is stricter than the reader: it writes
# only for `missing-key` and `false`, creates a `missing-file`, and stops
# without initializing anything for `unreadable`, `invalid-json`, and
# `unexpected-shape`.
#
# Measured on Claude Code 2.1.330: the CLI reads
# `projects[<realpath>].hasTrustDialogAccepted` and skips the trust dialog for
# an explicit `true`. See SKILL.md#claude-trust-approval.

# claude_trust_normalize_path <path>
#
# Print the normalized absolute path, or return 1 when the system cannot
# resolve it. This is the launcher's realpath rule: `realpath -m` normalizes
# without requiring the target to exist.
claude_trust_normalize_path() {
  local resolved=''
  resolved="$(realpath -m -- "$1" 2>/dev/null)" || resolved=''
  case "$resolved" in
    /*) printf '%s\n' "$resolved" ;;
    *) return 1 ;;
  esac
}

# claude_trust_usable_dir <path>
#
# Return 0 when the value can be a Claude config directory in this repository's
# contracts: an absolute path on one line, with no whitespace or control
# characters (the value is passed to the CLI and quoted into commands).
claude_trust_usable_dir() {
  case "${1:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:][:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# claude_trust_config_dir <reported-config-directory>
#
# Print the effective config directory: $CLAUDE_CONFIG_DIR when it is set,
# otherwise the directory the auth helper reported. Return 1 when the chosen
# value is unusable; the caller owns the failure message.
claude_trust_config_dir() {
  local chosen=''
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    chosen="$CLAUDE_CONFIG_DIR"
  else
    chosen="${1:-}"
  fi
  claude_trust_usable_dir "$chosen" || return 1
  printf '%s\n' "$chosen"
}

# claude_trust_file_for <explicit|default> <config-directory>
#
# Print the state file for one config directory. `explicit` is a directory that
# came from $CLAUDE_CONFIG_DIR, so the state file sits inside it; `default` is
# the config directory the CLI reports when the variable is unset, and the
# state file sits one level above it (measured on 2.1.330: the default config
# directory is `<home>/.claude` and the state file stays at `<home>/.claude.json`).
claude_trust_file_for() {
  local mode="$1" config_dir="$2"
  case "$mode" in
    explicit) printf '%s/.claude.json\n' "${config_dir%/}" ;;
    default) printf '%s/.claude.json\n' "$(dirname -- "$config_dir")" ;;
    *) return 2 ;;
  esac
}

# claude_trust_file <reported-config-directory>
#
# Print the state file for the caller's own environment, using the same rule as
# the CLI: $CLAUDE_CONFIG_DIR when set, otherwise the reported config
# directory's parent.
claude_trust_file() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    claude_trust_file_for explicit "$1"
  else
    claude_trust_file_for default "$1"
  fi
}

# claude_trust_strict_json <file>
#
# Exit 0 only when the file holds exactly one strict JSON document. `jq` and
# Python's `json` both accept the non-standard constants `Infinity`, `-Infinity`,
# and `NaN`; a state file containing one of them is a syntax error for Claude
# Code, so the reader must not treat it as a record either. `JSON.parse` in
# Node rejects those tokens and any trailing data, which is the shape this
# repository already requires (start-agent.sh parses the role specification with
# Node). Exit 3 when no validator is available: an unvalidated document is
# never read as approved.
claude_trust_strict_json() {
  command -v node >/dev/null 2>&1 || return 3
  node --input-type=module -e '
import { readFileSync } from "node:fs";
try {
  JSON.parse(readFileSync(process.argv[1], "utf8"));
} catch {
  process.exit(1);
}
' "$1" 2>/dev/null
}

# claude_trust_state <state-file> <normalized-directory>
#
# Print exactly one classification:
#
#   missing-file      no state file
#   unreadable        a state file exists but cannot be read as a file
#   invalid-json      the file is not JSON
#   unexpected-shape  JSON, but not the object shape this record needs
#   missing-key       no project entry, or no trust key in that entry
#   false             the record is present and explicitly false
#   true              the record is present and explicitly true
#
# Always exits 0 for a classification so a caller under `set -e` can read the
# verdict; only a usage error returns 2. The trimmed, unmodified path is the
# key: a path with a trailing slash or a symlinked spelling is a different
# record, and round-to-unapproved happens in the caller.
claude_trust_state() {
  if [ "$#" -ne 2 ]; then
    printf 'Usage: claude_trust_state <state-file> <normalized-directory>\n' >&2
    return 2
  fi
  local file="$1" dir="$2" verdict='' rc=0 strict_rc=0
  if [ -d "$file" ]; then
    printf 'unreadable\n'
    return 0
  fi
  if [ ! -e "$file" ]; then
    printf 'missing-file\n'
    return 0
  fi
  if [ ! -r "$file" ]; then
    printf 'unreadable\n'
    return 0
  fi
  # Strict syntax first: `jq -s` accepts `Infinity`, `NaN`, and two concatenated
  # documents, so its own parse cannot tell a record from a file the CLI rejects.
  strict_rc=0
  claude_trust_strict_json "$file" || strict_rc=$?
  if [ "$strict_rc" -ne 0 ]; then
    printf 'invalid-json\n'
    return 0
  fi
  # The slurp also pins the value count at one for the classification below.
  verdict="$(jq -s -r --arg dir "$dir" '
    if length != 1 then "invalid-json"
    else .[0] as $document
      | if ($document | type) != "object" then "unexpected-shape"
        elif (($document | has("projects")) and (($document.projects | type) != "object")) then
          "unexpected-shape"
        else ($document.projects // {}) as $projects
          | if ($projects | has($dir)) | not then "missing-key"
            else $projects[$dir] as $entry
              | if ($entry | type) != "object" then "unexpected-shape"
                elif ($entry | has("hasTrustDialogAccepted")) | not then "missing-key"
                elif $entry.hasTrustDialogAccepted == true then "true"
                elif $entry.hasTrustDialogAccepted == false then "false"
                else "unexpected-shape"
                end
            end
        end
    end' "$file" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'invalid-json\n'
    return 0
  fi
  verdict="${verdict%%$'\n'*}"
  case "$verdict" in
    invalid-json | unexpected-shape | missing-key | false | true) ;;
    *) verdict='unexpected-shape' ;;
  esac
  printf '%s\n' "$verdict"
}

# claude_trust_claude_processes
#
# Print one tab-separated line per running `claude` process of this user:
#
#   <pid>\t<explicit|default>\t<config-directory or - >\t<home-directory or - >\t<cwd or - >
#
# The program is the basename of the first command-line token, so a wrapper
# such as claude-trust.sh is not mistaken for the CLI. `explicit` means the
# process carries a non-empty CLAUDE_CONFIG_DIR; `default` means it does not,
# and its state file follows the process's own HOME (measured on 2.1.330:
# `<home>/.claude` is the default config directory and the state file stays at
# `<home>/.claude.json`). The reader reports the environment each process
# actually carries, never the writer's own. The cwd is the process's working
# directory, because a relative CLAUDE_CONFIG_DIR belongs to that directory, not
# to the caller's.
#
# Exit status: 0 when at least one process was printed, 1 when there is none,
# 2 when the scan cannot confirm either way. Only this user's processes are
# examined: another account cannot write this user's state file. A candidate
# whose environment cannot be read is unconfirmable, so a zombie, a hidden
# environment, or a missing `ps` stops the writer instead of guessing.
claude_trust_claude_processes() {
  command -v ps >/dev/null 2>&1 || return 2
  local uid listing line pid owner args first env_file env_text config_value home_value
  local cwd_link cwd_value found=1
  uid="$(id -u 2>/dev/null)" || return 2
  listing="$(ps -e -o pid=,uid=,args= 2>/dev/null)" || return 2
  [ -n "$listing" ] || return 2
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    pid="${line%%[[:space:]]*}"
    line="${line#"$pid"}"
    line="${line#"${line%%[![:space:]]*}"}"
    owner="${line%%[[:space:]]*}"
    args="${line#"$owner"}"
    args="${args#"${args%%[![:space:]]*}"}"
    [ "$owner" = "$uid" ] || continue
    [ -n "$args" ] || continue
    first="${args%%[[:space:]]*}"
    [ "${first##*/}" = claude ] || continue
    env_file="/proc/${pid}/environ"
    [ -r "$env_file" ] || return 2
    env_text="$(tr '\0' '\n' < "$env_file" 2>/dev/null)" || return 2
    [ -n "$env_text" ] || return 2
    found=0
    config_value="$(printf '%s\n' "$env_text" | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n 1)"
    home_value="$(printf '%s\n' "$env_text" | sed -n 's/^HOME=//p' | head -n 1)"
    cwd_value=''
    cwd_link="/proc/${pid}/cwd"
    if [ -e "$cwd_link" ]; then
      cwd_value="$(readlink -f -- "$cwd_link" 2>/dev/null)" || cwd_value=''
    fi
    if [ -n "$config_value" ]; then
      printf '%s\texplicit\t%s\t%s\t%s\n' "$pid" "$config_value" "${home_value:--}" "${cwd_value:--}"
    else
      printf '%s\tdefault\t-\t%s\t%s\n' "$pid" "${home_value:--}" "${cwd_value:--}"
    fi
  done <<< "$listing"
  return "$found"
}

# claude_trust_process_state_file <explicit|default> <config-directory> <home> <cwd>
#
# Print the state file one scanned process uses, from that process's own
# environment. An explicit absolute directory keeps the state inside it; a
# relative one belongs to the process's cwd and is unconfirmable without it. A
# default process resolves `<home>/.claude.json`; one without a HOME is
# unconfirmable too, so the caller stops instead of comparing against its own.
claude_trust_process_state_file() {
  local mode="$1" config_dir="${2:-}" home="${3:-}" cwd="${4:-}"
  case "$mode" in
    explicit)
      [ -n "$config_dir" ] && [ "$config_dir" != - ] || return 1
      case "$config_dir" in
        /*) ;;
        *)
          [ -n "$cwd" ] && [ "$cwd" != - ] || return 1
          config_dir="${cwd%/}/${config_dir}"
          ;;
      esac
      claude_trust_file_for explicit "$config_dir"
      ;;
    default)
      [ -n "$home" ] && [ "$home" != - ] || return 1
      printf '%s/.claude.json\n' "${home%/}"
      ;;
    *) return 2 ;;
  esac
}
