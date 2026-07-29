#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local comment_id
  comment_id="$(jq -r '.comment_id' "$request_file")"

  local target
  target="$(resolve_target)" || {
    envelope_fail "review-comments.update" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/comments/$comment_id" 2>/dev/null)" || {
    envelope_fail "review-comments.update" "API_ERROR" "Failed to fetch review comment" false
    exit 1
  }

  local before_url
  before_url="$(echo "$before_state" | jq -r '.html_url // ""')"

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  local comment_target
  comment_target="$(jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$comment_id" \
    --arg url "$before_url" \
    '{
      type: $type, repository: $repo, id: $id, url: $url
    }')"

  echo "$before_state" | jq -j '.body // ""' > "$GH_TEMP_DIR/before-body-tmp"
  if cmp -s "$expected_body_file" "$GH_TEMP_DIR/before-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/before-body-tmp"
    gh_cleanup "$expected_body_file"
    local already_formatted
    already_formatted="$(echo "$before_state" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"
    envelope_already_applied "review-comments.update" "$comment_target" "$already_formatted"
    exit 0
  fi
  rm -f "$GH_TEMP_DIR/before-body-tmp"

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq '{body: .body}' "$request_file" > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/comments/$comment_id" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    gh_cleanup "$expected_body_file"
    envelope_fail "review-comments.update" "API_ERROR" "Failed to update review comment" false
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id res_url
  res_id="$(echo "$_res" | jq -r '.id')"
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/comments/$comment_id")" || {
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "review-comments.update" "$comment_target" "{}"
    exit 1
  }

  local after_id after_url
  after_id="$(echo "$after_state" | jq -r '.id')"
  after_url="$(echo "$after_state" | jq -r '.html_url // ""')"

  local triple_ok=true

  if [ "$res_id" != "$after_id" ]; then
    triple_ok=false
  fi

  if [ "$res_url" != "$after_url" ]; then
    triple_ok=false
  fi

  echo "$after_state" | jq -j '.body // ""' > "$GH_TEMP_DIR/after-body-tmp"
  if cmp -s "$expected_body_file" "$GH_TEMP_DIR/after-body-tmp" 2>/dev/null; then
    :
  else
    triple_ok=false
  fi
  rm -f "$GH_TEMP_DIR/after-body-tmp"

  gh_cleanup "$expected_body_file"

  if [ "$triple_ok" != "true" ]; then
    envelope_unknown_outcome "review-comments.update" "$comment_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{id, body, html_url, user: {login: .user.login}, created_at, updated_at, author_association}')"

  envelope_ok "review-comments.update" "$comment_target" "$formatted"
}

main "$@"
