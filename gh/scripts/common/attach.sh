#!/usr/bin/env bash
set -euo pipefail

# Shared deterministic processing for the gh CLI `--attach` feature
# (gh >= 2.99.0, github.com only). Sourced by write action scripts when the
# input carries a non-empty `attachments` array.
#
# Responsibilities (see _docs/architecture.md):
#   - gate validation: gh version, host, attachment count;
#   - attachment path validation (security boundary): extension allow-list,
#     existence, emptiness, size limits, duplicates;
#   - `--attach` argv assembly (path strings preserved verbatim, resolved
#     against the calling process CWD);
#   - post-write body verification (uploaded URLs are opaque, so exact
#     comparison is impossible; only decidable invariants are checked).

ATTACH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ATTACH_DIR/../common/auth.sh"
source "$ATTACH_DIR/../common/envelope.sh"

ATTACH_MIN_GH_VERSION="2.99.0"
ATTACH_MAX_COUNT=50
ATTACH_IMAGE_EXTENSIONS="png jpg jpeg gif webp svg"
ATTACH_VIDEO_EXTENSIONS="mp4 mov webm"
ATTACH_IMAGE_MAX_BYTES=$((10 * 1024 * 1024))
ATTACH_VIDEO_MAX_BYTES=$((100 * 1024 * 1024))

# Assembled by attach_prepare: ATTACH_FLAGS holds the verbatim 'path#alt'
# items for `--attach` flags; ATTACH_PATHS holds the verbatim paths used by
# attach_verify.
ATTACH_FLAGS=()
ATTACH_PATHS=()

attach_version_ge() {
  local current="$1"
  local minimum="$2"

  [ "$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)" = "$minimum" ]
}

# Read byte sizes using the GNU stat interface. Reject missing/incompatible
# tools and malformed output instead of letting an empty size bypass a limit.
attach_file_size() {
  local size
  size="$(stat -c%s "$1" 2>/dev/null)" || return 1
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$size"
}

# attach_gate <action> <count>
# Tool capability / gh CLI / host / count gates. On violation prints
# envelope_fail (MISSING_DEPENDENCY or ATTACH_UNSUPPORTED) and returns 1.
attach_gate() {
  local action="$1"
  local count="$2"

  # Check only the required interfaces; never select a package-manager path
  # or change PATH here. Linux/WSL keep their existing command resolution.
  local sorted
  sorted="$(printf '%s\n' '2.10.0' '2.9.0' | sort -V 2>/dev/null)" || sorted=""
  if [ "$sorted" != $'2.9.0\n2.10.0' ]; then
    envelope_fail "$action" "MISSING_DEPENDENCY" \
      "Attachments require sort -V (GNU coreutils); provide compatible tools on the harness process PATH" false
    return 1
  fi
  if ! attach_file_size "$ATTACH_DIR/attach.sh" >/dev/null; then
    envelope_fail "$action" "MISSING_DEPENDENCY" \
      "Attachments require stat -c%s (GNU coreutils); provide compatible tools on the harness process PATH" false
    return 1
  fi

  local version
  version="$(gh --version 2>/dev/null | head -n1 | awk '{print $3}')" || version=""
  if ! attach_version_ge "${version:-0}" "$ATTACH_MIN_GH_VERSION"; then
    envelope_fail "$action" "ATTACH_UNSUPPORTED" \
      "Attachments require gh >= $ATTACH_MIN_GH_VERSION (installed: ${version:-unknown})" false
    return 1
  fi

  local host
  host="$(get_host 2>/dev/null || true)"
  if [ "$host" != "github.com" ]; then
    envelope_fail "$action" "ATTACH_UNSUPPORTED" \
      "Attachments require the github.com host (current: ${host:-unknown})" false
    return 1
  fi

  if [ "$count" -gt "$ATTACH_MAX_COUNT" ]; then
    envelope_fail "$action" "ATTACH_UNSUPPORTED" \
      "Attachments support at most $ATTACH_MAX_COUNT files per command (got $count)" false
    return 1
  fi

  return 0
}

