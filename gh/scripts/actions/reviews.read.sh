#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local request_file="$1"

  local number review_id
  number="$(jq -r '.number' "$request_file")"
  review_id="$(jq -r '.review_id // empty' "$request_file")"

  local per_page_valid
  per_page_valid="$(jq -r '
    (has("per_page") | not) or
    (
      (.per_page | type == "number") and
      (.per_page == (.per_page | floor)) and
      (.per_page >= 1) and
      (.per_page <= 100)
    )
  ' "$request_file")"
  if [ "$per_page_valid" != "true" ]; then
    envelope_fail "reviews.read" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local per_page
  per_page="$(jq -r '.per_page // 100' "$request_file")"

  local target
  target="$(resolve_pr_target)" || {
    envelope_fail "reviews.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  if [ -n "$review_id" ]; then
    local result
    result="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews/$review_id" 2>/dev/null)" || {
      envelope_fail "reviews.read" "API_ERROR" "Failed to fetch review" false
      exit 1
    }

    local review_target
    review_target="$(jq -n \
      --arg type "review" \
      --arg repo "$owner_repo" \
      --argjson id "$review_id" \
      --argjson parent_number "$pr_number" \
      --arg url "$(echo "$result" | jq -r '.html_url // ""')" \
      '{
        type: $type,
        repository: $repo,
        id: $id,
        parent: {type: "pull_request", repository: $repo, number: $parent_number},
        url: $url
      }')"

    local formatted
    formatted="$(echo "$result" | jq '{id, state, body, html_url, user: {login: .user.login}, submitted_at, commit_id, comments_count: (.body_text // "" | length)}')"

    local wrapper
    wrapper="$(jq -n --argjson item "$formatted" '{item: $item}')"
    envelope_ok "reviews.read" "$review_target" "$wrapper"
  else
    local collection_target
    collection_target="$(jq -n \
      --arg type "pull_request" \
      --arg repo "$owner_repo" \
      --argjson number "$pr_number" \
      --arg url "$pr_url" \
      '{
        type: $type,
        repository: $repo,
        number: $number,
        url: $url
      }')"

    local raw_data
    raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/reviews" '[.[]]' "$per_page")" || {
      envelope_fail "reviews.read" "API_ERROR" "Failed to list reviews" false
      exit 1
    }

    local formatted
    formatted="$(echo "$raw_data" | jq '[.[] | {id, state, body, html_url, user: {login: .user.login}, submitted_at, commit_id, comments_count: (.body_text // "" | length)}]')"

    local wrapper
    wrapper="$(jq -n --argjson items "$formatted" '{items: $items}')"
    envelope_ok "reviews.read" "$collection_target" "$wrapper"
  fi
}

main "$@"
