#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"

  local state labels assignee milestone
  state="$(echo "$input" | jq -r '.state // "open"')"
  labels="$(echo "$input" | jq -r '.labels // empty')"
  assignee="$(echo "$input" | jq -r '.assignee // empty')"
  milestone="$(echo "$input" | jq -r '.milestone // empty')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.list" "TARGET_ERROR" "Failed to resolve target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local per_page
  per_page="$(echo "$input" | jq -r '.per_page // 30')"

  # Reject values outside the integer range 1..100 before any gh call. An
  # absent or explicit-null per_page keeps the default (existing null
  # contract: the dispatcher lets an optional null through and the action
  # applies its default).
  local per_page_valid
  per_page_valid="$(echo "$input" | jq -r '
    (has("per_page") | not) or
    (.per_page == null) or
    (
      (.per_page | type == "number") and
      (.per_page == (.per_page | floor)) and
      (.per_page >= 1) and
      (.per_page <= 100)
    )
  ')"
  if [ "$per_page_valid" != "true" ]; then
    envelope_fail "issue.list" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local filter_args=()
  filter_args+=(-f "state=$state")
  [ -n "$labels" ] && filter_args+=(-f "labels=$labels")
  [ -n "$assignee" ] && filter_args+=(-f "assignee=$assignee")
  [ -n "$milestone" ] && filter_args+=(-f "milestone=$milestone")

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/issues" '[.[]]' "$per_page" "${filter_args[@]}")" || {
    envelope_fail "issue.list" "API_ERROR" "Failed to list issues" false
    exit 1
  }

  local data
  data="$(echo "$raw_data" | jq -c '[.[] | select(.pull_request == null) | {id, number, title, state, html_url, user: {login: .user.login}, labels: [.labels[].name], assignees: [.assignees[].login], milestone: {title: .milestone.title}, comments, created_at, updated_at, closed_at}]')"

  envelope_ok "issue.list" "$target" "$data"
}

main "$@"
