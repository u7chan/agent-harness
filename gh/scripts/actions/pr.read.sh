#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"

  local reference number
  reference="$(echo "$input" | jq -r '.reference // empty')"
  number="$(echo "$input" | jq -r '.number // empty')"

  local pr_target
  pr_target="$(resolve_pr_target "$reference" "$number")" || {
    envelope_fail "pr.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local data
  data="$(call_gh_api "repos/$owner_repo/pulls/$pr_number")" || {
    envelope_fail "pr.read" "API_ERROR" "Failed to get PR #$pr_number" false
    exit 1
  }

  local formatted
  formatted="$(echo "$data" | jq '{
    id, number, title, state, html_url, body, draft, merged, mergeable,
    user: {login: .user.login},
    labels: [.labels[]? | {name: .name}],
    assignees: [.assignees[]? | {login: .login}],
    milestone: {title: .milestone.title},
    comments, commits, additions, deletions, changed_files,
    created_at, updated_at, closed_at, merged_at,
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
  }')"

  envelope_ok "pr.read" "$pr_target" "$formatted"
}

main "$@"
