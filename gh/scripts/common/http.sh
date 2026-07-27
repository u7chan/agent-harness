#!/usr/bin/env bash
set -euo pipefail

GH_API_VERSION="2026-03-10"
GH_RETRY_MAX=3
GH_RETRY_BASE_DELAY=1

call_gh_api() {
  local endpoint="$1"
  local method="${2:-GET}"
  [ $# -ge 2 ] && shift 2 || shift $#

  local attempt=0
  local result exit_code

  while [ "$attempt" -lt "$GH_RETRY_MAX" ]; do
    attempt=$((attempt + 1))

    result="$(gh api \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      -H "Accept: application/vnd.github+json" \
      --method "$method" \
      "$endpoint" \
      "$@")" && exit_code=$? || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
      printf '%s\n' "$result"
      return 0
    fi

    if is_retryable "$result" "$exit_code" && [ "$attempt" -lt "$GH_RETRY_MAX" ]; then
      local delay=$((GH_RETRY_BASE_DELAY * (2 ** (attempt - 1))))
      sleep "$delay"
      continue
    fi

    break
  done

  printf '%s\n' "$result" >&2
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
