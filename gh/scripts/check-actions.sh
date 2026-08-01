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
SKILL_MD="$GH_DIR/SKILL.md"
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

skill_actions=()
in_index=0
header_seen=0
index_ended=0
extract_action_cell() {
  local row=$1
  local cell=''
  local char=''
  local in_code=0
  local escaped=0
  local i
  local -a cells=()

  for ((i = 0; i < ${#row}; i++)); do
    char=${row:i:1}
    if ((in_code == 0 && escaped == 0)) && [[ "$char" == '\\' ]]; then
      cell+=$char
      escaped=1
    elif [[ "$char" == '`' ]]; then
      cell+=$char
      in_code=$((1 - in_code))
      escaped=0
    elif [[ "$char" == '|' ]] && ((in_code == 0 && escaped == 0)); then
      cells+=("$cell")
      cell=''
    else
      cell+=$char
      escaped=0
    fi
  done
  cells+=("$cell")
  printf '%s' "${cells[2]-}"
}

if [[ ! -f "$SKILL_MD" ]]; then
  fail 'SKILL.md Action Index is present and parseable' "missing: $SKILL_MD"
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]Action[[:space:]]Index[[:space:]]*$ ]]; then
      in_index=1
      continue
    fi
    if ((in_index == 1)) && [[ "$line" =~ ^##[[:space:]]Permission[[:space:]]*$ ]]; then
      index_ended=1
      break
    fi
    if ((in_index == 1 && header_seen == 0)); then
      if [[ -z "${line//[[:space:]]/}" ]]; then
        continue
      fi
      header_seen=1
      continue
    fi
    if ((in_index == 1)) && [[ "$line" == \|* ]]; then
      skill_action=$(extract_action_cell "$line")
      skill_action="${skill_action#"${skill_action%%[![:space:]]*}"}"
      skill_action="${skill_action%"${skill_action##*[![:space:]]}"}"
      if [[ -z "$skill_action" || "$skill_action" =~ ^-+$ ]]; then
        continue
      fi
      skill_action=${skill_action#'`'}
      skill_action=${skill_action%'`'}
      skill_action=${skill_action//\\|/|}
      skill_actions+=("$skill_action")
    fi
  done < "$SKILL_MD"

  if ((in_index == 0 || index_ended == 0 || header_seen == 0)); then
    fail 'SKILL.md Action Index is present and parseable'
    skill_actions=()
  else
    pass 'SKILL.md Action Index is present and parseable'
  fi
fi

index_orphans=()
for skill_action in "${skill_actions[@]}"; do
  if [[ -n "$skill_action" ]] && ! jq -e --arg name "$skill_action" '.actions[] | select(.name == $name)' "$ACTIONS_JSON" >/dev/null; then
    index_orphans+=("not in actions.json: $skill_action")
  fi
done
if ((${#index_orphans[@]} > 0)); then
  fail 'SKILL.md Action Index actions exist in actions.json' "${index_orphans[@]}"
else
  pass 'SKILL.md Action Index actions exist in actions.json'
fi

missing_index_actions=()
for action_name in "${action_names[@]}"; do
  found=0
  for skill_action in "${skill_actions[@]}"; do
    if [[ "$action_name" == "$skill_action" ]]; then
      found=1
      break
    fi
  done
  if ((found == 0)); then
    missing_index_actions+=("not in SKILL.md Action Index: $action_name")
  fi
done
if ((${#missing_index_actions[@]} > 0)); then
  fail 'actions.json actions are listed in SKILL.md Action Index' "${missing_index_actions[@]}"
else
  pass 'actions.json actions are listed in SKILL.md Action Index'
fi

exit "$failed"
