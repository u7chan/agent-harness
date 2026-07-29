#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local reference number reviewers_json
  reference="$(echo "$input" | jq -r '.reference // empty')"
  number="$(echo "$input" | jq -r '.number // empty')"
  reviewers_json="$(echo "$input" | jq -c '.reviewers')"

  local pr_target
  pr_target="$(resolve_pr_target "$reference" "$number")" || {
    envelope_fail "reviewers.remove" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/requested_reviewers" 2>/dev/null)" || {
    envelope_fail "reviewers.remove" "API_ERROR" "Failed to fetch current reviewers" false
    exit 1
  }

  local current_reviewers
  current_reviewers="$(echo "$before_state" | jq -c '[.users[]?.login]')"

  local none_present
  none_present="$(echo "$reviewers_json" | jq -c --argjson current "$current_reviewers" '
    [.[] | select(. as $r | $current | index($r) != null)] | length == 0
  ')"

  if [ "$none_present" = "true" ]; then
    local formatted_before
    formatted_before="$(echo "$before_state" | jq '{
      users: [.users[]? | {login, id, html_url}],
      teams: [.teams[]? | {name, id, slug, html_url}]
    }')"
    envelope_already_applied "reviewers.remove" "$pr_target" "$formatted_before"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson reviewers "$reviewers_json" '{reviewers: $reviewers}' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/requested_reviewers" "DELETE" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "reviewers.remove" "API_ERROR" "Failed to remove reviewers" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/requested_reviewers")" || {
    envelope_unknown_outcome "reviewers.remove" "$pr_target" "{}"
    exit 1
  }

  local _all_removed
  _all_removed="$(echo "$after_state" | jq -c --argjson expected "$reviewers_json" '
    [.users[]?.login] as $after | [$expected[] | select(. as $r | $after | index($r) != null)] | length == 0
  ')"

  if [ "$_all_removed" != "true" ]; then
    envelope_unknown_outcome "reviewers.remove" "$pr_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    users: [.users[]? | {login, id, html_url}],
    teams: [.teams[]? | {name, id, slug, html_url}]
  }')"

  envelope_ok "reviewers.remove" "$pr_target" "$formatted"
}

main "$@"
