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
    envelope_fail "review-comments.delete" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/comments/$comment_id" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    local api_stderr
    api_stderr="$(cat "$GH_TEMP_DIR/gh-stderr" 2>/dev/null || true)"
    if echo "$api_stderr" | grep -qE 'HTTP 404'; then
      envelope_fail "review-comments.delete" "NOT_FOUND" "Review comment $comment_id not found" false
      exit 1
    fi
    envelope_fail "review-comments.delete" "API_ERROR" "Failed to fetch review comment" false
    exit 1
  }

  local comment_url
  comment_url="$(echo "$before_state" | jq -r '.html_url // ""')"

  local comment_target
  comment_target="$(jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$comment_id" \
    --arg url "$comment_url" \
    '{
      type: $type, repository: $repo, id: $id, url: $url
    }')"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  call_gh_api "repos/$owner_repo/pulls/comments/$comment_id" "DELETE" 2>"$GH_TEMP_DIR/gh-delete-stderr" || {
    GH_RETRY_MAX="$_saved_retry"
    envelope_fail "review-comments.delete" "API_ERROR" "Failed to delete review comment" false
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"

  local verify_stderr_file="$GH_TEMP_DIR/gh-verify-stderr"
  local verify_result verify_exit
  verify_result="$(call_gh_api "repos/$owner_repo/pulls/comments/$comment_id" 2>"$verify_stderr_file")" && verify_exit=0 || verify_exit=$?

  if [ "$verify_exit" -eq 0 ]; then
    envelope_unknown_outcome "review-comments.delete" "$comment_target" "{}"
    exit 1
  fi

  local v_stderr
  v_stderr="$(cat "$verify_stderr_file" 2>/dev/null || true)"

  if ! echo "$v_stderr" | grep -qE 'HTTP 404'; then
    envelope_unknown_outcome "review-comments.delete" "$comment_target" "{}"
    exit 1
  fi

  local confirmation
  confirmation="$(jq -n --argjson id "$comment_id" '{id: $id, deleted: true}')"

  envelope_ok "review-comments.delete" "$comment_target" "$confirmation"
}

main "$@"
