#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_PATH%/*}
if [[ "$SCRIPT_DIR" == "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR=.
fi
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" && pwd)
GH_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
ACTIONS_JSON="$GH_DIR/actions.json"
ACTIONS_DIR="$GH_DIR/scripts/actions"
failed=0

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  shift
  while (($# > 0)); do
    printf '       %s\n' "$1"
    shift
  done
  failed=1
}

if [[ ! -f "$ACTIONS_JSON" ]]; then
  fail 'actions.json is present' "missing: $ACTIONS_JSON"
  exit "$failed"
fi

if ! jq -e '.actions | type == "array"' "$ACTIONS_JSON" >/dev/null 2>&1; then
  fail 'actions.json has a valid actions array'
  exit "$failed"
fi

mapfile -t action_names < <(jq -r '.actions[] | .name // empty' "$ACTIONS_JSON")

duplicate_names=$(jq -r '
  [.actions | group_by(.name)[] | select(length > 1) | (.[] | .name // "<empty>")] |
  unique |
  .[]
' "$ACTIONS_JSON")
if [[ -n "$duplicate_names" ]]; then
  duplicate_details=()
  while IFS= read -r name; do
    duplicate_details+=("duplicate action: $name")
  done <<< "$duplicate_names"
  fail 'actions.json action names are unique' "${duplicate_details[@]}"
else
  pass 'actions.json action names are unique'
fi

missing_fields=$(jq -r '
  .actions | to_entries[] |
  . as $entry |
  ["name", "description", "category", "permission"] |
  map(select((($entry.value[.] // "") | tostring | length) == 0)) |
  select(length > 0) |
  "\($entry.key + 1): \($entry.value.name // "<unnamed>") missing=\(join(", "))"
' "$ACTIONS_JSON")
if [[ -n "$missing_fields" ]]; then
  missing_details=()
  while IFS= read -r detail; do
    missing_details+=("$detail")
  done <<< "$missing_fields"
  fail 'actions.json required fields are present' "${missing_details[@]}"
else
  pass 'actions.json required fields are present'
fi

invalid_permissions=$(jq -r '
  .actions | to_entries[] |
  select(.value.permission != "read" and .value.permission != "write" and .value.permission != "sensitive-write") |
  "\(.key + 1): \(.value.name // "<unnamed>") permission=\(.value.permission // "<missing>")"
' "$ACTIONS_JSON")
if [[ -n "$invalid_permissions" ]]; then
  permission_details=()
  while IFS= read -r detail; do
    permission_details+=("$detail")
  done <<< "$invalid_permissions"
  fail 'actions.json permission values are valid' "${permission_details[@]}"
else
  pass 'actions.json permission values are valid'
fi

missing_scripts=()
for action_name in "${action_names[@]}"; do
  if [[ ! -f "$ACTIONS_DIR/$action_name.sh" ]]; then
    missing_scripts+=("missing script: $action_name.sh")
  fi
done

orphan_scripts=()
if [[ -d "$ACTIONS_DIR" ]]; then
  shopt -s nullglob
  script_paths=("$ACTIONS_DIR"/*.sh)
  for script_path in "${script_paths[@]}"; do
    script_name=${script_path##*/}
    script_name=${script_name%.sh}
    if ! jq -e --arg name "$script_name" '.actions[] | select(.name == $name)' "$ACTIONS_JSON" >/dev/null; then
      orphan_scripts+=("orphan script: $script_name.sh")
    fi
  done
else
  orphan_scripts+=("missing directory: $ACTIONS_DIR")
fi

if ((${#missing_scripts[@]} > 0 || ${#orphan_scripts[@]} > 0)); then
  fail 'actions.json and action scripts are in sync' "${missing_scripts[@]}" "${orphan_scripts[@]}"
else
  pass 'actions.json and action scripts are in sync'
fi

exit "$failed"
