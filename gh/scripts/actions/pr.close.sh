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
    envelope_fail "pr.close" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" 2>/dev/null)" || {
    envelope_fail "pr.close" "API_ERROR" "Failed to fetch PR" false
    exit 1
  }

  local current_state
  current_state="$(echo "$before_state" | jq -r '.state')"

  if [ "$current_state" = "closed" ]; then
    local formatted_before
    formatted_before="$(echo "$before_state" | jq '{
      id, number, title, state, html_url, draft,
      head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
      base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
    }')"
    envelope_already_applied "pr.close" "$pr_target" "$formatted_before"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  echo '{"state":"closed"}' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "pr.close" "API_ERROR" "Failed to close PR" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number")" || {
    envelope_unknown_outcome "pr.close" "$pr_target" "{}"
    exit 1
  }

  local after_state_status
  after_state_status="$(echo "$after_state" | jq -r '.state')"
  if [ "$after_state_status" != "closed" ]; then
    envelope_unknown_outcome "pr.close" "$pr_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url, draft,
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
  }')"

  envelope_ok "pr.close" "$pr_target" "$formatted"
}

main "$@"
