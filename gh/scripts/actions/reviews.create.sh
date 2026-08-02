#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number
  number="$(jq -r '.number' "$request_file")"

  local event
  event="$(jq -r '.event // "COMMENT"' "$request_file")"
  case "$event" in
    COMMENT|PENDING) ;;
    *)
      envelope_fail "reviews.create" "INVALID_PARAMETER" "Only event=COMMENT or PENDING is allowed. APPROVE and REQUEST_CHANGES are rejected." false
      exit 1
      ;;
  esac

  local target
  target="$(resolve_pr_target "" "$number")" || {
    envelope_fail "reviews.create" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  local body_file
  body_file="$(gh_make_temp "write-body")"

  local has_comments
  has_comments="$(jq -r 'if has("comments") and (.comments | type == "array") then "true" else "false" end' "$request_file")"

  if [ "$event" = "PENDING" ]; then
    if [ "$has_comments" = "true" ]; then
      jq '{body: .body, comments: .comments}' "$request_file" > "$body_file"
    else
      jq '{body: .body}' "$request_file" > "$body_file"
    fi
  else
    if [ "$has_comments" = "true" ]; then
      jq '{body: .body, event: "COMMENT", comments: .comments}' "$request_file" > "$body_file"
    else
      jq '{body: .body, event: "COMMENT"}' "$request_file" > "$body_file"
    fi
  fi

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "reviews.create" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local res_id
  res_id="$(echo "$_res" | jq -r '.id')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/reviews/$res_id" 2>/dev/null)" || {
    envelope_unknown_outcome "reviews.create" "$pr_target" "{}"
    exit 1
  }

  local verified_id verified_state
  verified_id="$(echo "$verified" | jq -r '.id')"
  verified_state="$(echo "$verified" | jq -r '.state // empty')"

  if [ "$res_id" != "$verified_id" ]; then
    envelope_unknown_outcome "reviews.create" "$pr_target" "$verified"
    exit 1
  fi

  local res_url verified_url
  res_url="$(echo "$_res" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  if [ "$res_url" != "$verified_url" ]; then
    envelope_unknown_outcome "reviews.create" "$pr_target" "$verified"
    exit 1
  fi

  echo "$_res" | jq -j '.body // ""' > "$GH_TEMP_DIR/res-body-tmp"
  echo "$verified" | jq -j '.body // ""' > "$GH_TEMP_DIR/verified-body-tmp"
  if ! cmp -s "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/res-body-tmp" "$GH_TEMP_DIR/verified-body-tmp"
    envelope_unknown_outcome "reviews.create" "$pr_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/res-body-tmp"

  local expected_body_file
  expected_body_file="$(gh_make_temp "expected-body")"
  jq -j '.body' "$request_file" > "$expected_body_file"

  if ! cmp -s "$expected_body_file" "$GH_TEMP_DIR/verified-body-tmp" 2>/dev/null; then
    rm -f "$GH_TEMP_DIR/verified-body-tmp"
    gh_cleanup "$expected_body_file"
    envelope_unknown_outcome "reviews.create" "$pr_target" "$verified"
    exit 1
  fi
  rm -f "$GH_TEMP_DIR/verified-body-tmp"
  gh_cleanup "$expected_body_file"

  local review_target
  review_target="$(jq -n \
    --arg type "review" \
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
  formatted="$(echo "$verified" | jq '{id, state, body, html_url, user: {login: .user.login}, submitted_at, commit_id}')"

  envelope_ok "reviews.create" "$review_target" "$formatted"
}

main "$@"
