#!/usr/bin/env bash
set -euo pipefail

CONFIG_ALLOWED_TOP_FIELDS='["schema_version","layout","members"]'
CONFIG_ALLOWED_MEMBER_FIELDS='["role","kind","activation","prompt_file"]'
CONFIG_ALLOWED_LAYOUT_FIELDS='["max_cols"]'

herdr_config_realpath_file() {
  local path="$1"
  realpath -e -- "$path" 2>/dev/null || readlink -f -- "$path" 2>/dev/null
}

herdr_config_validate_raw_file() {
  local config_path="$1"

  jq -e --argjson top_allowed "$CONFIG_ALLOWED_TOP_FIELDS" \
    --argjson member_allowed "$CONFIG_ALLOWED_MEMBER_FIELDS" \
    --argjson layout_allowed "$CONFIG_ALLOWED_LAYOUT_FIELDS" '
    def safe_name:
      type == "string"
      and length > 0
      and length <= 128
      and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def no_control:
      type == "string" and (explode | all(. >= 32 and . != 127));
    type == "object"
    and ((keys - $top_allowed) | length == 0)
    and has("schema_version")
    and (.schema_version | type == "number" and . == 2)
    and has("layout")
    and (.layout | type == "object")
    and ((.layout | keys - $layout_allowed) | length == 0)
    and (.layout.max_cols | type == "number" and floor == . and . >= 1 and . <= 3)
    and has("members")
    and (.members | type == "array" and length > 0)
    and all(.members[];
      type == "object"
      and ((keys - $member_allowed) | length == 0)
      and has("role")
      and (.role | safe_name)
      and ((has("kind") | not) or (.kind | safe_name))
      and ((has("activation") | not) or (.activation | type == "string" and (. == "immediate" or . == "deferred")))
      and ((has("prompt_file") | not) or .prompt_file == null or (.prompt_file | no_control and length > 0))
    )
    and (([.members[].role] | unique | length) == (.members | length))
  ' "$config_path" >/dev/null 2>&1
}