# attach_prepare <action> <attachments_json>
# Validates the attachments array and fills ATTACH_FLAGS / ATTACH_PATHS.
# On violation prints envelope_fail (MISSING_DEPENDENCY / ATTACH_UNSUPPORTED
# for gates, ATTACH_INVALID for path validation) and returns 1.
attach_prepare() {
  local action="$1"
  local attachments_json="$2"

  ATTACH_FLAGS=()
  ATTACH_PATHS=()

  local count
  count="$(echo "$attachments_json" | jq 'length')"

  attach_gate "$action" "$count" || return 1

  local i item item_type path alt ext ext_lower kind size prev
  for i in $(seq 0 $((count - 1))); do
    item_type="$(echo "$attachments_json" | jq -r ".[$i] | type")"
    if [ "$item_type" != "string" ]; then
      envelope_fail "$action" "ATTACH_INVALID" \
        "Attachment items must be strings of the form 'path#alt'" false
      return 1
    fi

    item="$(echo "$attachments_json" | jq -r ".[$i]")"
    if [[ "$item" == *"#"* ]]; then
      path="${item%%#*}"
      alt="${item#*#}"
    else
      path="$item"
      alt=""
    fi

    if [ -z "$path" ]; then
      envelope_fail "$action" "ATTACH_INVALID" "Attachment path must not be empty" false
      return 1
    fi

    ext="${path##*.}"
    ext_lower="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    kind=""
    case " $ATTACH_IMAGE_EXTENSIONS " in
      *" $ext_lower "*) kind="image" ;;
    esac
    case " $ATTACH_VIDEO_EXTENSIONS " in
      *" $ext_lower "*) kind="video" ;;
    esac
    if [ -z "$kind" ]; then
      envelope_fail "$action" "ATTACH_INVALID" \
        "Unsupported attachment extension: $ext_lower (allowed: png jpg jpeg gif webp svg mp4 mov webm)" false
      return 1
    fi

    if [ "$kind" = "video" ] && [ -n "$alt" ]; then
      envelope_fail "$action" "ATTACH_INVALID" \
        "Video attachments do not support alt text: $path" false
      return 1
    fi

    if [ ! -f "$path" ]; then
      envelope_fail "$action" "ATTACH_INVALID" "Attachment file does not exist: $path" false
      return 1
    fi
    if [ ! -s "$path" ]; then
      envelope_fail "$action" "ATTACH_INVALID" "Attachment file is empty: $path" false
      return 1
    fi

    size="$(attach_file_size "$path")" || {
      envelope_fail "$action" "ATTACH_INVALID" "Could not determine attachment size: $path" false
      return 1
    }
    if [ "$kind" = "image" ] && [ "$size" -gt "$ATTACH_IMAGE_MAX_BYTES" ]; then
      envelope_fail "$action" "ATTACH_INVALID" \
        "Image attachment exceeds the 10 MB limit: $path" false
      return 1
    fi
    if [ "$kind" = "video" ] && [ "$size" -gt "$ATTACH_VIDEO_MAX_BYTES" ]; then
      envelope_fail "$action" "ATTACH_INVALID" \
        "Video attachment exceeds the 100 MB limit: $path" false
      return 1
    fi

    # Bash 3.2 treats an empty array as unset under nounset. The + expansion
    # preserves each path verbatim and yields zero arguments for an empty array.
    for prev in ${ATTACH_PATHS[@]+"${ATTACH_PATHS[@]}"}; do
      if [ "$prev" = "$path" ]; then
        envelope_fail "$action" "ATTACH_INVALID" "Duplicate attachment: $path" false
        return 1
      fi
    done

    ATTACH_PATHS+=("$path")
    ATTACH_FLAGS+=("$item")
  done

  return 0
}

# attach_verify <expected_body_file> <fetched_body_file>
# Post-write body verification using ATTACH_PATHS:
#   - every attachment path referenced in the expected body must no longer
#     appear in the fetched body (gh rewrote the references to URLs);
#   - when unreferenced attachments exist, the expected body must be an exact
#     prefix of the fetched body and the fetched body must be longer
#     (unreferenced attachments are appended).
# Returns 0 on success, 1 on mismatch (callers report unknown_outcome).
attach_verify() {
  local expected_body_file="$1"
  local fetched_body_file="$2"

  local unreferenced=0 path expected_size fetched_size

  for path in ${ATTACH_PATHS[@]+"${ATTACH_PATHS[@]}"}; do
    if grep -Fq -- "$path" "$expected_body_file"; then
      if grep -Fq -- "$path" "$fetched_body_file"; then
        echo "attachment reference was not rewritten: $path" >&2
        return 1
      fi
    else
      unreferenced=1
    fi
  done

  if [ "$unreferenced" = "1" ]; then
    expected_size="$(attach_file_size "$expected_body_file")" || return 1
    fetched_size="$(attach_file_size "$fetched_body_file")" || return 1
    if [ "$fetched_size" -le "$expected_size" ]; then
      echo "appended attachments are missing from the stored body" >&2
      return 1
    fi
    if ! head -c "$expected_size" "$fetched_body_file" | cmp -s - "$expected_body_file"; then
      echo "stored body does not start with the submitted body" >&2
      return 1
    fi
  fi

  return 0
}