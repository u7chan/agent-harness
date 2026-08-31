#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

operation_target() {
  local owner_repo="$1"
  local pr_number="$2"
  local id="$3"
  local url="$4"
  jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$id" \
    --argjson parent_number "$pr_number" \
    --arg url "$url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: "pull_request", repository: $repo, number: $parent_number},
      url: $url
    }'
}

format_comment() {
  local comment="$1"
  local outcome="$2"
  echo "$comment" | jq --arg outcome "$outcome" '{
    id,
    body,
    html_url,
    path,
    position,
    line,
    commit_id,
    in_reply_to_id,
    user: {login: .user.login},
    created_at,
    updated_at,
    author_association,
    transport_outcome: $outcome
  }'
}

# Select the single existing reply that is identical to the intended write:
# same body, same actor, same root reply target.  Returns the comment JSON or
# an empty string when no such reply exists yet.
adopt_exact_reply() {
  local comments_json="$1"
  local body_file="$2"
  local actor="$3"
  local root_id="$4"
  echo "$comments_json" | jq -c --rawfile body "$body_file" --arg actor "$actor" --argjson root_id "$root_id" '
    ([.[] | select(
      (.body // "") == $body and
      (.user.login // "") == $actor and
      (.in_reply_to_id // null) == $root_id
    )] | if length > 0 then .[0] else empty end)
  ' 2>/dev/null || true
}

# Emit the already-applied outcome for an adopted exact-match reply.
emit_adopted() {
  local owner_repo="$1"
  local pr_number="$2"
  local adopted="$3"
  local adopted_id adopted_url adopted_target
  adopted_id="$(echo "$adopted" | jq -r '.id // empty')"
  adopted_url="$(echo "$adopted" | jq -r '.html_url // ""')"
  adopted_target="$(operation_target "$owner_repo" "$pr_number" "$adopted_id" "$adopted_url")"
  envelope_already_applied "review-comments.reply" "$adopted_target" "$(format_comment "$adopted" "already_applied")"
}

main() {
  local request_file="$1"

  local number reference reply_to request_body_file
  number="$(jq -r '.number' "$request_file")"
  reference="$(jq -r '.reference // empty' "$request_file")"
  reply_to="$(jq -r '.reply_to' "$request_file")"
  request_body_file="$(gh_make_temp "request-body")"
  jq -j '.body' "$request_file" > "$request_body_file"

  local target
  target="$(resolve_pr_target "$reference" "$number")" || {
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

  # Walk to the actual root and reject cycles.  The write always targets the
  # root numeric REST ID so the dedup and the POST share one topology identity.
  local visited_file
  visited_file="$(gh_make_temp "visited-ids")"
  echo "[]" > "$visited_file"
  local root="$current"
  local step=0
  local max_depth=50
  while :; do
    step=$((step + 1))
    if [ "$step" -gt "$max_depth" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Root comment resolution exceeded max depth ($max_depth)" false
      exit 1
    fi
    local root_id
    root_id="$(echo "$root" | jq -r '.id // empty')"
    if [ -z "$root_id" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no numeric id" false
      exit 1
    fi
    if [ "$(jq --argjson id "$root_id" 'index($id) != null' "$visited_file")" = "true" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Circular reference detected in comment thread at comment $root_id" false
      exit 1
    fi
    jq --argjson id "$root_id" '. + [$id]' "$visited_file" > "${visited_file}.tmp" && mv "${visited_file}.tmp" "$visited_file"
    local parent_id
    parent_id="$(echo "$root" | jq -r '.in_reply_to_id // empty')"
    if [ -z "$parent_id" ]; then
      break
    fi
    root="$(call_gh_api "repos/$owner_repo/pulls/comments/$parent_id" 2>/dev/null)" || {
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch parent comment $parent_id during root resolution" false
      exit 1
    }
  done
  gh_cleanup "$visited_file"

  local root_pull_request_url root_comment_id
  root_pull_request_url="$(echo "$root" | jq -r '.pull_request_url // ""')"
  root_comment_id="$(echo "$root" | jq -r '.id // empty')"
  if [ "$root_pull_request_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Root comment belongs to $root_pull_request_url, not $parent_api_url" false
    exit 1
  fi
  if [ -z "$root_comment_id" ]; then
    envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no numeric id" false
    exit 1
  fi

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  # Exact-body dedup: scan the full REST comment list once.  When a reply with
  # the same body, the same actor, and the same root already exists, the
  # operation is already applied and no POST is performed.
  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch existing review comments" false
    exit 1
  }
  local adopted
  adopted="$(adopt_exact_reply "$existing" "$request_body_file" "$actor" "$root_comment_id")"
  if [ -n "$adopted" ]; then
    emit_adopted "$owner_repo" "$pr_number" "$adopted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -n --rawfile b "$request_body_file" --argjson in_reply_to "$root_comment_id" \
    '{body: $b, in_reply_to: $in_reply_to}' > "$body_file"

  # A single POST attempt.  A failed response is ambiguous (the write may have
  # landed server-side), so re-read and adopt an exact-match reply instead of
  # retrying the POST.  This is the double-post guard for agent retries.
  local saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local response
  response="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/comments" "POST" --input "$body_file" 2>/dev/null)" || {
    GH_RETRY_MAX="$saved_retry"
    local recheck
    if recheck="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)"; then
      adopted="$(adopt_exact_reply "$recheck" "$request_body_file" "$actor" "$root_comment_id")"
      if [ -n "$adopted" ]; then
        emit_adopted "$owner_repo" "$pr_number" "$adopted"
        exit 0
      fi
    fi
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$saved_retry"
  gh_cleanup "$body_file"

  local response_id
  response_id="$(echo "$response" | jq -r '.id // empty')"
  if ! [[ "$response_id" =~ ^[0-9]+$ ]]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$response"
    exit 1
  fi

  # Post-write verification: re-fetch the returned comment and confirm
  # identity, PR membership, actor, body, and reply target.
  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/comments/$response_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  local verified_id verified_pr verified_actor verified_reply
  verified_id="$(echo "$verified" | jq -r '.id // empty')"
  verified_pr="$(echo "$verified" | jq -r '.pull_request_url // ""')"
  verified_actor="$(echo "$verified" | jq -r '.user.login // empty')"
  verified_reply="$(echo "$verified" | jq -r '.in_reply_to_id // empty')"
  local response_url verified_url
  response_url="$(echo "$response" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  local verified_body_file response_body_file
  verified_body_file="$(gh_make_temp "verified-body")"
  jq -j '.body // empty' <<< "$verified" > "$verified_body_file"
  response_body_file="$(gh_make_temp "response-body")"
  jq -j '.body // empty' <<< "$response" > "$response_body_file"
  if [ "$response_id" != "$verified_id" ] || [ "$response_url" != "$verified_url" ] || \
     ! cmp -s "$request_body_file" "$response_body_file" || \
     ! cmp -s "$request_body_file" "$verified_body_file" || \
     [ "$verified_pr" != "$parent_api_url" ] || \
     [ "$verified_actor" != "$actor" ] || [ "$verified_reply" != "$root_comment_id" ]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi
  gh_cleanup "$verified_body_file"
  gh_cleanup "$response_body_file"

  local comment_target
  comment_target="$(operation_target "$owner_repo" "$pr_number" "$response_id" "$(echo "$verified" | jq -r '.html_url // ""')")"
  envelope_ok "review-comments.reply" "$comment_target" "$(format_comment "$verified" "ok")"
}

main "$@"