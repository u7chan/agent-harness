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
    envelope_fail "reviewers.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local data
  data="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/requested_reviewers")" || {
    envelope_fail "reviewers.read" "API_ERROR" "Failed to get requested reviewers" false
    exit 1
  }

  local formatted
  formatted="$(echo "$data" | jq '{
    users: [.users[]? | {login, id, html_url}],
    teams: [.teams[]? | {name, id, slug, html_url}]
  }')"

  envelope_ok "reviewers.read" "$pr_target" "$formatted"
}

main "$@"
