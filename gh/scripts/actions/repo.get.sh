#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local target
  target="$(resolve_target)" || {
    envelope_fail "repo.get" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local data
  data="$(call_gh_api "repos/$owner_repo")" || {
    envelope_fail "repo.get" "API_ERROR" "Failed to get repository" false
    exit 1
  }

  local formatted
  formatted="$(echo "$data" | jq '{
    id, name, full_name, description, private, html_url, default_branch,
    language, stargazers_count, forks_count, open_issues_count, topics,
    created_at, updated_at, pushed_at
  }')"

  envelope_ok "repo.get" "$target" "$formatted"
}

main "$@"
