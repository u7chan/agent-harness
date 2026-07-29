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
  target="$(resolve_pr_target)" || {
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

  local all_threads="[]"
  local cursor="null"

  while :; do
    local query
    query="query(\$owner: String!, \$repo: String!, \$prNumber: Int!, \$first: Int!, \$after: String) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$prNumber) { reviewThreads(first: \$first, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id isResolved comments(first: 100) { nodes { id body html_url path line commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt } } } } } } }"

    local page_result
    page_result="$(call_graphql "$query" \
      -F owner="$owner" \
      -F repo="$repo" \
      -F prNumber="$pr_number" \
      -F first="$per_page" \
      -F after="$cursor" \
    2>/dev/null)" || {
      envelope_fail "review-threads.read" "API_ERROR" "Failed to fetch review threads" false
      exit 1
    }

    local threads_page page_info has_next end_cursor
    threads_page="$(echo "$page_result" | jq -c '.data.repository.pullRequest.reviewThreads.nodes // []' 2>/dev/null)" || threads_page="[]"
    page_info="$(echo "$page_result" | jq '.data.repository.pullRequest.reviewThreads.pageInfo // {}' 2>/dev/null)" || page_info="{}"
    has_next="$(echo "$page_info" | jq -r '.hasNextPage // false')"
    end_cursor="$(echo "$page_info" | jq -r '.endCursor // "null"')"

    local formatted_page
    formatted_page="$(echo "$threads_page" | jq -c '
      [.[] | {
        thread_id: (.id // empty),
        resolved: (.isResolved // false),
        comments: [.comments.nodes[]? | {
          id: (.id // empty),
          body: (.body // ""),
          html_url: (.html_url // ""),
          path: (.path // ""),
          line: (.line // null),
          commit_id: (.commit.oid // ""),
          in_reply_to_id: (.replyTo.id // null),
          user: {login: (.author.login // "")},
          created_at: (.createdAt // ""),
          updated_at: (.updatedAt // ""),
          author_association: (.authorAssociation // "")
        }]
      }]
    ' 2>/dev/null)" || formatted_page="[]"

    local concat_tmp
    concat_tmp="$(gh_make_temp "concat")"
    echo "$all_threads" > "$concat_tmp"
    all_threads="$(echo "$formatted_page" | jq -c --slurpfile old "$concat_tmp" '$old[0] + .')" || {
      all_threads="$(echo "$formatted_page" | jq -c --argjson old_threads "$all_threads" '$old_threads + .')"
    }
    gh_cleanup "$concat_tmp"

    if [ "$has_next" != "true" ] || [ "$end_cursor" = "null" ]; then
      break
    fi
    cursor="$end_cursor"
  done

  if [ -n "$thread_id" ]; then
    local filtered
    filtered="$(echo "$all_threads" | jq --arg tid "$thread_id" '
      [ .[] | select(.thread_id == $tid) ]
    ')"
    local wrapper
    wrapper="$(jq -n --argjson threads "$filtered" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  else
    local wrapper
    wrapper="$(jq -n --argjson threads "$all_threads" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  fi
}

main "$@"
