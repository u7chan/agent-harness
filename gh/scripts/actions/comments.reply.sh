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
  target="$(resolve_target)" || {
    envelope_fail "comments.reply" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local actor
  actor="$(gh api user --jq '.login' 2>/dev/null)" || {
    envelope_fail "comments.reply" "AUTH_ERROR" "Failed to resolve current user" false
    exit 1
  }

  local parent_data parent_api_url
  parent_data="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "comments.reply" "API_ERROR" "Failed to fetch parent issue/PR" false
    exit 1
  }
  parent_api_url="$(echo "$parent_data" | jq -r '.url')"

  local original
  original="$(call_gh_api "repos/$owner_repo/issues/comments/$reply_to" 2>/dev/null)" || {
    envelope_fail "comments.reply" "API_ERROR" "Failed to fetch original comment" false
    exit 1
  }
  local original_url original_issue_url
  original_url="$(echo "$original" | jq -r '.html_url')"
  original_issue_url="$(echo "$original" | jq -r '.issue_url // ""')"

  if [ "$original_issue_url" != "$parent_api_url" ]; then
    envelope_fail "comments.reply" "REPLY_MISMATCH" "Comment $reply_to does not belong to issue/PR $number (issue_url=$original_issue_url, expected=$parent_api_url)" false
    exit 1
  fi

  local final_body_file
  final_body_file="$(gh_make_temp "final-body")"
  jq -j --arg url "$original_url" '"\("> Re: " + $url + "\n\n")" + .body' "$request_file" > "$final_body_file"

  local parent_type parent_url
  if echo "$parent_data" | jq -e '.pull_request != null' >/dev/null 2>&1; then
    parent_type="pull_request"
  else
    parent_type="issue"
  fi
  parent_url="$(echo "$parent_data" | jq -r '.html_url')"

  local parent_target
  parent_target="$(jq -n \
    --arg type "$parent_type" \
    --arg repo "$owner_repo" \
    --argjson number "$number" \
    --arg url "$parent_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/issues/$number/comments" '[.[]]' "100" 2>/dev/null)" || {
    gh_cleanup "$final_body_file"
    envelope_fail "comments.reply" "API_ERROR" "Failed to fetch existing comments" false
    exit 1
  }

  local dedup
  dedup="$(echo "$existing" | jq -r --rawfile b "$final_body_file" --arg actor "$actor" '
    first(.[] | select(.user.login == $actor and .body == $b))
  ' 2>/dev/null)" || dedup=""

  if [ -n "$dedup" ] && [ "$dedup" != "null" ]; then
    gh_cleanup "$final_body_file"
    local dedup_id dedup_url
    dedup_id="$(echo "$dedup" | jq -r '.id')"
    dedup_url="$(echo "$dedup" | jq -r '.html_url')"

    local dedup_target
    dedup_target="$(jq -n \
      --arg type "issue_comment" \
      --arg repo "$owner_repo" \
      --argjson id "$dedup_id" \
      --arg parent_type "$parent_type" \
      --argjson parent_number "$number" \
      --arg url "$dedup_url" \
      '{
        type: $type, repository: $repo, id: $id,
        parent: {type: $parent_type, repository: $repo, number: $parent_number},
        url: $url
      }')"

    local dedup_formatted
    dedup_formatted="$(echo "$dedup" | jq --arg reply_to_url "$original_url" '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association, native_thread: false, reply_to_url: $reply_to_url}')"
    envelope_already_applied "comments.reply" "$dedup_target" "$dedup_formatted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -n --rawfile b "$final_body_file" '{body: $b}' > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/issues/comments/$res_id" 2>/dev/null)" || {
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "{}"
    exit 1
  }

  local verified_id
  verified_id="$(echo "$verified" | jq -r '.id')"

  if [ "$res_id" != "$verified_id" ]; then
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "$verified"
    exit 1
  fi

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  if [ "$res_url" != "$verified_url" ]; then
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "$verified"
    exit 1
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "$verified"
    exit 1
  fi

  if ! cmp -s "$final_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$final_body_file"
    envelope_unknown_outcome "comments.reply" "$parent_target" "$verified"
    exit 1
  fi

  rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$final_body_file"

  local comment_target
  comment_target="$(jq -n \
    --arg type "issue_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$res_id" \
    --arg parent_type "$parent_type" \
    --argjson parent_number "$number" \
    --arg url "$verified_url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: $parent_type, repository: $repo, number: $parent_number},
      url: $url
    }')"

  local formatted
  formatted="$(echo "$verified" | jq \
    --arg reply_to_url "$original_url" \
    '{
      id, body, html_url,
      user: {login: .user.login},
      created_at, updated_at,
      author_association,
      native_thread: false,
      reply_to_url: $reply_to_url
    }')"

  envelope_ok "comments.reply" "$comment_target" "$formatted"
}

main "$@"
