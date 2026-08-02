#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number commit_id path
  number="$(jq -r '.number' "$request_file")"
  commit_id="$(jq -r '.commit_id' "$request_file")"
  path="$(jq -r '.path' "$request_file")"

  local target
  target="$(resolve_pr_target "" "$number")" || {
    envelope_fail "review-comments.create" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local actor
  actor="$(gh api user --jq '.login' 2>/dev/null)" || {
    envelope_fail "review-comments.create" "AUTH_ERROR" "Failed to resolve current user" false
    exit 1
  }

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  local check_body_file
  check_body_file="$(gh_make_temp "check-body")"
  jq -j '.body' "$request_file" > "$check_body_file"

  local position side start_line start_side
  position="$(jq -r '.position // empty' "$request_file")"
  side="$(jq -r '.side // empty' "$request_file")"
  start_line="$(jq -r '.start_line // empty' "$request_file")"
  start_side="$(jq -r '.start_side // empty' "$request_file")"

  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    gh_cleanup "$check_body_file"
    envelope_fail "review-comments.create" "API_ERROR" "Failed to fetch existing review comments" false
    exit 1
  }

  local dedup
  dedup="$(echo "$existing" | jq -r \
    --rawfile b "$check_body_file" \
    --arg actor "$actor" \
    --arg commit_id "$commit_id" \
    --arg path "$path" \
    --argjson position "$position" \
    --arg side "$side" \
    --arg start_line "$start_line" \
    --arg start_side "$start_side" \
    '
      first(.[] | select(
        .user.login == $actor and
        .body == $b and
        .path == $path and
        .commit_id == $commit_id and
        (.position // 0) == ($position // 0) and
        ((.side // "") == $side) and
        ((.start_line // "") | tostring) == $start_line and
        ((.start_side // "") == $start_side)
      ))
    ' 2>/dev/null)" || dedup=""
  gh_cleanup "$check_body_file"

  if [ -n "$dedup" ] && [ "$dedup" != "null" ]; then
    local dedup_id dedup_url
    dedup_id="$(echo "$dedup" | jq -r '.id')"
    dedup_url="$(echo "$dedup" | jq -r '.html_url')"

    local dedup_target
    dedup_target="$(jq -n \
      --arg type "review_comment" \
      --arg repo "$owner_repo" \
      --argjson id "$dedup_id" \
      --argjson parent_number "$pr_number" \
      --arg url "$dedup_url" \
      '{
        type: $type, repository: $repo, id: $id,
        parent: {type: "pull_request", repository: $repo, number: $parent_number},
        url: $url
      }')"

    local dedup_formatted
    dedup_formatted="$(echo "$dedup" | jq '{id, body, html_url, path, position, line, commit_id, in_reply_to_id, user: {login: .user.login}, created_at, updated_at, author_association}')"
    envelope_already_applied "review-comments.create" "$dedup_target" "$dedup_formatted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq '{body: .body, commit_id: .commit_id, path: .path, position: .position}' "$request_file" > "$body_file"
  local side
  side="$(jq -r '.side // empty' "$request_file")"
  if [ -n "$side" ]; then
    jq --arg side "$side" '. + {side: $side}' "$body_file" > "${body_file}.tmp" && mv "${body_file}.tmp" "$body_file"
  fi
  local start_line
  start_line="$(jq -r '.start_line // empty' "$request_file")"
  if [ -n "$start_line" ]; then
    jq --argjson sl "$start_line" '. + {start_line: $sl}' "$body_file" > "${body_file}.tmp" && mv "${body_file}.tmp" "$body_file"
  fi
  local start_side
  start_side="$(jq -r '.start_side // empty' "$request_file")"
  if [ -n "$start_side" ]; then
    jq --arg ss "$start_side" '. + {start_side: $ss}' "$body_file" > "${body_file}.tmp" && mv "${body_file}.tmp" "$body_file"
  fi
  local start_line

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "review-comments.create" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/comments/$res_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.create" "$pr_target" "{}"
    exit 1
  }

  local verified_id
  verified_id="$(echo "$verified" | jq -r '.id')"

  if [ "$res_id" != "$verified_id" ]; then
    envelope_unknown_outcome "review-comments.create" "$pr_target" "$verified"
    exit 1
  fi

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  if [ "$res_url" != "$verified_url" ]; then
    envelope_unknown_outcome "review-comments.create" "$pr_target" "$verified"
    exit 1
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    envelope_unknown_outcome "review-comments.create" "$pr_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/res-body-tmp"

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  if ! cmp -s "$expected_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "review-comments.create" "$pr_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$expected_body_file"

  local comment_target
  comment_target="$(jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$res_id" \
    --argjson parent_number "$pr_number" \
    --arg url "$res_url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: "pull_request", repository: $repo, number: $parent_number},
      url: $url
    }')"

  local formatted
  formatted="$(echo "$verified" | jq '{id, body, html_url, path, position, line, commit_id, in_reply_to_id, user: {login: .user.login}, created_at, updated_at, author_association}')"

  envelope_ok "review-comments.create" "$comment_target" "$formatted"
}

main "$@"
