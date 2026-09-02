#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number attachments_json
  number="$(jq -r '.number' "$request_file")"
  attachments_json="$(jq -c '.attachments // []' "$request_file")"

  local target
  target="$(resolve_target)" || {
    envelope_fail "comments.create" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local actor
  actor="$(gh api user --jq '.login' 2>/dev/null)" || {
    envelope_fail "comments.create" "AUTH_ERROR" "Failed to resolve current user" false
    exit 1
  }

  local parent_data
  parent_data="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "comments.create" "API_ERROR" "Failed to fetch parent issue/PR" false
    exit 1
  }
  local parent_type
  if echo "$parent_data" | jq -e '.pull_request != null' >/dev/null 2>&1; then
    parent_type="pull_request"
  else
    parent_type="issue"
  fi
  local parent_url
  parent_url="$(echo "$parent_data" | jq -r '.html_url')"

  local parent_target
  parent_target="$(jq -n \
    --arg type "$parent_type" \
    --arg repo "$owner_repo" \
    --argjson number "$number" \
    --arg url "$parent_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  if [ "$attachments_json" != "[]" ]; then
    # gh CLI subcommand path (--attach is CLI-only); non-interactive via
    # --body-file. Attachment dedup is impossible (uploaded URLs are opaque),
    # so the comment is always created and verified by read-back.
    source "$SCRIPT_DIR/../common/attach.sh"

    if ! attach_prepare "comments.create" "$attachments_json"; then
      exit 1
    fi

    local cli_body_file
    cli_body_file="$(gh_make_temp "cli-body")"
    jq -j '.body' "$request_file" > "$cli_body_file"

    local cli_args=()
    if [ "$parent_type" = "pull_request" ]; then
      cli_args=("pr" "comment" "$number" "--repo" "$owner_repo" "--body-file" "$cli_body_file")
    else
      cli_args=("issue" "comment" "$number" "--repo" "$owner_repo" "--body-file" "$cli_body_file")
    fi
    local _a
    for _a in "${ATTACH_FLAGS[@]}"; do
      cli_args+=(--attach "$_a")
    done

    local cli_out=""
    cli_out="$(gh "${cli_args[@]}" 2>"$GH_TEMP_DIR/gh-stderr")" || true
    gh_cleanup "$cli_body_file"

    local res_id
    res_id="$(printf '%s\n' "$cli_out" | grep -oE '#issuecomment-[0-9]+' | head -n1 | sed -E 's/^#issuecomment-//')" || res_id=""
    if [ -z "$res_id" ]; then
      envelope_unknown_outcome "comments.create" "$parent_target" "{}"
      exit 1
    fi

    local verified
    verified="$(call_gh_api "repos/$owner_repo/issues/comments/$res_id" 2>/dev/null)" || {
      envelope_unknown_outcome "comments.create" "$parent_target" "{}"
      exit 1
    }

    local verified_id
    verified_id="$(echo "$verified" | jq -r '.id')"
    if [ "$res_id" != "$verified_id" ]; then
      envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
      exit 1
    fi

    local res_url verified_url
    res_url="$(printf '%s\n' "$cli_out" | grep -oE 'https://github.com/[^ ]+' | head -n1)" || res_url=""
    verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
    if [ "$res_url" != "$verified_url" ]; then
      envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
      exit 1
    fi

    local expect_body_file verified_body_file
    expect_body_file="$(gh_make_temp "expect-body")"
    jq -j '.body' "$request_file" > "$expect_body_file"
    verified_body_file="$(gh_make_temp "verify-body")"
    echo "$verified" | jq -j '.body // ""' > "$verified_body_file"
    if ! attach_verify "$expect_body_file" "$verified_body_file"; then
      gh_cleanup "$expect_body_file"
      gh_cleanup "$verified_body_file"
      envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
      exit 1
    fi
    gh_cleanup "$expect_body_file"
    gh_cleanup "$verified_body_file"

    local comment_target
    comment_target="$(jq -n \
      --arg type "issue_comment" \
      --arg repo "$owner_repo" \
      --argjson id "$res_id" \
      --arg parent_type "$parent_type" \
      --argjson parent_number "$number" \
      --arg url "$res_url" \
      '{
        type: $type, repository: $repo, id: $id,
        parent: {type: $parent_type, repository: $repo, number: $parent_number},
        url: $url
      }')"

    local formatted
    formatted="$(echo "$verified" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"

    envelope_ok "comments.create" "$comment_target" "$formatted"
    exit 0
  fi

  local check_body_file
  check_body_file="$(gh_make_temp "check-body")"
  jq -j '.body' "$request_file" > "$check_body_file"

  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/issues/$number/comments" '[.[]]' "100" 2>/dev/null)" || {
    gh_cleanup "$check_body_file"
    envelope_fail "comments.create" "API_ERROR" "Failed to fetch existing comments" false
    exit 1
  }

  local dedup
  dedup="$(echo "$existing" | jq -r --rawfile b "$check_body_file" --arg actor "$actor" '
    first(.[] | select(.user.login == $actor and .body == $b))
  ' 2>/dev/null)" || dedup=""
  gh_cleanup "$check_body_file"

  if [ -n "$dedup" ] && [ "$dedup" != "null" ]; then
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
    dedup_formatted="$(echo "$dedup" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"
    envelope_already_applied "comments.create" "$dedup_target" "$dedup_formatted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq '{body: .body}' "$request_file" > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "comments.create" "$parent_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/issues/comments/$res_id" 2>/dev/null)" || {
    envelope_unknown_outcome "comments.create" "$parent_target" "{}"
    exit 1
  }

  local verified_id
  verified_id="$(echo "$verified" | jq -r '.id')"

  if [ "$res_id" != "$verified_id" ]; then
    envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
    exit 1
  fi

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  if [ "$res_url" != "$verified_url" ]; then
    envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
    exit 1
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/res-body-tmp"

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  if ! cmp -s "$expected_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "comments.create" "$parent_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$expected_body_file"

  local comment_target
  comment_target="$(jq -n \
    --arg type "issue_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$res_id" \
    --arg parent_type "$parent_type" \
    --argjson parent_number "$number" \
    --arg url "$res_url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: $parent_type, repository: $repo, number: $parent_number},
      url: $url
    }')"

  local formatted
  formatted="$(echo "$verified" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"

  envelope_ok "comments.create" "$comment_target" "$formatted"
}

main "$@"
