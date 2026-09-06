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

# Read-output boundary: budgets for what a read action returns inline in the
# conversation envelope, and the artifact contract for everything beyond it.
# - GH_INLINE_MAX_BYTES: data at or below this size is returned inline
#   unchanged.
# - GH_INLINE_MAX_ITEMS: once the byte boundary is exceeded, the inline view
#   keeps at most this many array items.
# Both can be overridden per invocation via the environment. The complete data
# is always saved to an artifact under gh_artifact_dir (survives the dispatcher
# exit); the envelope points to it via output_file and records what the inline
# view leaves out (truncated, total_count vs inline_count, omitted). Nothing
# is silently discarded.
GH_INLINE_MAX_BYTES="${GH_INLINE_MAX_BYTES:-20000}"
GH_INLINE_MAX_ITEMS="${GH_INLINE_MAX_ITEMS:-100}"

# Decide the conversation output of a read action from its full data on stdin.
#
#   bounded_read_output <artifact-prefix> <inline-jq-filter> [omitted-label]
#
# - Within GH_INLINE_MAX_BYTES: prints the input unchanged (the existing
#   inline contract, byte for byte).
# - Beyond it: saves the full input to an artifact file and prints a bounded
#   data object:
#     {items, truncated: true, total_count, inline_count, omitted,
#      output_file, size_bytes}
#   where items is the lightened inline view (inline-jq-filter applied to the
#   full data, arrays capped at GH_INLINE_MAX_ITEMS items). The item range
#   beyond inline_count and the fields named in omitted exist only in
#   output_file. For non-array data no generic cap applies; the inline filter
#   is responsible for keeping that view bounded.
bounded_read_output() {
  local prefix="${1:-output}"
  local inline_filter="${2:-.}"
  local omitted_label="${3:-}"

  local full
  full="$(gh_make_temp)"
  cat > "$full"

  local size_bytes
  size_bytes="$(stat -c%s "$full")"

  if [ "$size_bytes" -le "$GH_INLINE_MAX_BYTES" ]; then
    cat "$full"
    rm -f "$full"
    return 0
  fi

  local output_file
  output_file="$(mktemp -p "$(gh_artifact_dir)" "${prefix}-XXXXXX")"
  cp "$full" "$output_file"

  local total_count
  total_count="$(jq 'if type == "array" then length else null end' "$full")"

  local inline_file
  inline_file="$(gh_make_temp)"
  jq -c "$inline_filter" "$full" > "$inline_file"

  local inline_count
  inline_count="$(jq 'if type == "array" then length else null end' "$inline_file")"

  if [ "$inline_count" != "null" ] && [ "$inline_count" -gt "$GH_INLINE_MAX_ITEMS" ]; then
    jq -c ".[:$GH_INLINE_MAX_ITEMS]" "$inline_file" > "${inline_file}.sliced"
    mv "${inline_file}.sliced" "$inline_file"
    inline_count="$GH_INLINE_MAX_ITEMS"
  fi
  rm -f "$full"

  jq -nc \
    --argjson truncated true \
    --argjson total_count "$total_count" \
    --argjson inline_count "$inline_count" \
    --arg omitted "$omitted_label" \
    --arg output_file "$output_file" \
    --argjson size_bytes "$size_bytes" \
    --slurpfile items "$inline_file" \
    '{
      items: $items[0],
      truncated: $truncated,
      total_count: $total_count,
      inline_count: $inline_count,
      omitted: $omitted,
      output_file: $output_file,
      size_bytes: $size_bytes
    }'
  rm -f "$inline_file"
}
