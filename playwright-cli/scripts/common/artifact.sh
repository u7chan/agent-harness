#!/usr/bin/env bash
set -euo pipefail

# True when every component of the path (root to leaf) is symlink-free and the
# path stays inside the canonical artifact root. Never follows symlinks.
pw_artifact_path_symlink_free() {
  local path="$1"
  local root
  root="$(pw_artifact_root)"
  case "$path" in
    "$root/"*) ;;
    *) return 1 ;;
  esac
  pw_reject_symlinks "$path"
}

# Compute a unique artifact path under the artifact root.
# Path: artifacts/<session>/<request_id_or_read>/<seq>-<kind>.<ext>
pw_new_artifact_path() {
  local session="$1"
  local request_segment="$2"
  local kind="$3"
  local ext="$4"
  local session_dir
  session_dir="$(pw_artifact_sanitize_segment "$session")"
  local req_dir
  req_dir="$(pw_artifact_sanitize_segment "$request_segment")"
  local base="$PWD/.playwright-cli/agent-harness/artifacts/$session_dir/$req_dir"
  pw_reject_symlinks "$base" || return 1
  pw_ensure_dir "$base"
  local seq=1
  local candidate
  while :; do
    candidate="$base/$(printf '%03d' "$seq")-$kind.$ext"
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    seq=$((seq + 1))
  done
}

pw_artifact_id() {
  local path="$1"
  basename "$path"
}

pw_artifact_metadata() {
  local path="$1" kind="$2" media_type="$3" sensitive="$4"
  pw_artifact_path_symlink_free "$path" || return 1
  local size_bytes sha256
  size_bytes="$(stat -c%s "$path")"
  sha256="$(sha256sum -b "$path" | cut -d' ' -f1)"
  local relative
  relative="${path#$PWD/}"
  jq -nc \
    --arg id "$(basename "$path")" \
    --arg kind "$kind" \
    --arg relative "$relative" \
    --argjson size "$size_bytes" \
    --arg sha256 "$sha256" \
    --arg media_type "$media_type" \
    --argjson sensitive "$sensitive" \
    '{id: $id, kind: $kind, relative_path: $relative, size_bytes: $size, sha256: $sha256, media_type: $media_type, sensitive: $sensitive, retention: "caller-managed"}'
}

# Write a stream to a runtime-generated artifact path. Never overwrites.
pw_artifact_store() {
  local session="$1" request_segment="$2" kind="$3" ext="$4" media_type="$5" sensitive="$6"
  local path
  path="$(pw_new_artifact_path "$session" "$request_segment" "$kind" "$ext")" || return 1
  pw_reject_symlinks "$(dirname "$path")" || return 1
  umask 077
  cat > "$path"
  chmod 0600 "$path"
  pw_artifact_metadata "$path" "$kind" "$media_type" "$sensitive"
}

# Remove an artifact file if it exists (partial artifact cleanup). Refuses to
# follow symlinks anywhere in the path, so it can never reach outside the
# canonical artifact tree.
pw_artifact_remove() {
  local path="$1"
  [ -n "$path" ] || return 0
  [ -e "$path" ] || return 0
  [ ! -L "$path" ] || return 0
  pw_reject_symlinks "$(dirname "$path")" || return 0
  rm -f "$path"
}

pw_artifact_cleanup_dir() {
  local session="$1" request_segment="$2"
  local session_dir req_dir
  session_dir="$(pw_artifact_sanitize_segment "$session")"
  req_dir="$(pw_artifact_sanitize_segment "$request_segment")"
  local dir="$PWD/.playwright-cli/agent-harness/artifacts/$session_dir/$req_dir"
  [ -d "$dir" ] || return 0
  pw_reject_symlinks "$dir" || return 0
  rm -f "$dir"/* 2>/dev/null || true
}
