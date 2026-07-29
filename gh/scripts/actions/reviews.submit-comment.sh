#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number review_id
  number="$(jq -r '.number' "$request_file")"
  review_id="$(jq -r '.review_id' "$request_file")"

  local event
  event="$(jq -r '.event // "COMMENT"' "$request_file")"
  if [ "$event" != "COMMENT" ]; then
    envelope_fail "reviews.submit-comment" "INVALID_PARAMETER" "Only event=COMMENT is allowed." false
    exit 1
  fi

  local target
  target="$(resolve_pr_target)" || {
    envelope_fail "reviews.submit-comment" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local review_before
  review_before="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews/$review_id" 2>/dev/null)" || {
    envelope_fail "reviews.submit-comment" "API_ERROR" "Failed to fetch review $review_id" false
    exit 1
  }

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  local before_state before_body
  before_state="$(echo "$review_before" | jq -r '.state // empty')"
  before_body="$(echo "$review_before" | jq -j '.body // ""')"

  if [ "$before_state" != "PENDING" ]; then
    local before_body_file
    before_body_file="$(gh_make_temp "before-body")"
    echo "$before_body" > "$before_body_file"

    if cmp -s "$expected_body_file" "$before_body_file" 2>/dev/null; then
      gh_cleanup "$expected_body_file"
      gh_cleanup "$before_body_file"

      local dedup_target
      dedup_target="$(jq -n \
        --arg type "review" \
        --arg repo "$owner_repo" \
        --argjson id "$review_id" \
        --argjson parent_number "$pr_number" \
        --arg url "$(echo "$review_before" | jq -r '.html_url // ""')" \
        '{
          type: $type, repository: $repo, id: $id,
          parent: {type: "pull_request", repository: $repo, number: $parent_number},
          url: $url
        }')"

      local dedup_formatted
      dedup_formatted="$(echo "$review_before" | jq '{id, state, body, html_url, user: {login: .user.login}, submitted_at, commit_id}')"
      envelope_already_applied "reviews.submit-comment" "$dedup_target" "$dedup_formatted"
      exit 0
    fi

    gh_cleanup "$before_body_file"
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq '{body: .body, event: "COMMENT"}' "$request_file" > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews/$review_id/events" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "reviews.submit-comment" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews/$review_id" 2>/dev/null)" || {
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "reviews.submit-comment" "$pr_target" "{}"
    exit 1
  }

  local verified_id verified_state
  verified_id="$(echo "$verified" | jq -r '.id')"
  verified_state="$(echo "$verified" | jq -r '.state // empty')"

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"

  local triple_ok=true
  if [ "$res_id" != "$verified_id" ]; then
    triple_ok=false
  fi
  if [ "$res_url" != "$verified_url" ]; then
    triple_ok=false
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    triple_ok=false
  fi

  if [ "$triple_ok" = "true" ] && [ -f "$expected_body_file" ]; then
    if ! cmp -s "$expected_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
      triple_ok=false
    fi
  fi

  rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$expected_body_file"

  local review_target
  review_target="$(jq -n \
    --arg type "review" \
    --arg repo "$owner_repo" \
    --argjson id "$review_id" \
    --argjson parent_number "$pr_number" \
    --arg url "$verified_url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: "pull_request", repository: $repo, number: $parent_number},
      url: $url
    }')"

  if [ "$triple_ok" != "true" ]; then
    gh_cleanup "$expected_body_file" 2>/dev/null || true
    envelope_unknown_outcome "reviews.submit-comment" "$review_target" "$verified"
    exit 1
  fi

  if [ "$verified_state" != "COMMENTED" ]; then
    envelope_unknown_outcome "reviews.submit-comment" "$review_target" "$verified"
    exit 1
  fi

  local formatted
  formatted="$(echo "$verified" | jq '{id, state, body, html_url, user: {login: .user.login}, submitted_at, commit_id}')"

  envelope_ok "reviews.submit-comment" "$review_target" "$formatted"
}

main "$@"
