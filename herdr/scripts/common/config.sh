#!/usr/bin/env bash
set -euo pipefail

CONFIG_ALLOWED_TOP_FIELDS='["schema_version","members"]'
CONFIG_ALLOWED_MEMBER_FIELDS='["role","kind","activation","prompt_file"]'
CONFIG_VALID_ACTIVATIONS='["immediate","deferred"]'

herdr_config_resolve() {
  local explicit_path="${1:-}"
  local fallback_kind="${2:-}"

  local config_path=""

  if [ -n "$explicit_path" ]; then
    if [ -f "$explicit_path" ]; then
      config_path="$(cd "$(dirname "$explicit_path")" && pwd)/$(basename "$explicit_path")"
    else
      echo "config: explicit config_path not found: $explicit_path" >&2
      echo '{}'
      return 1
    fi
  else
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

    if [ -n "$git_root" ]; then
      local dir="$PWD"
      while true; do
        if [ -f "$dir/.herdr/team.json" ]; then
          config_path="$(cd "$dir" && pwd)/.herdr/team.json"
          break
        fi
        [ "$dir" = "/" ] && break
        [ -n "$git_root" ] && [ "$dir" = "$git_root" ] && break
        dir="$(dirname "$dir")"
      done
    fi

    if [ -z "$config_path" ]; then
      local global_config="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/team.json"
      if [ -f "$global_config" ]; then
        config_path="$global_config"
      fi
    fi

    if [ -z "$config_path" ]; then
      local script_dir
      script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
      local bundled_config="$script_dir/team.json"
      if [ -f "$bundled_config" ]; then
        config_path="$bundled_config"
      fi
    fi
  fi

  if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
    if [ -z "$fallback_kind" ]; then
      echo '{}'
      return 0
    fi
    herdr_config_default "$fallback_kind"
    return 0
  fi

  if ! jq empty "$config_path" 2>/dev/null; then
    echo '{}' >&2
    echo '{}'
    return 1
  fi

  local schema_version
  schema_version="$(jq -r '.schema_version // 0' "$config_path")"

  if [ "$schema_version" != "1" ]; then
    echo "config: unsupported schema_version=$schema_version" >&2
    echo '{}'
    return 1
  fi

  local members_count
  members_count="$(jq -r '.members | length // 0' "$config_path")"

  if [ "$members_count" -eq 0 ]; then
    if [ -z "$fallback_kind" ]; then
      echo '{}'
      return 0
    fi
    herdr_config_default "$fallback_kind"
    return 0
  fi

  local config_dir
  config_dir="$(dirname "$config_path")"

  local validated
  validated="$(jq -c \
    --arg config_dir "$config_dir" \
    --arg fallback_kind "$fallback_kind" \
    '
    . + {
      _config_dir: $config_dir,
      _config_path: input_filename,
      members: [.members[] | . + {
        kind: (.kind // $fallback_kind),
        activation: (.activation // (if .role == "impl" then "immediate" else "deferred" end)),
        prompt_file: (.prompt_file // null)
      }]
    }
    ' "$config_path")"

  echo "$validated"
}

herdr_config_validate_members() {
  local config_json="$1"

  local errors=""

  local top_unknown
  top_unknown="$(echo "$config_json" | jq -r --argjson allowed "$CONFIG_ALLOWED_TOP_FIELDS" '
    [keys[] | select(. != "schema_version" and . != "members" and . != "_config_dir" and . != "_config_path")] | join(", ")
  ')"
  if [ -n "$top_unknown" ] && [ "$top_unknown" != "null" ]; then
    errors="${errors}top-level unknown fields: $top_unknown\n"
  fi

  local config_dir
  config_dir="$(echo "$config_json" | jq -r '._config_dir // ""')"

  local role kind activation prompt_file
  local seen_roles=()
  local seen

  local count
  count="$(echo "$config_json" | jq -r '.members | length')"
  local i
  for i in $(seq 0 $((count - 1))); do
    role="$(echo "$config_json" | jq -r ".members[$i].role // \"\"")"
    kind="$(echo "$config_json" | jq -r ".members[$i].kind // \"\"")"
    activation="$(echo "$config_json" | jq -r ".members[$i].activation // \"\"")"
    prompt_file="$(echo "$config_json" | jq -r ".members[$i].prompt_file // \"\"")"

    if [ -z "$role" ]; then
      errors="${errors}member[$i]: role is required\n"
      continue
    fi

    local member_unknown
    member_unknown="$(echo "$config_json" | jq -r --argjson allowed "$CONFIG_ALLOWED_MEMBER_FIELDS" --arg i "$i" '
      [.members[$i|tonumber] | keys[] | select(. as $k | $allowed | index($k) | not)] | join(", ")
    ')"
    if [ -n "$member_unknown" ] && [ "$member_unknown" != "null" ] && [ "$member_unknown" != "" ]; then
      errors="${errors}member[$i] ($role): unknown fields: $member_unknown\n"
    fi

    for seen in "${seen_roles[@]}"; do
      if [ "$seen" = "$role" ]; then
        errors="${errors}member[$i] ($role): duplicate role\n"
      fi
    done
    seen_roles+=("$role")

    local kind_type
    kind_type="$(echo "$config_json" | jq -r ".members[$i].kind | type")"
    if [ "$kind_type" != "string" ]; then
      errors="${errors}member[$i] ($role): kind must be string, got $kind_type\n"
    elif [ -z "$kind" ]; then
      errors="${errors}member[$i] ($role): kind is required\n"
    fi

    if [ "$activation" != "immediate" ] && [ "$activation" != "deferred" ]; then
      errors="${errors}member[$i] ($role): activation must be immediate or deferred, got '$activation'\n"
    fi

    if [ -n "$prompt_file" ] && [ "$prompt_file" != "null" ]; then
      local pf_type
      pf_type="$(echo "$config_json" | jq -r ".members[$i].prompt_file | type")"
      if [ "$pf_type" != "string" ]; then
        errors="${errors}member[$i] ($role): prompt_file must be string, got $pf_type\n"
      elif [[ "$prompt_file" =~ ^/ ]] || [[ "$prompt_file" =~ \.\./ ]]; then
        errors="${errors}member[$i] ($role): prompt_file must be relative and cannot contain '..' or absolute paths (got '$prompt_file')\n"
      elif [ -n "$config_dir" ] && [ "$config_dir" != "null" ]; then
        local resolved="$config_dir/$prompt_file"
        if [ ! -f "$resolved" ]; then
          errors="${errors}member[$i] ($role): prompt_file '$prompt_file' not found relative to config dir\n"
        else
          local real_prompt
          real_prompt="$(realpath "$resolved" 2>/dev/null || readlink -f "$resolved" 2>/dev/null || echo "")"
          local real_config
          real_config="$(realpath "$config_dir" 2>/dev/null || readlink -f "$config_dir" 2>/dev/null || echo "")"
          if [ -n "$real_prompt" ] && [ -n "$real_config" ]; then
            if [[ "$real_prompt" != "$real_config"/* ]]; then
              errors="${errors}member[$i] ($role): prompt_file resolves outside config directory ($real_prompt not under $real_config)\n"
            fi
          fi
        fi
      fi
    fi

    local is_custom_role=true
    case "$role" in
      impl|review|pr-fix) is_custom_role=false ;;
    esac

    if [ "$is_custom_role" = true ]; then
      if [ -z "$prompt_file" ] || [ "$prompt_file" = "null" ]; then
        errors="${errors}member[$i] ($role): custom role requires prompt_file\n"
      fi
    fi
  done

  if [ -n "$errors" ]; then
    echo -e "$errors" >&2
    return 1
  fi
  return 0
}

herdr_config_default() {
  local kind="${1:-opencode}"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  jq -nc \
    --arg kind "$kind" \
    --arg config_dir "$script_dir" \
    '{
      schema_version: 1,
      _config_dir: $config_dir,
      _config_path: "bundled-default",
      members: [
        {role: "impl", kind: $kind, activation: "immediate"},
        {role: "review", kind: $kind, activation: "deferred"},
        {role: "pr-fix", kind: $kind, activation: "deferred"}
      ]
    }'
}

herdr_config_resolve_prompt() {
  local config_json="$1"
  local role="$2"

  local config_dir
  config_dir="$(echo "$config_json" | jq -r '._config_dir // ""')"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

  local prompt_file
  prompt_file="$(echo "$config_json" | jq -r --arg role "$role" '
    [.members[] | select(.role == $role) | .prompt_file // empty] | first // ""
  ')"

  if [ -n "$prompt_file" ] && [ "$prompt_file" != "null" ]; then
    local resolved="$config_dir/$prompt_file"
    if [ -f "$resolved" ]; then
      cat "$resolved"
      return 0
    fi
  fi

  local bundled="$script_dir/prompts/${role}.md"
  if [ -f "$bundled" ]; then
    cat "$bundled"
    return 0
  fi

  return 1
}

herdr_config_snapshot_prompts() {
  local config_json="$1"

  local result="{}"
  local count
  count="$(echo "$config_json" | jq -r '.members | length')"
  local i
  for i in $(seq 0 $((count - 1))); do
    local role
    role="$(echo "$config_json" | jq -r ".members[$i].role")"
    if [ -z "$role" ] || [ "$role" = "null" ]; then
      continue
    fi
    local prompt_content
    prompt_content="$(herdr_config_resolve_prompt "$config_json" "$role" 2>/dev/null || echo "")"
    if [ -n "$prompt_content" ]; then
      result="$(echo "$result" | jq -c --arg role "$role" --arg content "$prompt_content" '. + {($role): $content}')"
    fi
  done
  echo "$result"
}
