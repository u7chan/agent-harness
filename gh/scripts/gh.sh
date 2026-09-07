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

if [ -z "${GH_TEMP_DIR:-}" ]; then
  export GH_TEMP_DIR="$(mktemp -d /tmp/gh-XXXXXX)"
  touch "$GH_TEMP_DIR/.gh-tmp-marker"
fi
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

# Shared request validation for every action. main() materializes the
# request JSON into a request file exactly once (whichever entry path the
# input arrived on), so there is exactly one validator. Field semantics:
# - required field: the key must be present with a non-null, non-empty value
#   of the declared type. Missing key, explicit null, and empty string are
#   all MISSING_REQUIRED_FIELD; a required number must never reach an
#   action as null.
# - optional field: absent passes; when present it must match the declared
#   type, except an explicit null, which is allowed as a per-action contract
#   (update actions use null to clear a value while absence means "keep").
# - unknown keys are rejected as UNKNOWN_FIELDS.
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

    local field_state
    field_state="$(jq -r --arg f "$field" '
      if has($f) | not then "missing"
      elif .[$f] == null then "null"
      elif ((.[$f] | type) == "string") and ((.[$f] | length) == 0) then "empty"
      else "ok"
      end' "$request_file")"

    if [ "$required" = "true" ] && [ "$field_state" != "ok" ]; then
      envelope_fail "$action_name" "MISSING_REQUIRED_FIELD" "Required field '$field' is missing" false
      return 1
    fi

    if [ "$field_state" = "missing" ]; then
      continue
    fi

    local actual_type
    actual_type="$(jq -r --arg f "$field" '.[$f] | type' "$request_file")"
    if [ "$actual_type" != "$type" ] && [ "$actual_type" != "null" ]; then
      envelope_fail "$action_name" "TYPE_MISMATCH" "Field '$field' must be of type '$type', got '$actual_type'" false
      return 1
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

  # One input acquisition for every action: an explicit input file argument
  # wins, piped stdin comes next, and without either there is no input. The
  # request JSON is materialized into a scratch request file once, so both
  # the shared validator and the actions see one identical request; the
  # string-input and request-file entry paths can no longer diverge.
  local request_file
  request_file="$(gh_make_temp "request-json")"

  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    cp "$1" "$request_file"
  elif [ ! -t 0 ]; then
    cat > "$request_file"
  fi

  # An empty or whitespace-only input means "no input" on both entry paths:
  # normalize it to {} so the shared file validator and the action always
  # see a JSON object. Without this normalization an empty request file is
  # zero JSON inputs for jq and would slip past the INVALID_JSON check into
  # per-field validation (MISSING_REQUIRED_FIELD instead of MISSING_INPUT).
  if [ -z "$(tr -d '[:space:]' < "$request_file")" ]; then
    printf '%s\n' '{}' > "$request_file"
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

  # jq's // treats false as empty, so only a missing or null key may be
  # defaulted to true; an explicit catalog requires_auth:false must keep
  # the action auth-free.
  local requires_auth
  requires_auth="$(jq -r 'if (.requires_auth == null) then "true" else (.requires_auth | tostring) end' <<< "$action_def")"

  if [ "$requires_auth" = "true" ]; then
    if ! check_auth 2>/dev/null; then
      envelope_fail "$action_name" "AUTH_ERROR" "gh is not authenticated or host is not github.com" false
      exit 1
    fi
  fi

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

  # Launch contract: every action script runs under the dispatcher's own
  # bash, and the dispatcher never chmods action files. Action scripts are
  # read-only dependencies of the dispatcher, so dispatch works from a
  # read-only checkout and leaves the checkout untouched (git status stays
  # clean) even when an executable bit is missing. The first argument is
  # the request JSON: the comments/review family reads it from the request
  # file path, every other action receives the inline JSON text.
  local request_arg
  case "$action_name" in
    comments.* | review-comments.* | reviews.* | review-threads.*)
      request_arg="$request_file"
      ;;
    *)
      request_arg="$(cat "$request_file")"
      ;;
  esac

  "$BASH" "$action_file" "$request_arg" || {
    local rc=$?
    exit "${rc:-1}"
  }
}

main "$@"
