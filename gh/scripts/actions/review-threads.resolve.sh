#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"

# GraphQL fetch that fails closed: a non-zero gh CLI exit and a response body
# carrying a non-empty errors array both count as a failed call, matching
# review-threads.read. The gh CLI can print error bodies to stdout on a zero
# exit, so the exit code alone is not enough.
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

# Strict node(id:) classification shared by the pre-check and the post-write
# verification. Only "ok" may drive a decision; every other shape fails
# closed instead of defaulting missing fields (review-threads.read verifies
# the same __typename + id identity before trusting a node):
#   ok         - the node is the requested PullRequestReviewThread (id
#                matches), isResolved is a real boolean, and the owning
#                pullRequest/repository is present
#   not_found  - data.node is explicitly null
#   wrong_node - the node is not the requested review thread: a different
#                __typename or a different id than requested
#   incomplete - any other unverifiable shape: missing node key, non-object
#                node, missing or non-boolean isResolved, missing ownership
classify_node() {
  local response="$1"
  local thread_id="$2"
  printf '%s\n' "$response" | jq -r --arg tid "$thread_id" '
    if (((.data // null) | type) != "object") or ((.data | has("node")) | not) then "incomplete"
    elif .data.node == null then "not_found"
    elif ((.data.node | type) != "object") then "incomplete"
    elif .data.node.__typename != "PullRequestReviewThread" then "wrong_node"
    elif .data.node.id != $tid then "wrong_node"
    elif ((.data.node.isResolved | type) != "boolean") then "incomplete"
    elif ((.data.node.pullRequest | type) != "object") or
         ((.data.node.pullRequest.repository | type) != "object") or
         ((.data.node.pullRequest.repository.nameWithOwner | type) != "string") or
         (.data.node.pullRequest.repository.nameWithOwner == "") then "incomplete"
    else "ok"
    end'
}

# Shared node fetch that both the pre-check and the post-write verification
# run, so they validate exactly the same response shape.
NODE_QUERY='query($threadId: ID!) { node(id: $threadId) { __typename ... on PullRequestReviewThread { id isResolved pullRequest { url number repository { nameWithOwner } } } } }'

# Fail the action before any mutation when the pre-check cannot prove that
# the requested thread exists in the expected state.
fail_unverifiable_thread() {
  local state="$1"
  local thread_id="$2"
  case "$state" in
    not_found|wrong_node)
      envelope_fail "review-threads.resolve" "NOT_FOUND" "Thread $thread_id not found" false
      exit 1
      ;;
    ok)
      ;;
    *)
      envelope_fail "review-threads.resolve" "API_ERROR" "GraphQL node response is incomplete" false
      exit 1
      ;;
  esac
}

main() {
  local request_file="$1"

  local thread_id reference
  thread_id="$(jq -r '.thread_id' "$request_file")"
  # Optional reference pins the target repository to the caller's PR-derived
  # owner/repo (review skill contract); absent or null falls back to the
  # current working directory's repository.
  reference="$(jq -r '.reference // empty' "$request_file")"

  local target
  target="$(resolve_target "$reference")" || {
    envelope_fail "review-threads.resolve" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_state
  before_state="$(call_graphql "$NODE_QUERY" -f threadId="$thread_id")" || {
    envelope_fail "review-threads.resolve" "API_ERROR" "Failed to fetch thread state" false
    exit 1
  }

  local node_state
  node_state="$(classify_node "$before_state" "$thread_id" 2>/dev/null)" || node_state="incomplete"
  fail_unverifiable_thread "$node_state" "$thread_id"

  # Case-insensitive membership, matching review-threads.read: the reference
  # (or CWD) spelling is preserved in the envelope, but the comparison is
  # normalized on both sides so "U7chan/Agent-Harness" matches the API's
  # canonical "u7chan/agent-harness". classify_node already required the
  # owning repository to be present.
  local owner_repo_lc
  owner_repo_lc="$(printf '%s' "$owner_repo" | tr '[:upper:]' '[:lower:]')"
  local thread_repo thread_repo_lc
  thread_repo="$(echo "$before_state" | jq -r '.data.node.pullRequest.repository.nameWithOwner')"
  thread_repo_lc="$(printf '%s' "$thread_repo" | tr '[:upper:]' '[:lower:]')"

  if [ "$thread_repo_lc" != "$owner_repo_lc" ]; then
    envelope_fail "review-threads.resolve" "TARGET_MISMATCH" "Thread belongs to $thread_repo, not $owner_repo" false
    exit 1
  fi

  local thread_url
  thread_url="$(echo "$before_state" | jq -r '.data.node.pullRequest.url // ""')"

  local thread_target
  thread_target="$(jq -n \
    --arg type "review_thread" \
    --arg repo "$owner_repo" \
    --arg id "$thread_id" \
    --arg url "$thread_url" \
    '{type: $type, repository: $repo, id: $id, url: $url}')"

  # classify_node guaranteed a real boolean here, so only true/false remain.
  local is_resolved
  is_resolved="$(echo "$before_state" | jq -r '.data.node.isResolved')"

  if [ "$is_resolved" = "true" ]; then
    local already_data
    already_data="$(jq -n --arg thread_id "$thread_id" --argjson resolved true --arg outcome "already_resolved_external" '{thread_id: $thread_id, resolved: $resolved, outcome: $outcome}')"
    envelope_already_applied "review-threads.resolve" "$thread_target" "$already_data"
    exit 0
  fi

  # Single-fire mutation: no retry layer wraps it, so the caller's retry
  # settings never multiply the write. A failed or malformed response is
  # ambiguous, so it reports unknown_outcome instead of retrying.
  local mutation_query
  mutation_query='mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } } }'

  local mutation_result
  mutation_result="$(call_graphql "$mutation_query" -f threadId="$thread_id")" || {
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "{}"
    exit 1
  }
  if ! echo "$mutation_result" | jq -e --arg thread_id "$thread_id" \
    '.data.resolveReviewThread.thread.id == $thread_id and .data.resolveReviewThread.thread.isResolved == true' >/dev/null 2>&1; then
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "$mutation_result"
    exit 1
  fi

  # Post-write verification: the re-read must prove that the same thread now
  # carries a real boolean true. Every unverifiable shape - fetch failure,
  # errors, null or missing node, wrong node, missing or non-boolean
  # isResolved - reports unknown_outcome, never success.
  local after_state
  after_state="$(call_graphql "$NODE_QUERY" -f threadId="$thread_id")" || {
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "{}"
    exit 1
  }
  node_state="$(classify_node "$after_state" "$thread_id" 2>/dev/null)" || node_state="incomplete"
  if [ "$node_state" != "ok" ]; then
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "$after_state"
    exit 1
  fi

  local after_resolved
  after_resolved="$(echo "$after_state" | jq -r '.data.node.isResolved')"
  if [ "$after_resolved" != "true" ]; then
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "$after_state"
    exit 1
  fi

  local confirmation
  confirmation="$(jq -n --arg thread_id "$thread_id" --argjson resolved true --arg outcome "resolved_by_run" '{thread_id: $thread_id, resolved: $resolved, outcome: $outcome}')"

  envelope_ok "review-threads.resolve" "$thread_target" "$confirmation"
}

main "$@"
