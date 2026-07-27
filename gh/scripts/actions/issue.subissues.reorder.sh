#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number sub_issue_id after_id before_id
  number="$(echo "$input" | jq -r '.number')"
  sub_issue_id="$(echo "$input" | jq -r '.sub_issue_id')"
  after_id="$(echo "$input" | jq -r '.after_id // empty')"
  before_id="$(echo "$input" | jq -r '.before_id // empty')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.subissues.reorder" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local body_file
  body_file="$(gh_make_temp "write-body")"

  jq -nc \
    --argjson sub_issue_id "$sub_issue_id" \
    --argjson after_id "$after_id" \
    --argjson before_id "$before_id" \
    '{
      sub_issue_id: $sub_issue_id
    } + (if $after_id then {after_id: $after_id} else {} end)
      + (if $before_id then {before_id: $before_id} else {} end)' > "$body_file"

  local _res; _res="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues/priority" "PATCH" --input "$body_file")" || {
    gh_cleanup "$body_file"
    envelope_fail "issue.subissues.reorder" "API_ERROR" "Failed to reorder sub-issues" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues")" || {
    envelope_unknown_outcome "issue.subissues.reorder" "$issue_target" "{}"
    exit 1
  }

  local formatted
  formatted="$(echo "$after_state" | jq '[.[] | {id, number: (.number // .id), title, state: (.state // "open"), html_url}]')"

  envelope_ok "issue.subissues.reorder" "$issue_target" "$formatted"
}

main "$@"
