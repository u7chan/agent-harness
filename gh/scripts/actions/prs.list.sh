#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"

  local state head base sort_dir direction per_page
  state="$(echo "$input" | jq -r '.state // "open"')"
  head="$(echo "$input" | jq -r '.head // empty')"
  base="$(echo "$input" | jq -r '.base // empty')"
  sort_dir="$(echo "$input" | jq -r '.sort // "created"')"
  direction="$(echo "$input" | jq -r '.direction // "desc"')"
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
    envelope_fail "prs.list" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local target
  target="$(resolve_target)" || {
    envelope_fail "prs.list" "TARGET_ERROR" "Failed to resolve target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local filter_args=()
  filter_args+=(-f "state=$state")
  filter_args+=(-f "sort=$sort_dir")
  filter_args+=(-f "direction=$direction")
  [ -n "$head" ] && filter_args+=(-f "head=$head")
  [ -n "$base" ] && filter_args+=(-f "base=$base")

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls" '[.[]]' "$per_page" "${filter_args[@]}")" || {
    envelope_fail "prs.list" "API_ERROR" "Failed to list PRs" false
    exit 1
  }

  local data
  data="$(echo "$raw_data" | jq -c '[.[] | {
    id, number, title, state, html_url, draft,
    user: {login: .user.login},
    labels: [.labels[].name],
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}},
    created_at, updated_at
  }]')"

  envelope_ok "prs.list" "$target" "$data"
}

main "$@"
