#!/usr/bin/env bash
set -euo pipefail

GH_API_VERSION="2026-03-10"
GH_RETRY_MAX=3
GH_RETRY_BASE_DELAY=1

# Forwarded diagnostic bound: gh stderr is never transcribed into outputs
# verbatim. Everything emitted from captured stderr is redacted first and
# capped at GH_DIAG_MAX_BYTES bytes.
GH_DIAG_MAX_BYTES=500

# Redact secrets and bound the size of a gh stderr diagnostic so no raw
# stderr text is forwarded to callers. GitHub credential tokens, URL
# userinfo credentials, sensitive query parameters, and Authorization
# header values are replaced with [REDACTED]; the result is capped at
# GH_DIAG_MAX_BYTES bytes.
sanitize_diag() {
  sed -E \
    -e 's/(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/[REDACTED]/g' \
    -e 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e "s#([?&](access_token|client_secret|token|api_key|apikey|password|passwd|secret|auth)=)[^&[:space:]\"']+#\1[REDACTED]#g" \
    -e 's#(Authorization|authorization):[[:space:]]*.*#\1: [REDACTED]#g' \
    | head -c "${GH_DIAG_MAX_BYTES:-500}"
}

call_gh_api() {
  local endpoint="$1"
  local method="${2:-GET}"
  [ $# -ge 2 ] && shift 2 || shift $#

  local attempt=0
  local result="" exit_code="" diag=""
  local err_file

  while [ "$attempt" -lt "$GH_RETRY_MAX" ]; do
    attempt=$((attempt + 1))

    # gh writes API error bodies to stdout but the retryable signals
    # ("HTTP 503", "connection refused", rate-limit messages) to stderr,
    # so the failure judgment needs both streams. The success result stays
    # stdout-only: diagnostics are never mixed into the returned JSON.
    err_file="$(mktemp "${TMPDIR:-/tmp}/gh-api-stderr.XXXXXX")"
    result="$(gh api \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      -H "Accept: application/vnd.github+json" \
      --method "$method" \
      "$endpoint" \
      "$@" 2>"$err_file")" && exit_code=$? || exit_code=$?
    diag="$(cat "$err_file")"
    rm -f "$err_file"

    if [ "$exit_code" -eq 0 ]; then
      if [ -n "$diag" ]; then
        printf '%s\n' "$diag" | sanitize_diag >&2
      fi
      printf '%s\n' "$result"
      return 0
    fi

    if is_retryable "$(printf '%s\n%s' "$result" "$diag")" "$exit_code" && [ "$attempt" -lt "$GH_RETRY_MAX" ]; then
      local delay=$((GH_RETRY_BASE_DELAY * (2 ** (attempt - 1))))
      sleep "$delay"
      continue
    fi

    break
  done

  # Only the redacted, size-bounded diagnostic is forwarded on failure; the
  # stdout body is the fallback when gh produced no stderr at all. Unmatched
  # (unknown-outcome) failures are never auto-resent.
  if [ -n "$diag" ]; then
    printf '%s\n' "$diag" | sanitize_diag >&2
  elif [ -n "$result" ]; then
    printf '%s\n' "$result" | sanitize_diag >&2
  fi
  return "${exit_code:-1}"
}

call_gh_api_paginated() {
  local endpoint="$1"
  local jq_filter="$2"
  local per_page="${3:-100}"
  if [ $# -ge 3 ]; then
    shift 3
  elif [ $# -ge 2 ]; then
    shift 2
  else
    shift $#
  fi

  local page=1
  local tmpfile
  tmpfile="$(mktemp)"
  echo '[]' > "$tmpfile"

  while :; do
    local page_result
    page_result="$(call_gh_api "$endpoint" "GET" \
      -f "per_page=$per_page" \
      -f "page=$page" \
      "$@" 2>&1)" || {
      rm -f "$tmpfile"
      echo "$page_result" >&2
      return 1
    }

    if ! echo "$page_result" | jq -e 'type == "array"' >/dev/null 2>&1; then
      rm -f "$tmpfile"
      echo "Paginated endpoint returned a non-array response" >&2
      return 1
    fi

    local raw_count
    raw_count="$(echo "$page_result" | jq 'length')"

    local page_items
    page_items="$(echo "$page_result" | jq -c "$jq_filter")"

    if [ "$raw_count" -eq 0 ]; then
      break
    fi

    local combined
    combined="$(echo "$page_items" | jq -c --slurpfile old "$tmpfile" '$old[0] + .')"
    echo "$combined" > "$tmpfile"

    if [ "$raw_count" -lt "$per_page" ]; then
      break
    fi

    page=$((page + 1))
  done

  cat "$tmpfile"
  rm -f "$tmpfile"
}

is_retryable() {
  local output="$1"
  local exit_code="$2"

  if echo "$output" | grep -qiE 'rate limit|secondary rate limit'; then
    return 0
  fi

  if echo "$output" | grep -qiE 'HTTP 5[0-9][0-9]'; then
    return 0
  fi

  if echo "$output" | grep -qiE 'connection refused|timeout|could not resolve host|Temporary failure|curl.*(6|7|28|35)'; then
    return 0
  fi

  return 1
}
