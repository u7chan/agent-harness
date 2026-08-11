#!/usr/bin/env bash
set -euo pipefail

PW_VALIDATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_VALIDATOR_PROGRAM="$(cat "$PW_VALIDATOR_DIR/validator.jq")"

# Synthesize the full input schema for an action: the action-specific schema
# plus common fields (grant for all actions, session for browser actions,
# request_id for write actions).
pw_full_input_schema() {
  local action_def="$1"
  jq -cn --argjson a "$action_def" '
    {type: "object", additionalProperties: false, properties: {}, required: []}
    | .properties += (($a.input_schema.properties) // {})
    | .required += (($a.input_schema.required) // [])
    | if ($a.input_schema.oneOfFields != null) then .oneOfFields = $a.input_schema.oneOfFields else . end
    | if ($a.input_schema.dependentRequired != null) then .dependentRequired = $a.input_schema.dependentRequired else . end
    | if ($a.input_schema.minProperties != null) then .minProperties = $a.input_schema.minProperties else . end
    | if ($a.input_schema.maxProperties != null) then .maxProperties = $a.input_schema.maxProperties else . end
    | if ($a.session == "required") then
        .properties.session = {type: "string", format: "session-name"} | .required += ["session"]
      else . end
    | .properties.grant = {type: "string", enum: ["read", "write", "sensitive-write"]}
    | if ($a.permission != "read") then
        .properties.request_id = {type: "string", format: "uuid"} | .required += ["request_id"]
      else . end
  '
}

# Validate an instance against a schema. Returns 0 and prints nothing when
# valid; returns 1 and prints the first error {path, code, message} otherwise.
pw_validate_input() {
  local schema="$1"
  local instance="$2"
  local errors
  errors="$(jq -cn --argjson s "$schema" --argjson i "$instance" \
    "$PW_VALIDATOR_PROGRAM"' pw_validate($i; $s)')"
  if [ "$errors" = "[]" ]; then
    return 0
  fi
  printf '%s\n' "$errors" | jq -c '.[0]'
  return 1
}
