#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="${1:-}"
  [ -z "$input" ] && input="{}"

  local limit_valid
  limit_valid="$(echo "$input" | jq -r '
    (has("limit") | not) or
    (
      (.limit | type == "number") and
      (.limit == (.limit | floor)) and
      (.limit >= 1) and
      (.limit <= 100)
    )
  ')"
  if [ "$limit_valid" != "true" ]; then
    envelope_fail "workflow-runs.list" "INVALID_PARAMETER" "limit must be an integer between 1 and 100" false
    exit 1
  fi

  local limit
  limit="$(echo "$input" | jq -r '.limit // 20')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "workflow-runs.list" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local data
  data="$(call_gh_api "repos/$owner_repo/actions/runs" "GET" \
    -f "per_page=$limit" -f "page=1")" || {
    envelope_fail "workflow-runs.list" "API_ERROR" "Failed to list workflow runs" false
    exit 1
  }

  local formatted
  formatted="$(echo "$data" | jq -c '[.workflow_runs[]? | {
    name, run_number, head_branch, head_sha, event, status, conclusion,
    html_url, created_at, updated_at
  }]')"

  envelope_ok "workflow-runs.list" "$target" "$formatted"
}

main "$@"
