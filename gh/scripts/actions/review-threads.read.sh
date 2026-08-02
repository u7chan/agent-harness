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
  printf '%s\n' "$result"
}

main() {
  local request_file="$1"

  local number thread_id
  number="$(jq -r '.number' "$request_file")"
  thread_id="$(jq -r '.thread_id // empty' "$request_file")"

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
    envelope_fail "review-threads.read" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local per_page
  per_page="$(jq -r '.per_page // 100' "$request_file")"

  local target
  target="$(resolve_pr_target "" "$number")" || {
    envelope_fail "review-threads.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local owner repo
  owner="${owner_repo%%/*}"
  repo="${owner_repo#*/}"

  local collection_target
  collection_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{
      type: $type,
      repository: $repo,
      number: $number,
      url: $url
    }')"

  local threads_tmp
  threads_tmp="$(gh_make_temp "threads-raw")"
  echo "[]" > "$threads_tmp"
  local cursor="null"

  while :; do
    local query
    query="query(\$owner: String!, \$repo: String!, \$prNumber: Int!, \$first: Int!, \$after: String) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$prNumber) { reviewThreads(first: \$first, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id isResolved comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { id body url path line commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt } } } } } } }"

    local page_result
    page_result="$(call_graphql "$query" \
      -F owner="$owner" \
      -F repo="$repo" \
      -F prNumber="$pr_number" \
      -F first="$per_page" \
      -F after="$cursor" \
     2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to fetch review threads" false
      exit 1
    }

    local page_threads
    page_threads="$(echo "$page_result" | jq -c '[.data.repository.pullRequest.reviewThreads.nodes[]? | {
      thread_id: .id,
      is_resolved: (.isResolved // false),
      comments: [.comments.nodes[]? | {
        id: (.id // empty),
        body: (.body // ""),
        url: (.url // ""),
        path: (.path // ""),
        line: (.line // null),
        commit_oid: (.commit.oid // ""),
        reply_to_id: (.replyTo.id // null),
        author_login: (.author.login // ""),
        author_association: (.authorAssociation // ""),
        created_at: (.createdAt // ""),
        updated_at: (.updatedAt // "")
      }],
      comments_pageInfo: .comments.pageInfo
    }]' 2>/dev/null)" || page_threads="[]"

    local merged
    merged="$(echo "$page_threads" | jq -c --slurpfile old "$threads_tmp" '$old[0] + .')"
    echo "$merged" > "$threads_tmp"

    local has_next end_cursor
    has_next="$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')"
    end_cursor="$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // "null"')"

    if [ "$has_next" != "true" ] || [ "$end_cursor" = "null" ]; then
      break
    fi
    cursor="$end_cursor"
  done

  local cquery
  cquery='query($threadId: ID!, $after: String) { node(id: $threadId) { ... on PullRequestReviewThread { comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id body url path line commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt } } } } }'

  local threads_json
  threads_json="$(cat "$threads_tmp")"
  local pending_count=1

  while [ "$pending_count" -gt 0 ]; do
    pending_count="$(echo "$threads_json" | jq '[.[] | select(.comments_pageInfo.hasNextPage == true)] | length' 2>/dev/null)" || pending_count=0
    if [ "$pending_count" -eq 0 ]; then
      break
    fi

    local tid
    tid="$(echo "$threads_json" | jq -r '[.[] | select(.comments_pageInfo.hasNextPage == true)][0].thread_id // empty' 2>/dev/null)" || tid=""
    if [ -z "$tid" ]; then
      break
    fi

    local comment_cursor
    comment_cursor="$(echo "$threads_json" | jq -r --arg tid "$tid" '[.[] | select(.thread_id == $tid)][0].comments_pageInfo.endCursor // "null"' 2>/dev/null)" || comment_cursor="null"
    if [ "$comment_cursor" = "null" ]; then
      break
    fi

    local cresult
    cresult="$(call_graphql "$cquery" -F threadId="$tid" -F after="$comment_cursor" 2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to paginate comments for thread" false
      exit 1
    }

    local new_comments
    new_comments="$(echo "$cresult" | jq -c '[.data.node.comments.nodes[]? | {
      id: (.id // empty),
      body: (.body // ""),
      url: (.url // ""),
      path: (.path // ""),
      line: (.line // null),
      commit_oid: (.commit.oid // ""),
      reply_to_id: (.replyTo.id // null),
      author_login: (.author.login // ""),
      author_association: (.authorAssociation // ""),
      created_at: (.createdAt // ""),
      updated_at: (.updatedAt // "")
    }]' 2>/dev/null)" || new_comments="[]"

    local new_page_info
    new_page_info="$(echo "$cresult" | jq -c '.data.node.comments.pageInfo // {hasNextPage: false, endCursor: null}' 2>/dev/null)" || new_page_info='{"hasNextPage":false,"endCursor":null}'

    threads_json="$(echo "$threads_json" | jq -c --arg tid "$tid" --argjson nc "$new_comments" --argjson npi "$new_page_info" '
      map(if .thread_id == $tid then
        .comments += $nc | .comments_pageInfo = $npi
      else . end)
    ')"
  done

  gh_cleanup "$threads_tmp"

  local formatted_threads
  formatted_threads="$(echo "$threads_json" | jq -c '[.[] | {
    thread_id: .thread_id,
    resolved: .is_resolved,
    comments: [.comments[] | {
      id: .id,
      body: .body,
      html_url: .url,
      path: .path,
      line: .line,
      commit_id: .commit_oid,
      in_reply_to_id: .reply_to_id,
      user: {login: .author_login},
      created_at: .created_at,
      updated_at: .updated_at,
      author_association: .author_association
    }]
  }]' 2>/dev/null)" || formatted_threads="[]"

  if [ -n "$thread_id" ]; then
    local filtered
    filtered="$(echo "$formatted_threads" | jq --arg tid "$thread_id" '
      [ .[] | select(.thread_id == $tid) ]
    ')"
    local wrapper
    wrapper="$(jq -n --argjson threads "$filtered" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  else
    local wrapper
    wrapper="$(jq -n --argjson threads "$formatted_threads" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  fi
}

main "$@"
