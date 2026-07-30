#!/usr/bin/env bash
set -euo pipefail

herdr_manifest_dir() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams"
}

herdr_manifest_lock_dir() {
  echo "$(herdr_manifest_dir)/locks"
}

herdr_manifest_path() {
  local team_id="$1"
  herdr_manifest_validate_id "$team_id" || return 1
  echo "$(herdr_manifest_dir)/${team_id}.json"
}

herdr_manifest_validate_id() {
  local value="${1:-}"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]
}

herdr_manifest_exists() {
  local team_id="$1"
  local path
  path="$(herdr_manifest_path "$team_id")" || return 1
  [ -f "$path" ]
}

herdr_manifest_read() {
  local team_id="$1"
  local path
  path="$(herdr_manifest_path "$team_id")"

  if [ ! -f "$path" ]; then
    echo '{}'
    return 1
  fi

  cat "$path"
}

herdr_manifest_write() {
  local team_id="$1"
  local manifest_json="$2"

  local dir
  dir="$(herdr_manifest_dir)"
  mkdir -p "$dir"

  jq -e . >/dev/null 2>&1 <<< "$manifest_json" || return 1

  local path
  path="$(herdr_manifest_path "$team_id")" || return 1
  local tmp_path
  tmp_path="$(mktemp "$dir/.${team_id}.json.XXXXXX")" || return 1

  if ! printf '%s\n' "$manifest_json" > "$tmp_path" || ! mv -f -- "$tmp_path" "$path"; then
    rm -f -- "$tmp_path"
    return 1
  fi
}

herdr_manifest_delete() {
  local team_id="$1"
  local path
  path="$(herdr_manifest_path "$team_id")"
  rm -f "$path"
}

herdr_manifest_lock() {
  local lock_id="$1"
  local timeout_sec="${2:-30}"
  local owner_token="${3:-}"

  herdr_manifest_validate_id "$lock_id" || return 1
  herdr_manifest_validate_id "$owner_token" || return 1
  [[ "$timeout_sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

  local lock_dir
  lock_dir="$(herdr_manifest_lock_dir)"
  mkdir -p "$lock_dir"

  local lock_key
  lock_key="$(printf '%s' "$lock_id" | sha256sum | cut -d' ' -f1)"
  local lock_file="$lock_dir/${lock_key}.lock"
  command -v flock >/dev/null 2>&1 || return 1
  local lock_fd
  exec {lock_fd}>"$lock_file" || return 1
  if ! flock -w "$timeout_sec" "$lock_fd"; then
    exec {lock_fd}>&-
    return 1
  fi

  printf '%s\n' "$owner_token" >&"$lock_fd"
  HERDR_MANIFEST_LOCK_FILE="$lock_file"
  HERDR_MANIFEST_LOCK_FD="$lock_fd"
  HERDR_MANIFEST_LOCK_OWNER="$owner_token"
}

herdr_manifest_unlock() {
  local lock_file="$1"
  local owner_token="${2:-}"
  [ -n "$lock_file" ] || return 0
  local lock_dir lock_parent lock_name
  lock_dir="$(herdr_manifest_lock_dir)"
  lock_parent="$(dirname -- "$lock_file")"
  lock_name="$(basename -- "$lock_file")"
  [ "$lock_parent" = "$lock_dir" ] || return 1
  [[ "$lock_name" =~ ^[0-9a-f]{64}\.lock$ ]] || return 1
  [ "${HERDR_MANIFEST_LOCK_FILE:-}" = "$lock_file" ] || return 1
  [ "${HERDR_MANIFEST_LOCK_OWNER:-}" = "$owner_token" ] || return 1
  local lock_fd="${HERDR_MANIFEST_LOCK_FD:-}"
  [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 1
  flock -u "$lock_fd" || return 1
  exec {lock_fd}>&-
  HERDR_MANIFEST_LOCK_FILE=""
  HERDR_MANIFEST_LOCK_FD=""
  HERDR_MANIFEST_LOCK_OWNER=""
}

herdr_manifest_now_ms() {
  local epoch_ns
  epoch_ns="$(date +%s%N 2>/dev/null || true)"
  if [[ "$epoch_ns" =~ ^[0-9]{10,19}$ ]]; then
    echo $((10#$epoch_ns / 1000000))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

herdr_manifest_list() {
  local dir
  dir="$(herdr_manifest_dir)"
  if [ ! -d "$dir" ]; then
    echo '[]'
    return 0
  fi

  local result="["
  local first=true
  local f
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if [ "$first" = true ]; then
      first=false
    else
      result+=","
    fi
    result+="$(cat "$f")"
  done
  result+="]"

  echo "$result" | jq -c '.'
}

herdr_manifest_list_names() {
  local dir
  dir="$(herdr_manifest_dir)"
  if [ ! -d "$dir" ]; then
    echo '[]'
    return 0
  fi

  ls "$dir"/*.json 2>/dev/null | while read -r f; do
    basename "$f" .json
  done | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

herdr_manifest_check_workspace() {
  local team_id="$1"
  local workspace_id="$2"

  local manifest
  manifest="$(herdr_manifest_read "$team_id")"

  if [ "$manifest" = "{}" ]; then
    return 1
  fi

  local bound_workspace
  bound_workspace="$(echo "$manifest" | jq -r '.workspace_id // ""')"

  if [ "$bound_workspace" != "$workspace_id" ]; then
    return 1
  fi

  return 0
}

herdr_get_workspace_id() {
  herdr pane current 2>/dev/null | jq -r '.result.pane.workspace_id // "unknown"' 2>/dev/null || echo "unknown"
}

herdr_manifest_find_by_request_id() {
  local request_id="$1"
  local workspace_id="${2:-}"
  herdr_manifest_validate_id "$request_id" || return 1
  local dir
  dir="$(herdr_manifest_dir)"
  if [ ! -d "$dir" ]; then
    echo ""
    return 0
  fi

  local f
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    local stored_id
    stored_id="$(jq -r --arg rid "$request_id" --arg workspace_id "$workspace_id" '
      select(.request_id == $rid and ($workspace_id == "" or .workspace_id == $workspace_id))
      | .team_id // ""
    ' "$f" 2>/dev/null || echo "")"
    if [ -n "$stored_id" ]; then
      echo "$stored_id"
      return 0
    fi
  done
  echo ""
}
