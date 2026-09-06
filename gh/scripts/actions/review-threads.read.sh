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

# Fetch the scoped node and classify strictly. Accepts exactly two shapes:
# - GitHub's unresolvable-node response: data is an object with node
#   explicitly null and a non-empty errors array whose every entry is
#   NOT_FOUND with path exactly ["node"]. This is the only failure mapped to
#   the filtered-empty contract, and it is accepted at any exit code because
#   the gh CLI exits non-zero for GraphQL error bodies while printing them.
#   A NOT_FOUND on a child path (e.g. ["node", "pullRequest"]) is a child
#   fetch error, not a missing id, and is not accepted.
# - A normal success: exit code 0, no errors, and a data object holding a
#   node object. Any other shape (missing node key, non-object node such as
#   an array) fails, and every non-zero exit that is not the exception above
#   fails, surfacing as API_ERROR like the collection path.
call_graphql_node_may_be_missing() {
  local query="$1"
  shift
  local result rc=0
  result="$(gh api graphql -f query="$query" "$@" 2>/dev/null)" || rc=$?
  if echo "$result" | jq -e --argjson rc "$rc" '
    (
      (((.data // null) | type) == "object")
      and (.data | has("node"))
      and (.data.node == null)
      and (((.errors // []) | type) == "array")
      and (((.errors // []) | length) > 0)
      and ([.errors[] | ((.type? // "") == "NOT_FOUND") and ((.path? // null) == ["node"])] | all)
    )
    or
    (
      ($rc == 0)
      and (((.errors // []) | type) == "array")
      and (((.errors // []) | length) == 0)
      and (((.data // null) | type) == "object")
      and (.data | has("node"))
      and (((.data.node // null) | type) == "object")
    )
  ' >/dev/null 2>&1; then
    printf '%s\n' "$result"
    return 0
  fi
  return 1
}

# Single authoritative mapping from one GraphQL review comment node to the
# internal comment fields. Shared by the full snapshot and the scoped read so
# the two paths cannot drift.
COMMENT_FIELDS_JQ='{
  id: (.id // empty),
  database_id: (.databaseId // null),
  body: (.body // ""),
  url: (.url // ""),
  path: (.path // ""),
  line: (.line // null),
  outdated: (.outdated // false),
  commit_oid: (.commit.oid // ""),
  reply_to_id: (.replyTo.id // null),
  author_login: (.author.login // ""),
  author_association: (.authorAssociation // ""),
  created_at: (.createdAt // ""),
  updated_at: (.updatedAt // ""),
  last_edited_at: (.lastEditedAt // null)
}'

emit_threads_envelope() {
  local collection_target="$1"
  local threads_json="$2"
  local wrapper
  wrapper="$(jq -n --argjson threads "$threads_json" '{threads: $threads, pagination: {threads_complete: true, comments_complete: true}}')"
  envelope_ok "review-threads.read" "$collection_target" "$wrapper"
}

# Scoped read for an explicit thread_id: fetch only the requested thread node
# and its comments instead of the PR-wide reviewThreads collection, so the
# cost of confirming one thread does not grow with the number of unrelated
# threads. The envelope is the collection path's output filtered to one
# thread. Safety checks are kept, not dropped: the node must be the requested
# PullRequestReviewThread belonging to the target PR (number and repository,
# like review-threads.resolve), and comment pages are paginated to
# completeness with the same pageInfo/nodes validation as the collection path.
read_scoped_thread() {
  local thread_id="$1"
  local owner_repo="$2" pr_number="$3"
  local collection_target="$4"

  # Repository names are case-insensitive on GitHub: nameWithOwner comes back
  # in canonical spelling while reference keeps the caller's spelling, so the
  # membership comparison normalizes both sides.
  local owner_repo_lc
  owner_repo_lc="$(printf '%s' "$owner_repo" | tr '[:upper:]' '[:lower:]')"

  local scoped_query
  scoped_query='query($threadId: ID!, $after: String) { node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { number repository { nameWithOwner } } comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id databaseId body url path line outdated commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt lastEditedAt } } } } }'

  local comments_tmp
  comments_tmp="$(gh_make_temp "scoped-thread-comments")" || {
    envelope_fail "review-threads.read" "API_ERROR" "Failed to create scratch file" false
    exit 1
  }
  echo "[]" > "$comments_tmp"

  local cursor="null"
  local membership_verified="false"
  local is_resolved="false"

  while :; do
    local page_result
    if [ "$membership_verified" != "true" ]; then
      # First page: tolerate "node does not resolve" errors so an unknown or
      # foreign thread_id keeps the filtered-empty contract; any other
      # failure still reports API_ERROR.
      page_result="$(call_graphql_node_may_be_missing "$scoped_query" \
        -F threadId="$thread_id" \
        -F after="$cursor" \
       2>/dev/null)" || {
        gh_cleanup "$comments_tmp"
        envelope_fail "review-threads.read" "API_ERROR" "Failed to fetch review thread" false
        exit 1
      }
    else
      page_result="$(call_graphql "$scoped_query" \
        -F threadId="$thread_id" \
        -F after="$cursor" \
       2>/dev/null)" || {
        gh_cleanup "$comments_tmp"
        envelope_fail "review-threads.read" "API_ERROR" "Failed to fetch review thread" false
        exit 1
      }
    fi

    if [ "$membership_verified" != "true" ]; then
      # Classify the first response exactly. The fetch helper only lets
      # through the unresolvable-node NOT_FOUND response (node explicitly
      # null) and normal successes with a node object; anything else -
      # missing node key, a non-object node type, other error bodies - has
      # already failed. A null node keeps the collection path's
      # filtered-empty contract; a resolved object that is not the requested
      # review thread is not a thread of the target PR and keeps it too.
      local node_state
      node_state="$(echo "$page_result" | jq -r --arg tid "$thread_id" '
        if (((.data // null) | type) != "object") or ((.data | has("node")) | not) then "incomplete"
        elif .data.node == null then "unresolved"
        elif ((.data.node | type) == "object") then
          (if .data.node.id == $tid then "match" else "other_node" end)
        else "incomplete"
        end' 2>/dev/null)" || node_state="incomplete"
      case "$node_state" in
        unresolved|other_node)
          gh_cleanup "$comments_tmp"
          emit_threads_envelope "$collection_target" "[]"
          exit 0
          ;;
        match)
          ;;
        *)
          gh_cleanup "$comments_tmp"
          envelope_fail "review-threads.read" "API_ERROR" "GraphQL node response is incomplete" false
          exit 1
          ;;
      esac
      if ! echo "$page_result" | jq -e --argjson pr "$pr_number" --arg owner_repo "$owner_repo_lc" \
        '.data.node.pullRequest | type == "object" and .number == $pr and ((.repository.nameWithOwner // "" | ascii_downcase) == $owner_repo)' >/dev/null 2>&1; then
        # The node exists but belongs to another PR or repository, so it is
        # not a thread of the target PR. Membership is verified, not assumed;
        # the result stays the filtered-empty contract.
        gh_cleanup "$comments_tmp"
        emit_threads_envelope "$collection_target" "[]"
        exit 0
      fi
      membership_verified="true"
      is_resolved="$(echo "$page_result" | jq -r '.data.node.isResolved // false')"
    fi

    if ! echo "$page_result" | jq -e '.data.node.comments.pageInfo | type == "object" and (.hasNextPage | type == "boolean")' >/dev/null 2>&1; then
      gh_cleanup "$comments_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment pageInfo is incomplete" false
      exit 1
    fi
    if ! echo "$page_result" | jq -e '.data.node.comments.nodes | type == "array"' >/dev/null 2>&1; then
      gh_cleanup "$comments_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment nodes are incomplete" false
      exit 1
    fi

    local new_comments
    new_comments="$(echo "$page_result" | jq -c "[.data.node.comments.nodes[]? | $COMMENT_FIELDS_JQ]" 2>/dev/null)" || {
      gh_cleanup "$comments_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to normalize review thread comments" false
      exit 1
    }

    local merged
    merged="$(echo "$new_comments" | jq -c --slurpfile old "$comments_tmp" '$old[0] + .')" || {
      gh_cleanup "$comments_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to merge review thread comments" false
      exit 1
    }
    echo "$merged" > "$comments_tmp"

    local has_next end_cursor
    has_next="$(echo "$page_result" | jq -r '.data.node.comments.pageInfo.hasNextPage // false')"
    end_cursor="$(echo "$page_result" | jq -r '.data.node.comments.pageInfo.endCursor // "null"')"

    if [ "$has_next" != "true" ] || [ "$end_cursor" = "null" ]; then
      if [ "$has_next" = "true" ] && [ "$end_cursor" = "null" ]; then
        gh_cleanup "$comments_tmp"
        envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment pagination has no endCursor" false
        exit 1
      fi
      break
    fi
    cursor="$end_cursor"
  done

  local comments_json
  comments_json="$(cat "$comments_tmp")" || {
    gh_cleanup "$comments_tmp"
    envelope_fail "review-threads.read" "API_ERROR" "Failed to read review thread comments" false
    exit 1
  }
  gh_cleanup "$comments_tmp"

  local threads_json
  threads_json="$(echo "$comments_json" | jq -c --arg tid "$thread_id" --argjson resolved "$is_resolved" \
    '[{
      thread_id: $tid,
      resolved: $resolved,
      comments: [.[] | {
        id: .id,
        database_id: .database_id,
        body: .body,
        html_url: .url,
        path: .path,
        line: .line,
        outdated: .outdated,
        commit_id: .commit_oid,
        in_reply_to_id: .reply_to_id,
        user: {login: .author_login},
        created_at: .created_at,
        updated_at: .updated_at,
        last_edited_at: .last_edited_at,
        author_association: .author_association
      }]
    }]')" || {
    envelope_fail "review-threads.read" "API_ERROR" "Failed to format review thread" false
    exit 1
  }

  emit_threads_envelope "$collection_target" "$threads_json"
}

main() {
  local request_file="$1"

  local number reference thread_id
  number="$(jq -r '.number' "$request_file")"
  reference="$(jq -r '.reference // empty' "$request_file")"
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
  target="$(resolve_pr_target "$reference" "$number")" || {
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

  # Scoped read: with an explicit thread_id, fetch only that thread node
  # instead of the PR-wide reviewThreads collection (initial snapshots without
  # thread_id keep the full read below).
  if [ -n "$thread_id" ]; then
    read_scoped_thread "$thread_id" "$owner_repo" "$pr_number" "$collection_target"
    return 0
  fi

  local threads_tmp
  threads_tmp="$(gh_make_temp "threads-raw")"
  echo "[]" > "$threads_tmp"
  local cursor="null"

  while :; do
    local query
    query="query(\$owner: String!, \$repo: String!, \$prNumber: Int!, \$first: Int!, \$after: String) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$prNumber) { reviewThreads(first: \$first, after: \$after) { pageInfo { hasNextPage endCursor } nodes { id isResolved comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { id databaseId body url path line outdated commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt lastEditedAt } } } } } } }"

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

    if ! echo "$page_result" | jq -e '.data.repository.pullRequest.reviewThreads.pageInfo | type == "object" and (.hasNextPage | type == "boolean")' >/dev/null 2>&1; then
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL reviewThreads pageInfo is incomplete" false
      exit 1
    fi
    if ! echo "$page_result" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' >/dev/null 2>&1; then
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL reviewThreads nodes are incomplete" false
      exit 1
    fi
    if ! echo "$page_result" | jq -e '
      .data.repository.pullRequest.reviewThreads.nodes
      | all(.[];
          (.comments | type == "object") and
          (.comments.nodes | type == "array") and
          (.comments.pageInfo | type == "object") and
          (.comments.pageInfo.hasNextPage | type == "boolean"))
    ' >/dev/null 2>&1; then
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL thread comments pagination is incomplete" false
      exit 1
    fi

    local page_threads
    page_threads="$(echo "$page_result" | jq -c "[.data.repository.pullRequest.reviewThreads.nodes[]? | {
      thread_id: .id,
      is_resolved: (.isResolved // false),
      comments: [.comments.nodes[]? | $COMMENT_FIELDS_JQ],
      comments_pageInfo: .comments.pageInfo
    }]" 2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to normalize review thread comments" false
      exit 1
    }

    local merged
    merged="$(echo "$page_threads" | jq -c --slurpfile old "$threads_tmp" '$old[0] + .')"
    echo "$merged" > "$threads_tmp"

    local has_next end_cursor
    has_next="$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')"
    end_cursor="$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // "null"')"

    if [ "$has_next" != "true" ] || [ "$end_cursor" = "null" ]; then
      if [ "$has_next" = "true" ] && [ "$end_cursor" = "null" ]; then
        gh_cleanup "$threads_tmp"
        envelope_fail "review-threads.read" "API_ERROR" "GraphQL reviewThreads pagination has no endCursor" false
        exit 1
      fi
      break
    fi
    cursor="$end_cursor"
  done

  local cquery
  cquery='query($threadId: ID!, $after: String) { node(id: $threadId) { ... on PullRequestReviewThread { comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id databaseId body url path line outdated commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt lastEditedAt } } } } }'

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
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment pagination has no endCursor" false
      exit 1
    fi

    local cresult
    cresult="$(call_graphql "$cquery" -F threadId="$tid" -F after="$comment_cursor" 2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to paginate comments for thread" false
      exit 1
    }

    if ! echo "$cresult" | jq -e '.data.node.comments.pageInfo | type == "object" and (.hasNextPage | type == "boolean")' >/dev/null 2>&1; then
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment pageInfo is incomplete" false
      exit 1
    fi
    if ! echo "$cresult" | jq -e '.data.node.comments.nodes | type == "array"' >/dev/null 2>&1; then
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "GraphQL comment nodes are incomplete" false
      exit 1
    fi

    local new_comments
    new_comments="$(echo "$cresult" | jq -c "[.data.node.comments.nodes[]? | $COMMENT_FIELDS_JQ]" 2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to normalize paginated review comments" false
      exit 1
    }

    local new_page_info
    new_page_info="$(echo "$cresult" | jq -c '.data.node.comments.pageInfo' 2>/dev/null)" || {
      gh_cleanup "$threads_tmp"
      envelope_fail "review-threads.read" "API_ERROR" "Failed to read paginated review comment pageInfo" false
      exit 1
    }

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
      database_id: .database_id,
      body: .body,
      html_url: .url,
      path: .path,
      line: .line,
      outdated: .outdated,
      commit_id: .commit_oid,
      in_reply_to_id: .reply_to_id,
      user: {login: .author_login},
      created_at: .created_at,
      updated_at: .updated_at,
      last_edited_at: .last_edited_at,
      author_association: .author_association
    }]
  }]' 2>/dev/null)" || {
    envelope_fail "review-threads.read" "API_ERROR" "Failed to format review threads" false
    exit 1
  }

  local wrapper
  wrapper="$(jq -n --argjson threads "$formatted_threads" '{threads: $threads, pagination: {threads_complete: true, comments_complete: true}}')"
  envelope_ok "review-threads.read" "$collection_target" "$wrapper"
}

main "$@"
