#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local thread_id
  thread_id="$(jq -r '.thread_id' "$request_file")"

  local target
  target="$(resolve_target)" || {
    envelope_fail "review-threads.resolve" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/comments/$thread_id" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    local api_stderr
    api_stderr="$(cat "$GH_TEMP_DIR/gh-stderr" 2>/dev/null || true)"
    if echo "$api_stderr" | grep -qE 'HTTP 404'; then
      envelope_fail "review-threads.resolve" "NOT_FOUND" "Thread $thread_id not found" false
      exit 1
    fi
    envelope_fail "review-threads.resolve" "API_ERROR" "Failed to fetch thread comment" false
    exit 1
  }

  local already_resolved
  already_resolved="$(echo "$before_state" | jq -r '.resolved // false')"
  local thread_url
  thread_url="$(echo "$before_state" | jq -r '.html_url // ""')"

  local thread_target
  thread_target="$(jq -n \
    --arg type "review_thread" \
    --arg repo "$owner_repo" \
    --argjson id "$thread_id" \
    --arg url "$thread_url" \
    '{type: $type, repository: $repo, id: $id, url: $url}')"

  if [ "$already_resolved" = "true" ]; then
    local already_data
    already_data="$(jq -n --argjson thread_id "$thread_id" --argjson resolved true '{thread_id: $thread_id, resolved: $resolved}')"
    envelope_already_applied "review-threads.resolve" "$thread_target" "$already_data"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -n '{resolved: true}' > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  call_gh_api "repos/$owner_repo/pulls/comments/$thread_id" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/comments/$thread_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "{}"
    exit 1
  }

  local after_resolved
  after_resolved="$(echo "$after_state" | jq -r '.resolved // false')"

  if [ "$after_resolved" != "true" ]; then
    envelope_unknown_outcome "review-threads.resolve" "$thread_target" "$after_state"
    exit 1
  fi

  local confirmation
  confirmation="$(jq -n --argjson thread_id "$thread_id" --argjson resolved true '{thread_id: $thread_id, resolved: $resolved}')"

  envelope_ok "review-threads.resolve" "$thread_target" "$confirmation"
}

main "$@"
