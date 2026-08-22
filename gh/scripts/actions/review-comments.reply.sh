#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

call_graphql() {
  local query="$1"
  shift
  local result exit_code=0
  result="$(gh api graphql -f query="$query" "$@" 2>/dev/null)" || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    return 1
  fi
  if ! echo "$result" | jq -e '(.errors // []) | length == 0' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$result"
}

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
    last_edited_at,
    author_association,
    transport_outcome: $outcome,
    operation_scoped: true
  }'
}

precondition_changed() {
  local message="$1"
  envelope_fail "review-comments.reply" "PRECONDITION_CHANGED" "$message" false
  exit 1
}

valid_baseline_ids() {
  local input="$1"
  jq -e '
    type == "array" and
    all(.[]; type == "number" and . == floor and . > 0) and
    (length == (map(tostring) | unique | length))
  ' <<< "$input" >/dev/null 2>&1
}

normalize_comment() {
  jq -c '[.[] | {
    id: (.id // .comment_id),
    body: (.body // ""),
    in_reply_to_id: (.in_reply_to_id // .reply_to_comment_id // null),
    actor: (.user.login // .user_login // .actor // ""),
    path: (.path // null),
    line: (.line // null),
    commit_id: (.commit_id // null),
    created_at: (.created_at // null),
    updated_at: (.updated_at // null)
  }] | sort_by(.id)'
}

baseline_matches_current() {
  local baseline_comments="$1"
  local current_comments="$2"
  local normalized_baseline normalized_current
  normalized_baseline="$(normalize_comment <<< "$baseline_comments")" || return 1
  normalized_current="$(normalize_comment <<< "$current_comments")" || return 1
  [ "$normalized_baseline" = "$normalized_current" ]
}

ids_and_delta() {
  local baseline_ids="$1"
  local current_comments="$2"
  local current_ids
  current_ids="$(echo "$current_comments" | jq -c '[.[].id] | sort')" || return 1
  jq -n \
    --argjson baseline "$baseline_ids" \
    --argjson current "$current_ids" \
    --argjson comments "$current_comments" \
    '{
      baseline: ($baseline | sort),
      current: $current,
      added: ($current - ($baseline | sort)),
      removed: (($baseline | sort) - $current),
      added_comments: [$comments[] as $comment |
        select((($current - ($baseline | sort)) | index($comment.id)) != null) | $comment]
    }'
}

main() {
  local request_file="$1"

  local number reference reply_to thread_id baseline_thread_resolved plan_fingerprint baseline_ids baseline_comments_present request_body_file
  number="$(jq -r '.number' "$request_file")"
  reference="$(jq -r '.reference // empty' "$request_file")"
  reply_to="$(jq -r '.reply_to' "$request_file")"
  thread_id="$(jq -r '.thread_id // empty' "$request_file")"
  baseline_thread_resolved="$(jq -c 'if has("baseline_thread_resolved") then .baseline_thread_resolved else null end' "$request_file")"
  request_body_file="$(gh_make_temp "request-body")"
  jq -j '.body' "$request_file" > "$request_body_file"
  plan_fingerprint="$(jq -r '.plan_fingerprint // empty' "$request_file")"
  baseline_ids="$(jq -c '.baseline_comment_ids // empty' "$request_file")"

  if [ -z "$plan_fingerprint" ]; then
    envelope_fail "review-comments.reply" "MISSING_OPERATION_IDENTITY" "plan_fingerprint is required for operation-scoped reply transport" false
    exit 1
  fi
  if [ -z "$baseline_ids" ] || ! valid_baseline_ids "$baseline_ids"; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "baseline_comment_ids must contain unique positive integer IDs" false
    exit 1
  fi
  if [ -z "$thread_id" ] || [ "$baseline_thread_resolved" != "true" ] && [ "$baseline_thread_resolved" != "false" ]; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "thread_id and boolean baseline_thread_resolved are required" false
    exit 1
  fi
  baseline_comments_present="$(jq -r 'has("baseline_comments")' "$request_file")"
  if [ "$baseline_comments_present" = "true" ] && [ "$(jq -r '.baseline_comments | type' "$request_file")" != "array" ]; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "baseline_comments must be an array" false
    exit 1
  fi

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
  # root numeric REST ID, so the caller and the operation baseline share one
  # unambiguous topology identity.
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

  local root_pull_request_url root_id root_node_id root_path root_commit_id
  root_pull_request_url="$(echo "$root" | jq -r '.pull_request_url // ""')"
  root_id="$(echo "$root" | jq -r '.id')"
  root_node_id="$(echo "$root" | jq -r '.node_id // empty')"
  root_path="$(echo "$root" | jq -r '.path // empty')"
  root_commit_id="$(echo "$root" | jq -r '.commit_id // empty')"
  if [ "$root_pull_request_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Root comment belongs to $root_pull_request_url, not $parent_api_url" false
    exit 1
  fi
  if [ -z "$root_node_id" ] || [ -z "$root_path" ] || [ -z "$root_commit_id" ]; then
    envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no node_id, path, or commit_id to inherit" false
    exit 1
  fi

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  # This is the operation preflight.  An old exact-body comment is harmless if
  # it is part of the baseline: it is not the effect of this operation.  Only
  # one new, exact, direct reply can be adopted as an operation-scoped retry.
  local existing
  existing="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch existing review comments" false
    exit 1
  }
  local delta
  delta="$(ids_and_delta "$baseline_ids" "$existing")" || precondition_changed "Failed to compare operation baseline IDs"
  local added_count removed_count
  added_count="$(echo "$delta" | jq -r '.added | length')"
  removed_count="$(echo "$delta" | jq -r '.removed | length')"

  if [ "$added_count" -eq 0 ] && [ "$removed_count" -eq 0 ] && [ "$baseline_comments_present" = "true" ]; then
    if ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" "$existing"; then
      precondition_changed "Operation baseline comment body or edit metadata changed"
    fi
  elif [ "$added_count" -gt 0 ] || [ "$removed_count" -gt 0 ]; then
    if [ "$removed_count" -ne 0 ] || [ "$added_count" -ne 1 ]; then
      precondition_changed "Operation baseline changed by a non-single reply effect"
    fi
    local adopted
    adopted="$(echo "$existing" | jq -c --argjson baseline "$baseline_ids" --rawfile body "$request_body_file" --arg actor "$actor" --argjson root_id "$root_id" '
      [.[] as $comment | select(
        (($baseline | index($comment.id)) == null) and
        $comment.body == $body and
        ($comment.user.login // "") == $actor and
        ($comment.in_reply_to_id // null) == $root_id
      ) | $comment]
      | if length == 1 then .[0] else empty end
    ')" || adopted=""
    if [ -z "$adopted" ] || [ "$adopted" = "null" ]; then
      precondition_changed "Operation baseline changed by a non-matching reply"
    fi
    local adopted_id adopted_url adopted_target
    adopted_id="$(echo "$adopted" | jq -r '.id')"
    if [ "$baseline_comments_present" = "true" ] && ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" \
      "$(echo "$existing" | jq --argjson id "$adopted_id" '[.[] | select(.id != $id)]')"; then
      precondition_changed "Operation baseline changed an existing comment or edit metadata"
    fi
    adopted_url="$(echo "$adopted" | jq -r '.html_url // ""')"
    adopted_target="$(operation_target "$owner_repo" "$pr_number" "$adopted_id" "$adopted_url")"
    envelope_already_applied "review-comments.reply" "$adopted_target" "$(format_comment "$adopted" "already_applied")"
    exit 0
  fi

  # Re-read the GraphQL thread immediately before constructing the POST.  The
  # REST comment collection cannot represent resolved state, so matching
  # comment IDs alone is insufficient: an external Resolve after planning
  # must stop this operation before it creates a classification reply.
  local thread_query thread_state
  thread_query='query($threadId: ID!) { node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { url repository { nameWithOwner } } comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { id databaseId } } } } }'
  thread_state="$(call_graphql "$thread_query" -F threadId="$thread_id" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch root review thread state" false
    exit 1
  }
  if ! echo "$thread_state" | jq -e \
    --arg thread_id "$thread_id" \
    --arg pr_url "$pr_url" \
    --arg owner_repo "$owner_repo" \
    --arg root_node_id "$root_node_id" \
    --argjson root_id "$root_id" \
    --argjson baseline_resolved "$baseline_thread_resolved" '
      .data.node != null and
      .data.node.id == $thread_id and
      .data.node.isResolved == $baseline_resolved and
      .data.node.pullRequest.url == $pr_url and
      .data.node.pullRequest.repository.nameWithOwner == $owner_repo and
      (.data.node.comments.pageInfo | type == "object") and
      (.data.node.comments.pageInfo.hasNextPage | type == "boolean") and
      ([.data.node.comments.nodes[]? |
        select(.id == $root_node_id and .databaseId == $root_id)] | length == 1)
    ' >/dev/null 2>&1; then
    precondition_changed "Root thread identity or baseline resolved state changed"
  fi
  if [ "$baseline_thread_resolved" != "false" ]; then
    precondition_changed "Operation baseline thread is already resolved"
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -n --rawfile b "$request_body_file" --argjson in_reply_to "$root_id" \
    '{body: $b, in_reply_to: $in_reply_to}' > "$body_file"

  local saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local response
  response="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$saved_retry"
    gh_cleanup "$body_file"
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

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/comments/$response_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  local verified_id verified_pr verified_actor verified_reply response_url verified_url
  verified_id="$(echo "$verified" | jq -r '.id // empty')"
  verified_pr="$(echo "$verified" | jq -r '.pull_request_url // ""')"
  verified_actor="$(echo "$verified" | jq -r '.user.login // empty')"
  verified_reply="$(echo "$verified" | jq -r '.in_reply_to_id // empty')"
  response_url="$(echo "$response" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  local verified_body_file
  verified_body_file="$(gh_make_temp "verified-body")"
  jq -j '.body // empty' <<< "$verified" > "$verified_body_file"
  local response_body_file
  response_body_file="$(gh_make_temp "response-body")"
  jq -j '.body // empty' <<< "$response" > "$response_body_file"
  if [ "$response_id" != "$verified_id" ] || [ "$response_url" != "$verified_url" ] || [ "$verified_pr" != "$parent_api_url" ] || \
     ! cmp -s "$request_body_file" "$response_body_file" || \
     ! cmp -s "$request_body_file" "$verified_body_file" || [ "$verified_actor" != "$actor" ] || [ "$verified_reply" != "$root_id" ]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  # A successful POST is not enough.  The full post snapshot must be exactly
  # baseline + the returned reply; a concurrent Y makes the transport outcome
  # observable but unsafe to adopt as a classification record.
  local after
  after="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  }
  local after_delta after_added after_removed
  after_delta="$(ids_and_delta "$baseline_ids" "$after")" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  }
  after_added="$(echo "$after_delta" | jq -r '.added | length')"
  after_removed="$(echo "$after_delta" | jq -r '.removed | length')"
  if [ "$after_removed" -ne 0 ] || [ "$after_added" -ne 1 ] || \
     [ "$(echo "$after_delta" | jq -r --argjson id "$response_id" '.added | index($id) != null')" != "true" ]; then
    precondition_changed "Post-write snapshot contains an unexpected comment delta"
  fi
  if [ "$baseline_comments_present" = "true" ] && ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" \
    "$(echo "$after" | jq --argjson id "$response_id" '[.[] | select(.id != $id)]')"; then
    precondition_changed "Post-write snapshot changed an existing comment or edit metadata"
  fi

  local comment_target
  comment_target="$(operation_target "$owner_repo" "$pr_number" "$response_id" "$(echo "$verified" | jq -r '.html_url // ""')")"
  envelope_ok "review-comments.reply" "$comment_target" "$(format_comment "$verified" "ok")"
}

main "$@"
