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
    envelope_fail "pr.files.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/files" '[.[]]' 100)" || {
    envelope_fail "pr.files.read" "API_ERROR" "Failed to get PR files #$pr_number" false
    exit 1
  }

  local data
  data="$(echo "$raw_data" | jq -c '[.[] | {
    sha, filename, status, additions, deletions, changes,
    blob_url, raw_url, contents_url, patch
  }]')"

  envelope_ok "pr.files.read" "$pr_target" "$data"
}

main "$@"
