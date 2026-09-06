#!/usr/bin/env bash
set -euo pipefail

# Internal scratch directory used by the dispatcher and action scripts.
# Lifetime: owned by the dispatcher invocation. gh.sh creates it with a
# .gh-tmp-marker and removes the whole directory via its EXIT trap.
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

# Directory for artifact files returned to callers (see large_output).
# Lifetime: deliberately separate from the dispatcher's internal scratch. It is
# NOT removed by the dispatcher EXIT trap, so an output_file stays readable
# after gh.sh exits. Deletion responsibility: the caller deletes the returned
# file when done, e.g.
#   rm -f "$(printf '%s\n' "$result" | jq -r '.data.output_file')"
# GH_ARTIFACT_DIR overrides the save location (caller-owned; the dispatcher
# never cleans it up). The default is a per-invocation mktemp directory.
__GH_ARTIFACT_DIR=""

gh_artifact_dir() {
  if [ -n "$__GH_ARTIFACT_DIR" ]; then
    printf '%s\n' "$__GH_ARTIFACT_DIR"
    return
  fi
  if [ -n "${GH_ARTIFACT_DIR:-}" ]; then
    __GH_ARTIFACT_DIR="$GH_ARTIFACT_DIR"
  else
    __GH_ARTIFACT_DIR="$(mktemp -d /tmp/gh-artifacts-XXXXXX)"
  fi
  mkdir -p "$__GH_ARTIFACT_DIR"
  printf '%s\n' "$__GH_ARTIFACT_DIR"
}

large_output() {
  local prefix="${1:-output}"
  local file
  file="$(mktemp -p "$(gh_artifact_dir)" "${prefix}-XXXXXX")"
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
