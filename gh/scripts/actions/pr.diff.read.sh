#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local reference number
  reference="$(echo "$input" | jq -r '.reference // empty')"
  number="$(echo "$input" | jq -r '.number // empty')"

  local pr_target
  pr_target="$(resolve_pr_target "$reference" "$number")" || {
    envelope_fail "pr.diff.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local diff_content
  diff_content="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" "GET" \
    -H "Accept: application/vnd.github.v3.diff")" || {
    envelope_fail "pr.diff.read" "API_ERROR" "Failed to get PR diff #$pr_number" false
    exit 1
  }

  local file_info
  file_info="$(echo "$diff_content" | large_output "pr-diff-$pr_number")"

  envelope_ok "pr.diff.read" "$pr_target" "$file_info"
}

main "$@"
