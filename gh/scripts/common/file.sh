#!/usr/bin/env bash
set -euo pipefail

gh_temp_dir() {
  local dir="${GH_TEMP_DIR:-$(pwd)/.gh-tmp}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
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
  if [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
    rm -rf "$dir"/*
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
