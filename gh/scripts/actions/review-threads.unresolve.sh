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

  local thread_id
  thread_id="$(jq -r '.thread_id' "$request_file")"

  local target
  target="$(resolve_target)" || {
    envelope_fail "review-threads.unresolve" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_query
  before_query='query($threadId: ID!) { node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { url number repository { nameWithOwner } } } } }'

  local before_state
  before_state="$(call_graphql "$before_query" -F threadId="$thread_id" 2>/dev/null)" || {
    envelope_fail "review-threads.unresolve" "API_ERROR" "Failed to fetch thread state" false
    exit 1
  }

  local thread_data
  thread_data="$(echo "$before_state" | jq -r '.data.node // empty')"
  if [ -z "$thread_data" ] || [ "$thread_data" = "null" ]; then
    envelope_fail "review-threads.unresolve" "NOT_FOUND" "Thread $thread_id not found" false
    exit 1
  fi

  local already_unresolved
  local is_resolved
  is_resolved="$(echo "$thread_data" | jq -r '.isResolved // false')"
  local thread_url thread_repo
  thread_url="$(echo "$thread_data" | jq -r '.pullRequest.url // ""')"
  thread_repo="$(echo "$thread_data" | jq -r '.pullRequest.repository.nameWithOwner // ""')"

  if [ -n "$thread_repo" ] && [ "$thread_repo" != "null" ] && [ "$thread_repo" != "$owner_repo" ]; then
    envelope_fail "review-threads.unresolve" "TARGET_MISMATCH" "Thread belongs to $thread_repo, not $owner_repo" false
    exit 1
  fi

  local thread_target
  thread_target="$(jq -n \
    --arg type "review_thread" \
    --arg repo "$owner_repo" \
    --arg id "$thread_id" \
    --arg url "$thread_url" \
    '{type: $type, repository: $repo, id: $id, url: $url}')"

  if [ "$is_resolved" = "false" ]; then
    local already_data
    already_data="$(jq -n --arg thread_id "$thread_id" --argjson resolved false '{thread_id: $thread_id, resolved: $resolved}')"
    envelope_already_applied "review-threads.unresolve" "$thread_target" "$already_data"
    exit 0
  fi

  local mutation_query
  mutation_query='mutation($threadId: ID!) { unresolveReviewThread(input: {threadId: $threadId}) { thread { id isResolved } } }'

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local mutation_result
  mutation_result="$(call_graphql "$mutation_query" -F threadId="$thread_id" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    envelope_unknown_outcome "review-threads.unresolve" "$thread_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"

  local after_state
  after_state="$(call_graphql "$before_query" -F threadId="$thread_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-threads.unresolve" "$thread_target" "{}"
    exit 1
  }

  local after_thread_data
  after_thread_data="$(echo "$after_state" | jq -r '.data.node // empty')"
  local after_resolved
  after_resolved="$(echo "$after_thread_data" | jq -r '.isResolved // false')"

  if [ "$after_resolved" != "false" ]; then
    envelope_unknown_outcome "review-threads.unresolve" "$thread_target" "$after_thread_data"
    exit 1
  fi

  local confirmation
  confirmation="$(jq -n --arg thread_id "$thread_id" --argjson resolved false '{thread_id: $thread_id, resolved: $resolved}')"

  envelope_ok "review-threads.unresolve" "$thread_target" "$confirmation"
}

main "$@"
