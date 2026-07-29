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
  echo "$(herdr_manifest_dir)/${team_id}.json"
}

herdr_manifest_exists() {
  local team_id="$1"
  [ -f "$(herdr_manifest_path "$team_id")" ]
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

  local path
  path="$(herdr_manifest_path "$team_id")"
  local tmp_path="${path}.tmp.$$"

  echo "$manifest_json" > "$tmp_path"
  mv "$tmp_path" "$path"
}

herdr_manifest_delete() {
  local team_id="$1"
  local path
  path="$(herdr_manifest_path "$team_id")"
  rm -f "$path"
}

herdr_manifest_lock() {
  local team_id="$1"
  local timeout_sec="${2:-30}"

  local lock_dir
  lock_dir="$(herdr_manifest_lock_dir)"
  mkdir -p "$lock_dir"

  local lock_file="$lock_dir/${team_id}.lock"

  local waited=0
  while ! mkdir "$lock_file" 2>/dev/null; do
    if [ "$waited" -ge "$timeout_sec" ]; then
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done

  echo "$lock_file"
}

herdr_manifest_unlock() {
  local lock_file="$1"
  if [ -n "$lock_file" ] && [ -d "$lock_file" ]; then
    rmdir "$lock_file" 2>/dev/null || true
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
    stored_id="$(jq -r --arg rid "$request_id" 'select(.request_id == $rid) | .team_id // ""' "$f" 2>/dev/null || echo "")"
    if [ -n "$stored_id" ]; then
      echo "$stored_id"
      return 0
    fi
  done
  echo ""
}
