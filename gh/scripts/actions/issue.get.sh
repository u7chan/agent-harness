#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"
  local number
  number="$(echo "$input" | jq -r '.number')"

  local repo_target
  repo_target="$(resolve_target)" || {
    envelope_fail "issue.get" "TARGET_ERROR" "Failed to resolve target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$repo_target" | jq -r '.repository')"

  local data
  data="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_fail "issue.get" "API_ERROR" "Failed to get issue" false
    exit 1
  }

  local has_pr
  has_pr="$(echo "$data" | jq -r '.pull_request // empty')"
  if [ -n "$has_pr" ]; then
    envelope_fail "issue.get" "NOT_FOUND" "Issue #$number not found" false
    exit 1
  fi

  local formatted
  formatted="$(echo "$data" | jq '{
    id, number, title, state, html_url, body,
    user: {login: .user.login},
    labels: [.labels[]? | {name: .name}],
    assignees: [.assignees[]? | {login: .login}],
    milestone: {title: .milestone.title},
    comments, created_at, updated_at, closed_at
  }')"

  local target
  target="$(echo "$repo_target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  envelope_ok "issue.get" "$target" "$formatted"
}

main "$@"
