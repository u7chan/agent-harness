#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local request_file="$1"

  local number comment_id
  number="$(jq -r '.number' "$request_file")"
  comment_id="$(jq -r '.comment_id // empty' "$request_file")"

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
    envelope_fail "comments.read" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local per_page
  per_page="$(jq -r '.per_page // 100' "$request_file")"

  local target
  target="$(resolve_target)" || {
    envelope_fail "comments.read" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local parent_data parent_type parent_url parent_api_url
  parent_data="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "comments.read" "API_ERROR" "Failed to fetch parent issue/PR" false
    exit 1
  }
  if echo "$parent_data" | jq -e '.pull_request != null' >/dev/null 2>&1; then
    parent_type="pull_request"
  else
    parent_type="issue"
  fi
  parent_url="$(echo "$parent_data" | jq -r '.html_url')"
  parent_api_url="$(echo "$parent_data" | jq -r '.url')"

  if [ -n "$comment_id" ]; then
    local result
    result="$(call_gh_api "repos/$owner_repo/issues/comments/$comment_id" 2>/dev/null)" || {
      envelope_fail "comments.read" "API_ERROR" "Failed to fetch comment" false
      exit 1
    }

    local comment_issue_url
    comment_issue_url="$(echo "$result" | jq -r '.issue_url // ""')"
    if [ "$comment_issue_url" != "$parent_api_url" ]; then
      envelope_fail "comments.read" "PARENT_MISMATCH" "Comment $comment_id does not belong to issue/PR $number (comment issue_url=$comment_issue_url, expected=$parent_api_url)" false
      exit 1
    fi

    local comment_target
    comment_target="$(jq -n \
      --arg type "issue_comment" \
      --arg repo "$owner_repo" \
      --argjson id "$comment_id" \
      --arg parent_type "$parent_type" \
      --argjson parent_number "$number" \
      --arg url "$(echo "$result" | jq -r '.html_url')" \
      '{
        type: $type,
        repository: $repo,
        id: $id,
        parent: {type: $parent_type, repository: $repo, number: $parent_number},
        url: $url
      }')"

    local formatted
    formatted="$(echo "$result" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"

    local wrapper
    wrapper="$(jq -n --argjson item "$formatted" '{item: $item}')"
    envelope_ok "comments.read" "$comment_target" "$wrapper"
  else
    local collection_target
    collection_target="$(jq -n \
      --arg type "$parent_type" \
      --arg repo "$owner_repo" \
      --argjson number "$number" \
      --arg url "$parent_url" \
      '{
        type: $type,
        repository: $repo,
        number: $number,
        url: $url
      }')"

    local raw_data
    raw_data="$(call_gh_api_paginated "repos/$owner_repo/issues/$number/comments" '[.[]]' "$per_page")" || {
      envelope_fail "comments.read" "API_ERROR" "Failed to list comments" false
      exit 1
    }

    local formatted
    formatted="$(echo "$raw_data" | jq '[.[] | {id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}]')"

    local wrapper
    wrapper="$(jq -n --argjson items "$formatted" '{items: $items}')"
    envelope_ok "comments.read" "$collection_target" "$wrapper"
  fi
}

main "$@"
