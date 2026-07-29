#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERDR_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_DIR="$SCRIPT_DIR/common"
ACTIONS_DIR="$SCRIPT_DIR/actions"
ACTIONS_JSON="$HERDR_DIR/actions.json"

source "$COMMON_DIR/envelope.sh"
source "$COMMON_DIR/config.sh"
source "$COMMON_DIR/manifest.sh"
source "$COMMON_DIR/herdr_cli.sh"

if [ -z "${HERDR_TEMP_DIR:-}" ]; then
  export HERDR_TEMP_DIR="$(mktemp -d /tmp/herdr-skill-XXXXXX)"
fi
trap 'rm -rf "$HERDR_TEMP_DIR"' EXIT

command -v jq >/dev/null || {
  envelope_fail "unknown" "MISSING_DEPENDENCY" "jq is required" false
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: herdr.sh <action-name> [json-input-file]

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

validate_input_file() {
  local action_name="$1"
  local request_file="$2"
  local action_def="$3"

  local input_schema
  input_schema="$(jq -c '.input_schema // {}' <<< "$action_def")"

  if [ "$input_schema" = "{}" ] || [ "$input_schema" = "null" ]; then
    local has_keys
    has_keys="$(jq -r 'if (. | keys | length) > 0 then "true" else "false" end' "$request_file")"
    if [ "$has_keys" = "true" ]; then
      envelope_fail "$action_name" "UNEXPECTED_INPUT" "Action '$action_name' expects no input" false
      return 1
    fi
    return 0
  fi

  local has_required
  has_required="$(jq -r '[to_entries[] | select(.value.required == true)] | length' <<< "$input_schema")"
  if [ "$has_required" -gt 0 ]; then
    local input_empty
    input_empty="$(jq -r 'if (. | keys | length) == 0 then "true" else "false" end' "$request_file")"
    if [ "$input_empty" = "true" ]; then
      envelope_fail "$action_name" "MISSING_INPUT" "Action '$action_name' requires input" false
      return 1
    fi
  fi

  local schema_keys_json
  schema_keys_json="$(jq -c 'keys' <<< "$input_schema")"
  local unknown_fields
  unknown_fields="$(jq -r --argjson known "$schema_keys_json" '
    keys - $known | .[]
  ' "$request_file" 2>/dev/null || true)"

  if [ -n "$unknown_fields" ]; then
    local formatted
    formatted="$(echo "$unknown_fields" | tr '\n' ', ' | sed 's/, $//')"
    envelope_fail "$action_name" "UNKNOWN_FIELDS" "Unknown fields: $formatted" false
    return 1
  fi

  local entries
  entries="$(jq -r 'to_entries[] | "\(.key)|\(.value.type // "")|\(.value.required // false)"' <<< "$input_schema")"

  local field type required
  while IFS='|' read -r field type required; do
    [ -z "$field" ] && continue

    if [ "$required" = "true" ]; then
      local field_present
      field_present="$(jq -r --arg f "$field" 'has($f)' "$request_file")"
      if [ "$field_present" != "true" ]; then
        envelope_fail "$action_name" "MISSING_REQUIRED_FIELD" "Required field '$field' is missing" false
        return 1
      fi
    fi

    local field_present
    field_present="$(jq -r --arg f "$field" 'has($f)' "$request_file")"
    if [ "$field_present" = "true" ]; then
      local actual_type
      actual_type="$(jq -r --arg f "$field" '.[$f] | type' "$request_file")"
      if [ "$actual_type" != "$type" ] && [ "$actual_type" != "null" ]; then
        envelope_fail "$action_name" "TYPE_MISMATCH" "Field '$field' must be of type '$type', got '$actual_type'" false
        return 1
      fi
    fi
  done <<< "$entries"

  return 0
}

permission_level() {
  case "$1" in
    read) echo 0 ;;
    write) echo 1 ;;
    sensitive-write) echo 2 ;;
    *) echo 0 ;;
  esac
}

main() {
  [ "$#" -ge 1 ] || usage
  local action_name="$1"
  shift

  if [[ "$action_name" == member.* ]] || [[ "$action_name" == team.start ]] || [[ "$action_name" == team.stop ]]; then
    local request_file="$HERDR_TEMP_DIR/request.json"
    if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
      cp "$1" "$request_file"
    elif [ ! -t 0 ]; then
      cat > "$request_file"
    fi

    if [ ! -f "$request_file" ] || [ ! -s "$request_file" ]; then
      request_file="/dev/null"
      echo '{}' > "$HERDR_TEMP_DIR/request.json"
      request_file="$HERDR_TEMP_DIR/request.json"
    fi

    if ! jq empty "$request_file" 2>/dev/null; then
      envelope_fail "$action_name" "INVALID_JSON" "Input is not valid JSON" false
      exit 1
    fi

    local action_def
    action_def="$(jq -c --arg name "$action_name" '
      .actions[] | select(.name == $name)
    ' "$ACTIONS_JSON")"

    if [ -z "$action_def" ]; then
      envelope_fail "$action_name" "UNKNOWN_ACTION" "Unknown action: $action_name" false
      exit 1
    fi

    validate_input_file "$action_name" "$request_file" "$action_def" || {
      local rc=$?
      [ "$rc" -gt 0 ] && exit "$rc"
    }

    local permission
    permission="$(jq -r '.permission // "read"' <<< "$action_def")"
    local grant
    grant="$(jq -r '.grant // "read"' "$request_file")"

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

    "$action_file" "$request_file" || {
      local rc=$?
      exit "${rc:-1}"
    }
  else
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
      envelope_fail "$action_name" "UNKNOWN_ACTION" "Unknown action: $action_name" false
      exit 1
    fi

    validate_input "$action_name" "$input_json" "$action_def" || {
      local rc=$?
      [ "$rc" -gt 0 ] && exit "$rc"
    }

    local permission
    permission="$(echo "$action_def" | jq -r '.permission // "read"')"
    local grant
    grant="$(echo "$input_json" | jq -r '.grant // "read"')"

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
  fi
}

main "$@"
