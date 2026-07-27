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
    envelope_fail "pr.commits.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/commits" '[.[]]')" || {
    envelope_fail "pr.commits.read" "API_ERROR" "Failed to get PR commits #$pr_number" false
    exit 1
  }

  local data
  data="$(echo "$raw_data" | jq -c '[.[] | {
    sha, html_url,
    commit: {
      message: .commit.message,
      author: {name: .commit.author.name, email: .commit.author.email, date: .commit.author.date},
      committer: {name: .commit.committer.name, email: .commit.committer.email, date: .commit.committer.date}
    },
    author: {login: .author.login, avatar_url: .author.avatar_url},
    committer: {login: .committer.login, avatar_url: .committer.avatar_url},
    parents: [.parents[]? | {sha: .sha, html_url: .html_url}]
  }]')"

  envelope_ok "pr.commits.read" "$pr_target" "$data"
}

main "$@"
