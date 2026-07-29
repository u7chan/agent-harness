#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number reply_to
  number="$(jq -r '.number' "$request_file")"
  reply_to="$(jq -r '.reply_to' "$request_file")"

  local target
  target="$(resolve_pr_target)" || {
    envelope_fail "review-comments.reply" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local actor
  actor="$(gh api user --jq '.login' 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "AUTH_ERROR" "Failed to resolve current user" false
    exit 1
  }

  local parent_data parent_api_url
  parent_data="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch pull request" false
    exit 1
  }
  parent_api_url="$(echo "$parent_data" | jq -r '.url')"

  local current
  current="$(call_gh_api "repos/$owner_repo/pulls/comments/$reply_to" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch reply-to review comment" false
    exit 1
  }

  local current_pr_url
  current_pr_url="$(echo "$current" | jq -r '.pull_request_url // ""')"
  if [ "$current_pr_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Comment $reply_to does not belong to PR $pr_number (pull_request_url=$current_pr_url, expected=$parent_api_url)" false
    exit 1
  fi

  local visited_file
  visited_file="$(gh_make_temp "visited-ids")"
  echo "[]" > "$visited_file"

  local root="$current"
  local root_id
  root_id="$(echo "$root" | jq -r '.id')"
  jq --argjson id "$root_id" '. + [$id]' "$visited_file" > "${visited_file}.tmp" && mv "${visited_file}.tmp" "$visited_file"

  local step=0
  local max_depth=50
  while :; do
    step=$((step + 1))
    if [ "$step" -gt "$max_depth" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Root comment resolution exceeded max depth ($max_depth)" false
      exit 1
    fi

    local parent_id
    parent_id="$(echo "$root" | jq -r '.in_reply_to_id // empty')"

    if [ -z "$parent_id" ]; then
      break
    fi

    local already_visited
    already_visited="$(jq --argjson pid "$parent_id" 'index($pid) != null' "$visited_file")"
    if [ "$already_visited" = "true" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Circular reference detected in comment thread at comment $parent_id" false
      exit 1
    fi

    jq --argjson pid "$parent_id" '. + [$pid]' "$visited_file" > "${visited_file}.tmp" && mv "${visited_file}.tmp" "$visited_file"

    root="$(call_gh_api "repos/$owner_repo/pulls/comments/$parent_id" 2>/dev/null)" || {
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch parent comment $parent_id during root resolution" false
      exit 1
    }
  done
  gh_cleanup "$visited_file"

  local root_pull_request_url
  root_pull_request_url="$(echo "$root" | jq -r '.pull_request_url // ""')"
  if [ "$root_pull_request_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Root comment belongs to PR $root_pull_request_url, not $parent_api_url" false
    exit 1
  fi

  local root_path root_commit_id root_line root_in_reply_to_id
  root_path="$(echo "$root" | jq -r '.path // empty')"
  root_commit_id="$(echo "$root" | jq -r '.commit_id // empty')"
  root_line="$(echo "$root" | jq -r '.line // empty')"
  root_in_reply_to_id="$(echo "$root" | jq -r '.in_reply_to_id // empty')"

  local inherit_path="$root_path"
  local inherit_commit_id="$root_commit_id"

  local effective_in_reply_to
  if [ -n "$root_in_reply_to_id" ]; then
    effective_in_reply_to="$root_in_reply_to_id"
  else
    effective_in_reply_to="$(echo "$root" | jq -r '.id')"
  fi

  if [ -z "$inherit_path" ]; then
    envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no path to inherit" false
    exit 1
  fi
  if [ -z "$inherit_commit_id" ]; then
    envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no commit_id to inherit" false
    exit 1
  fi

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

  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    gh_cleanup "$check_body_file"
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch existing review comments" false
    exit 1
  }

  local dedup
  dedup="$(echo "$existing" | jq -r \
    --rawfile b "$check_body_file" \
    --arg actor "$actor" \
    --argjson effective_in_reply_to "$effective_in_reply_to" \
    '
      first(.[] | select(
        .user.login == $actor and
        .body == $b and
        (.in_reply_to_id // 0) == ($effective_in_reply_to // 0)
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
    dedup_formatted="$(echo "$dedup" | jq '{id, body, html_url, path, line, commit_id, in_reply_to_id, user: {login: .user.login}, created_at, updated_at, author_association}')"
    envelope_already_applied "review-comments.reply" "$dedup_target" "$dedup_formatted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"

  local reply_body_tmp
  reply_body_tmp="$(gh_make_temp "reply-body-tmp")"
  jq -j '.body' "$request_file" > "$reply_body_tmp"

  jq -n \
    --rawfile b "$reply_body_tmp" \
    --arg commit_id "$inherit_commit_id" \
    --arg path "$inherit_path" \
    --argjson in_reply_to "$effective_in_reply_to" \
    '{body: $b, commit_id: $commit_id, path: $path, line: 1, in_reply_to: $in_reply_to}' > "$body_file"
  gh_cleanup "$reply_body_tmp"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/comments/$res_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }

  local verified_id
  verified_id="$(echo "$verified" | jq -r '.id')"
  if [ "$res_id" != "$verified_id" ]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  if [ "$res_url" != "$verified_url" ]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  if ! cmp -s "$expected_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$expected_body_file"

  local comment_target
  comment_target="$(jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$res_id" \
    --argjson parent_number "$pr_number" \
    --arg url "$verified_url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: "pull_request", repository: $repo, number: $parent_number},
      url: $url
    }')"

  local formatted
  formatted="$(echo "$verified" | jq '{id, body, html_url, path, line, commit_id, in_reply_to_id, user: {login: .user.login}, created_at, updated_at, author_association}')"

  envelope_ok "review-comments.reply" "$comment_target" "$formatted"
}

main "$@"
