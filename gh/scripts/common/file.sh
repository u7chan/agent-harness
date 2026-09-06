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
#   unchanged; beyond it, the inline view is also capped at this many bytes of
#   encoded items.
# - GH_INLINE_MAX_ITEMS: once the byte boundary is exceeded, the inline view
#   keeps at most this many array items.
# Both can be overridden per invocation via the environment. The complete data
# is always saved to an artifact under gh_artifact_dir (survives the dispatcher
# exit); the envelope points to it via output_file and records what the inline
# view leaves out (truncated, total_count vs inline_count, omitted). Nothing
# is silently discarded.
# Failure contract: every fallible step is checked explicitly because this
# function is called inside command substitutions, where set -e alone cannot
# stop the caller. A failed artifact save returns non-zero with nothing on
# stdout, so the caller reports an error instead of a truncated success.
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
#   full data, arrays capped at GH_INLINE_MAX_ITEMS items and at
#   GH_INLINE_MAX_BYTES bytes of encoded items, keeping the leading prefix).
#   The item range beyond inline_count and the fields named in omitted exist
#   only in output_file. For non-array data no generic cap applies; the
#   inline filter is responsible for keeping that view bounded.
# - Fails (non-zero, nothing on stdout) when the complete data cannot be
#   saved to the artifact or the inline view cannot be produced; the caller
#   must report the failure instead of a truncated result.
bounded_read_output() {
  local prefix="${1:-output}"
  local inline_filter="${2:-.}"
  local omitted_label="${3:-}"

  local full
  full="$(gh_make_temp)" || return 1
  cat > "$full" || { rm -f "$full"; return 1; }

  local size_bytes
  size_bytes="$(stat -c%s "$full")" || { rm -f "$full"; return 1; }

  if [ "$size_bytes" -le "$GH_INLINE_MAX_BYTES" ]; then
    cat "$full" || { rm -f "$full"; return 1; }
    rm -f "$full"
    return 0
  fi

  # The artifact must exist before any truncated result is reported: the
  # inline view omits data, so a failed save is an error, not a success.
  local artifact_dir
  artifact_dir="$(gh_artifact_dir)" || { rm -f "$full"; return 1; }

  local output_file
  output_file="$(mktemp -p "$artifact_dir" "${prefix}-XXXXXX")" || { rm -f "$full"; return 1; }
  if ! cp "$full" "$output_file"; then
    rm -f "$full" "$output_file"
    return 1
  fi

  local total_count
  total_count="$(jq 'if type == "array" then length else null end' "$full")" || { rm -f "$full"; return 1; }

  local inline_file
  inline_file="$(gh_make_temp)" || { rm -f "$full"; return 1; }
  if ! jq -c "$inline_filter" "$full" > "$inline_file"; then
    rm -f "$full" "$inline_file"
    return 1
  fi
  rm -f "$full"

  local inline_count
  inline_count="$(jq 'if type == "array" then length else null end' "$inline_file")" || { rm -f "$inline_file"; return 1; }

  if [ "$inline_count" != "null" ] && [ "$inline_count" -gt "$GH_INLINE_MAX_ITEMS" ]; then
    if ! jq -c ".[:$GH_INLINE_MAX_ITEMS]" "$inline_file" > "${inline_file}.sliced"; then
      rm -f "$inline_file" "${inline_file}.sliced"
      return 1
    fi
    mv "${inline_file}.sliced" "$inline_file" || { rm -f "$inline_file" "${inline_file}.sliced"; return 1; }
    inline_count="$GH_INLINE_MAX_ITEMS"
  fi

  # Cap the inline view by bytes as well as items: keep the leading prefix
  # whose encoded items fit in the budget. Exact accounting: the compact
  # array JSON is 1 + sum(item bytes + 1 separator byte).
  if [ "$inline_count" != "null" ]; then
    local inline_bytes
    inline_bytes="$(stat -c%s "$inline_file")" || { rm -f "$inline_file"; return 1; }
    if [ "$inline_bytes" -gt "$GH_INLINE_MAX_BYTES" ]; then
      if ! jq -c --argjson budget "$GH_INLINE_MAX_BYTES" '
        reduce .[] as $item (
          {items: [], used: 1, prefix: true};
          (($item | tostring | utf8bytelength) + 1) as $cost |
          if .prefix and ((.used + $cost) <= $budget)
          then {items: (.items + [$item]), used: (.used + $cost), prefix: true}
          else {items: .items, used: .used, prefix: false}
          end
        ) | .items' "$inline_file" > "${inline_file}.capped"; then
        rm -f "$inline_file" "${inline_file}.capped"
        return 1
      fi
      mv "${inline_file}.capped" "$inline_file" || { rm -f "$inline_file" "${inline_file}.capped"; return 1; }
      inline_count="$(jq 'length' "$inline_file")" || { rm -f "$inline_file"; return 1; }
    fi
  fi

  local emit_rc
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
  emit_rc=$?
  rm -f "$inline_file"
  return "$emit_rc"
}
