#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_DIR="$SCRIPT_DIR/common"
ACTIONS_DIR="$SCRIPT_DIR/actions"
ACTIONS_JSON="$GH_DIR/actions.json"

source "$COMMON_DIR/auth.sh"
source "$COMMON_DIR/target.sh"
source "$COMMON_DIR/envelope.sh"
source "$COMMON_DIR/http.sh"
source "$COMMON_DIR/file.sh"

export GH_TEMP_DIR="${GH_TEMP_DIR:-$(mktemp -d /tmp/gh-XXXXXX)}"
trap 'gh_cleanup_temp_dir' EXIT

command -v jq >/dev/null || {
  envelope_fail "unknown" "MISSING_DEPENDENCY" "jq is required" false
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: gh.sh <action-name> [json-input-file]

Provide JSON input via a file argument or stdin.
EOF
  exit 2
}

validate_input() {
  local action_name="$1"
  local input_json="$2"
  local action_def="$3"

  local input_schema
  input_schema="$(echo "$action_def" | jq -c '.input_schema // {}')"

  if [ "$input_schema" = "{}" ] || [ "$input_schema" = "null" ]; then
    if [ -n "$input_json" ] && [ "$input_json" != "{}" ]; then
      envelope_fail "$action_name" "UNEXPECTED_INPUT" "Action '$action_name' expects no input" false
      return 1
    fi
    return 0
  fi

  if [ -z "$input_json" ] || [ "$input_json" = "{}" ]; then
    local has_required
    has_required="$(echo "$input_schema" | jq -r '[to_entries[] | select(.value.required == true)] | length')"
    if [ "$has_required" -gt 0 ]; then
      envelope_fail "$action_name" "MISSING_INPUT" "Action '$action_name' requires input" false
      return 1
    fi
    return 0
  fi

  local known_fields
  known_fields="$(echo "$input_schema" | jq -r 'keys[]' 2>/dev/null || true)"

  if [ -n "$known_fields" ]; then
    local unknown_fields
    unknown_fields="$(echo "$input_json" | jq -r --argjson known "$(echo "$input_schema" | jq 'keys')" '
      keys - $known | .[]
    ' 2>/dev/null || true)"

    if [ -n "$unknown_fields" ]; then
      local formatted
      formatted="$(echo "$unknown_fields" | tr '\n' ', ' | sed 's/, $//')"
      envelope_fail "$action_name" "UNKNOWN_FIELDS" "Unknown fields: $formatted" false
      return 1
    fi

    local field type required value
    while IFS='|' read -r field type required; do
      [ -z "$field" ] && continue

      value="$(echo "$input_json" | jq -r --arg f "$field" 'if has($f) then .[$f] else empty end' 2>/dev/null || true)"

      if [ "$required" = "true" ] && [ -z "$value" ]; then

        envelope_fail "$action_name" "MISSING_REQUIRED_FIELD" "Required field '$field' is missing" false
        return 1
      fi

      if [ -n "$value" ]; then
        local actual_type
        actual_type="$(echo "$input_json" | jq -r --arg f "$field" '.[$f] | type' 2>/dev/null || true)"

        if [ "$actual_type" != "$type" ] && [ "$actual_type" != "null" ]; then
          envelope_fail "$action_name" "TYPE_MISMATCH" "Field '$field' must be of type '$type', got '$actual_type'" false
          return 1
        fi
      fi
    done < <(echo "$input_schema" | jq -r 'to_entries[] | "\(.key)|\(.value.type // "")|\(.value.required // false)"')
  fi

  return 0
}

main() {
  [ "$#" -ge 1 ] || usage
  local action_name="$1"
  shift

  local input_json="{}"
  if [ "$#" -ge 1 ]; then
    input_json="$(<"$1")"
  elif [ ! -t 0 ]; then
    input_json="$(cat)"
  fi

  if ! echo "$input_json" | jq empty 2>/dev/null; then
    envelope_fail "$action_name" "INVALID_JSON" "Input is not valid JSON" false
    exit 1
  fi

  local action_def
  action_def="$(jq -c --arg name "$action_name" '
    .actions[] | select(.name == $name)
  ' "$ACTIONS_JSON")"

  if [ -z "$action_def" ]; then
    envelope_fail "$action_name" "UNKNOWN_ACTION" "Unknown action: $action_name. Use actions.list to see available actions." false
    exit 1
  fi

  validate_input "$action_name" "$input_json" "$action_def" || {
    local rc=$?
    [ "$rc" -gt 0 ] && exit "$rc"
  }

  local requires_auth
  requires_auth="$(echo "$action_def" | jq -r '.requires_auth // true')"

  if [ "$requires_auth" = "true" ]; then
    if ! check_auth 2>/dev/null; then
      envelope_fail "$action_name" "AUTH_ERROR" "gh is not authenticated or host is not github.com" false
      exit 1
    fi
  fi

  local permission
  permission="$(echo "$action_def" | jq -r '.permission // "read"')"
  local grant
  grant="$(echo "$input_json" | jq -r '.grant // "read"')"

  permission_level() {
    case "$1" in
      read) echo 0 ;;
      write) echo 1 ;;
      sensitive-write) echo 2 ;;
      *) echo 0 ;;
    esac
  }

  if [ "$(permission_level "$grant")" -lt "$(permission_level "$permission")" ]; then
    envelope_fail "$action_name" "GRANT_INSUFFICIENT" "Action requires '$permission' but grant is '$grant'" false
    exit 1
  fi

  local action_file="$ACTIONS_DIR/${action_name}.sh"
  if [ ! -f "$action_file" ]; then
    envelope_fail "$action_name" "NOT_IMPLEMENTED" "Action not yet implemented: $action_name" false
    exit 1
  fi

  if [ ! -x "$action_file" ]; then
    chmod +x "$action_file"
  fi

  "$action_file" "$input_json" || {
    local rc=$?
    exit "${rc:-1}"
  }
}

main "$@"
