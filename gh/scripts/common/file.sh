#!/usr/bin/env bash
set -euo pipefail

__GH_TEMP_DIR=""

gh_temp_dir() {
  if [ -n "$__GH_TEMP_DIR" ]; then
    printf '%s\n' "$__GH_TEMP_DIR"
    return
  fi
  if [ -n "${GH_TEMP_DIR:-}" ]; then
    __GH_TEMP_DIR="$GH_TEMP_DIR"
  else
    __GH_TEMP_DIR="$(mktemp -d /tmp/gh-XXXXXX)"
  fi
  mkdir -p "$__GH_TEMP_DIR"
  printf '%s\n' "$__GH_TEMP_DIR"
}

gh_make_temp() {
  mktemp -p "$(gh_temp_dir)" "gh-XXXXXX"
}

gh_cleanup() {
  local file="$1"
  if [ -f "$file" ]; then
    rm -f "$file"
  fi
}

gh_cleanup_temp_dir() {
  local dir
  dir="$(gh_temp_dir)"
  if [ -d "$dir" ] && [ -f "$dir/.gh-tmp-marker" ]; then
    rm -rf "$dir"
  fi
}

large_output() {
  local prefix="${1:-output}"
  local file
  file="$(gh_make_temp)"
  cat > "$file"

  local size_bytes
  size_bytes="$(stat -c%s "$file")"

  jq -nc \
    --arg file "$file" \
    --argjson size "$size_bytes" \
    '{
      output_file: $file,
      size_bytes: $size
    }'
}