herdr_config_resolve() {
  local explicit_path="${1:-}"
  local fallback_kind="${2:-}"
  local config_path=""

  if [ -n "$explicit_path" ]; then
    config_path="$(herdr_config_realpath_file "$explicit_path" || true)"
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
      echo "config: explicit config_path not found: $explicit_path" >&2
      return 1
    fi
  else
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

    if [ -n "$git_root" ]; then
      local dir="$PWD"
      while true; do
        if [ -e "$dir/.herdr/team.json" ]; then
          config_path="$(herdr_config_realpath_file "$dir/.herdr/team.json" || true)"
          break
        fi
        [ "$dir" = "/" ] && break
        [ "$dir" = "$git_root" ] && break
        dir="$(dirname "$dir")"
      done
    fi

    if [ -z "$config_path" ]; then
      local global_config="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/team.json"
      if [ -e "$global_config" ]; then
        config_path="$(herdr_config_realpath_file "$global_config" || true)"
      fi
    fi

    if [ -z "$config_path" ]; then
      local script_dir
      script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
      config_path="$(herdr_config_realpath_file "$script_dir/team.json" || true)"
    fi
  fi

  if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
    echo "config: no readable config file found" >&2
    return 1
  fi

  if [ ! -s "$config_path" ] || ! jq empty "$config_path" 2>/dev/null; then
    echo "config: config file is empty or invalid JSON: $config_path" >&2
    return 1
  fi

  if ! herdr_config_validate_raw_file "$config_path"; then
    echo "config: schema validation failed: $config_path" >&2
    return 1
  fi

  if [[ ! "$fallback_kind" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "config: invalid fallback agent kind" >&2
    return 1
  fi

  local config_dir
  config_dir="$(dirname "$config_path")"

  jq -c \
    --arg config_dir "$config_dir" \
    --arg config_path "$config_path" \
    --arg fallback_kind "$fallback_kind" '
    . + {
      _config_dir: $config_dir,
      _config_path: $config_path,
      layout: .layout,
      members: [.members[] | . + {
        kind: (.kind // $fallback_kind),
        activation: (.activation // (if .role == "impl" then "immediate" else "deferred" end)),
        prompt_file: (.prompt_file // null)
      }]
    }
  ' "$config_path"
}

herdr_config_validate_members() {
  local config_json="$1"

  if ! jq -e '
    type == "object"
    and (.schema_version | type == "number" and . == 2)
    and (._config_dir | type == "string" and length > 0)
    and (._config_path | type == "string" and length > 0)
    and (.layout | type == "object")
    and (.layout.max_cols | type == "number" and floor == . and . >= 1 and . <= 3)
    and (.members | type == "array" and length > 0)
    and all(.members[];
      type == "object"
      and (.role | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.kind | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
      and (.activation | type == "string" and (. == "immediate" or . == "deferred"))
      and (.prompt_file == null or (.prompt_file | type == "string" and length > 0))
    )
    and (([.members[].role] | unique | length) == (.members | length))
  ' <<< "$config_json" >/dev/null 2>&1; then
    echo "config: normalized config validation failed" >&2
    return 1
  fi

  local config_dir
  config_dir="$(jq -r '._config_dir' <<< "$config_json")"
  local real_config
  real_config="$(realpath -e -- "$config_dir" 2>/dev/null || readlink -f -- "$config_dir" 2>/dev/null || true)"
  if [ -z "$real_config" ] || [ ! -d "$real_config" ]; then
    echo "config: config directory cannot be canonicalized" >&2
    return 1
  fi

  local count i
  count="$(jq -r '.members | length' <<< "$config_json")"
  for ((i = 0; i < count; i++)); do
    local role prompt_file
    role="$(jq -r ".members[$i].role" <<< "$config_json")"
    prompt_file="$(jq -r ".members[$i].prompt_file // empty" <<< "$config_json")"

    case "$role" in
      impl|review|pr-fix) ;;
      *)
        if [ -z "$prompt_file" ]; then
          echo "config: member[$i] ($role): custom role requires prompt_file" >&2
          return 1
        fi
        ;;
    esac

    if [ -n "$prompt_file" ]; then
      if [[ "$prompt_file" = /* ]]; then
        echo "config: member[$i] ($role): prompt_file must be relative" >&2
        return 1
      fi
      local resolved real_prompt
      resolved="$real_config/$prompt_file"
      real_prompt="$(realpath -e -- "$resolved" 2>/dev/null || readlink -f -- "$resolved" 2>/dev/null || true)"
      if [ -z "$real_prompt" ] || [ ! -f "$real_prompt" ]; then
        echo "config: member[$i] ($role): prompt_file not found" >&2
        return 1
      fi
      case "$real_prompt" in
        "$real_config"/*) ;;
        *)
          echo "config: member[$i] ($role): prompt_file resolves outside config directory" >&2
          return 1
          ;;
      esac
    fi
  done
}

herdr_config_default() {
  local kind="${1:-opencode}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  herdr_config_resolve "$script_dir/team.json" "$kind"
}

herdr_config_resolve_prompt() {
  local config_json="$1"
  local role="$2"
  local config_dir
  config_dir="$(jq -r '._config_dir // ""' <<< "$config_json")"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local prompt_file
  prompt_file="$(jq -r --arg role "$role" '[.members[] | select(.role == $role) | .prompt_file // empty] | first // ""' <<< "$config_json")"
  if [ -n "$prompt_file" ]; then
    local resolved
    resolved="$(realpath -e -- "$config_dir/$prompt_file" 2>/dev/null || readlink -f -- "$config_dir/$prompt_file" 2>/dev/null || true)"
    case "$resolved" in
      "$config_dir"/*)
        [ -f "$resolved" ] && { command cat "$resolved"; return 0; }
        ;;
    esac
  fi

  local bundled="$script_dir/prompts/${role}.md"
  if [ -f "$bundled" ]; then
    command cat "$bundled"
    return 0
  fi
  return 1
}

herdr_config_snapshot_prompts() {
  local config_json="$1"
  local result="{}"
  local count i
  count="$(jq -r '.members | length' <<< "$config_json")"
  for ((i = 0; i < count; i++)); do
    local role prompt_content
    role="$(jq -r ".members[$i].role" <<< "$config_json")"
    prompt_content="$(herdr_config_resolve_prompt "$config_json" "$role")" || {
      echo "config: no prompt could be resolved for role '$role'" >&2
      return 1
    }
    result="$(jq -c --arg role "$role" --arg content "$prompt_content" '. + {($role): $content}' <<< "$result")"
  done
  echo "$result"
}
