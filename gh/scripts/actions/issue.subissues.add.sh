#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number sub_issue_id
  number="$(echo "$input" | jq -r '.number')"
  sub_issue_id="$(echo "$input" | jq -r '.sub_issue_id')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.subissues.add" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local current_sub_issues
  current_sub_issues="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues" 2>/dev/null)" || {
    envelope_fail "issue.subissues.add" "API_ERROR" "Failed to fetch sub-issues" false
    exit 1
  }

  local already_present
  already_present="$(echo "$current_sub_issues" | jq -r --argjson sid "$sub_issue_id" '
    if type == "array" then
      ([.[] | select(.id == $sid)] | length > 0)
    else false end
  ' 2>/dev/null)" || already_present="false"

  if [ "$already_present" = "true" ]; then
    envelope_already_applied "issue.subissues.add" "$issue_target" "{}"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson sub_issue_id "$sub_issue_id" '{sub_issue_id: $sub_issue_id}' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "issue.subissues.add" "API_ERROR" "Failed to add sub-issue" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues")" || {
    envelope_unknown_outcome "issue.subissues.add" "$issue_target" "{}"
    exit 1
  }

  local now_present
  now_present="$(echo "$after_state" | jq -r --argjson sid "$sub_issue_id" '
    ([.[] | select(.id == $sid)] | length > 0)
  ')"

  if [ "$now_present" != "true" ]; then
    envelope_unknown_outcome "issue.subissues.add" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '[.[] | {id, number: (.number // .id), title, state: (.state // "open"), html_url}]')"

  envelope_ok "issue.subissues.add" "$issue_target" "$formatted"
}

main "$@"
