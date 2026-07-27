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
  after_id="$(echo "$input" | jq -c '.after_id // null')"
  before_id="$(echo "$input" | jq -c '.before_id // null')"

  local _has_after _has_before
  _has_after="$(echo "$input" | jq -r 'has("after_id")')"
  _has_before="$(echo "$input" | jq -r 'has("before_id")')"

  if [ "$_has_after" = "true" ] && [ "$_has_before" = "true" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "Specify either after_id or before_id, not both" false
    exit 1
  fi
  if [ "$_has_after" != "true" ] && [ "$_has_before" != "true" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "Either after_id or before_id is required" false
    exit 1
  fi

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.subissues.reorder" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local current_sub_issues
  current_sub_issues="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues" 2>/dev/null)" || {
    envelope_fail "issue.subissues.reorder" "API_ERROR" "Failed to fetch sub-issues" false
    exit 1
  }

  local _correct_position
  _correct_position="$(echo "$current_sub_issues" | jq -r --argjson sid "$sub_issue_id" --argjson after "$after_id" --argjson before "$before_id" '
    def ids: map(.id);
    def idx: ids | index($sid);
    if idx == null then false
    elif $after then
      ((ids | index($after) // -1) + 1) == idx
    elif $before then
      ((ids | index($before) // -1) - 1) == idx
    else false end
  ' 2>/dev/null)" || _correct_position="false"

  if [ "$_correct_position" = "true" ]; then
    envelope_already_applied "issue.subissues.reorder" "$issue_target" "{}"
    exit 0
  fi

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

  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/sub_issues/priority" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
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

  local _now_correct
  _now_correct="$(echo "$after_state" | jq -r --argjson sid "$sub_issue_id" --argjson after "$after_id" --argjson before "$before_id" '
    def ids: map(.id);
    def idx: ids | index($sid);
    if idx == null then false
    elif $after then
      ((ids | index($after) // -1) + 1) == idx
    elif $before then
      ((ids | index($before) // -1) - 1) == idx
    else false end
  ' 2>/dev/null)" || _now_correct="false"

  if [ "$_now_correct" != "true" ]; then
    envelope_unknown_outcome "issue.subissues.reorder" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '[.[] | {id, number: (.number // .id), title, state: (.state // "open"), html_url}]')"

  envelope_ok "issue.subissues.reorder" "$issue_target" "$formatted"
}

main "$@"
