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
    envelope_fail "pr.checks.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local pr_data
  pr_data="$(call_gh_api "repos/$owner_repo/pulls/$pr_number")" || {
    envelope_fail "pr.checks.read" "API_ERROR" "Failed to get PR #$pr_number" false
    exit 1
  }

  local head_sha
  head_sha="$(echo "$pr_data" | jq -r '.head.sha')"

  local page=1
  local per_page=100
  local all_results="[]"

  while :; do
    local raw_data
    raw_data="$(call_gh_api "repos/$owner_repo/commits/$head_sha/check-runs" "GET" \
      -f "per_page=$per_page" -f "page=$page")" || {
      envelope_fail "pr.checks.read" "API_ERROR" "Failed to get check runs for PR #$pr_number" false
      exit 1
    }

    local page_items items_count
    page_items="$(echo "$raw_data" | jq -c '[.check_runs[]? | {
      name, status, conclusion, html_url
    }]')"
    items_count="$(echo "$page_items" | jq 'length')"

    if [ "$items_count" -eq 0 ]; then
      break
    fi

    all_results="$(echo "$page_items" | jq -c --slurpfile old <(echo "$all_results") '$old[0] + .')"

    if [ "$items_count" -lt "$per_page" ]; then
      break
    fi

    page=$((page + 1))
  done

  envelope_ok "pr.checks.read" "$pr_target" "$all_results"
}

main "$@"
