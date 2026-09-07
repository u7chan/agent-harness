#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

# True only when the target sub-issue and the after/before reference both
# exist in the given sub-issues list and the target already sits directly
# after (after_id) or directly before (before_id) the reference. A missing
# id must never look applied: coercing a null index to -1 made an absent
# after_id turn a head target into "already applied" and let a vanished
# reference pass post-write verification (Issue #172).
position_is_correct() {
  local list_json="$1"
  local sid="$2"
  local after="$3"
  local before="$4"

  printf '%s' "$list_json" | jq -r \
    --argjson sid "$sid" \
    --argjson after "$after" \
    --argjson before "$before" '
    if type != "array" then false
    else
      def ids: map(.id);
      def target_idx: ids | index($sid);
      def ref_idx: if $after != null then ids | index($after) else ids | index($before) end;
      if target_idx == null or ref_idx == null then false
      elif $after != null then target_idx == (ref_idx + 1)
      else target_idx == (ref_idx - 1)
      end
    end
  ' 2>/dev/null || printf 'false'
}

main() {
  local input="$1"

  local number sub_issue_id after_id before_id
  number="$(echo "$input" | jq -r '.number')"
  sub_issue_id="$(echo "$input" | jq -r '.sub_issue_id')"
  after_id="$(echo "$input" | jq -c '.after_id // null')"
  before_id="$(echo "$input" | jq -c '.before_id // null')"

  local _has_after _has_before
  _has_after="$(echo "$input" | jq -r 'has("after_id") and (.after_id | type != "null")')"
  _has_before="$(echo "$input" | jq -r 'has("before_id") and (.before_id | type != "null")')"

  if [ "$_has_after" = "true" ] && [ "$_has_before" = "true" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "Specify either after_id or before_id, not both" false
    exit 1
  fi
  if [ "$_has_after" != "true" ] && [ "$_has_before" != "true" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "Either after_id or before_id is required" false
    exit 1
  fi

  # A sub-issue cannot be reordered relative to itself: the request is
  # meaningless and the API rejects it, so fail before any call.
  if [ "$_has_after" = "true" ] && [ "$after_id" = "$sub_issue_id" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "after_id must not equal sub_issue_id" false
    exit 1
  fi
  if [ "$_has_before" = "true" ] && [ "$before_id" = "$sub_issue_id" ]; then
    envelope_fail "issue.subissues.reorder" "INVALID_INPUT" "before_id must not equal sub_issue_id" false
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

  # Issue #172: the target and the reference (after_id / before_id) must be
  # present in the current sub-issues. An absent id must fail without any
  # PATCH instead of degrading to "already applied" or reaching the API.
  local _target_exists
  _target_exists="$(echo "$current_sub_issues" | jq -r --argjson sid "$sub_issue_id" '
    if type == "array" then ([.[] | select(.id == $sid)] | length > 0) else false end
  ' 2>/dev/null)" || _target_exists="false"

  if [ "$_target_exists" != "true" ]; then
    envelope_fail "issue.subissues.reorder" "NOT_FOUND" "Sub-issue $sub_issue_id not found in the sub-issues of issue #$number" false
    exit 1
  fi

  local _ref_label _ref_id
  if [ "$_has_after" = "true" ]; then
    _ref_label="after_id"
    _ref_id="$after_id"
  else
    _ref_label="before_id"
    _ref_id="$before_id"
  fi

  local _ref_exists
  _ref_exists="$(echo "$current_sub_issues" | jq -r --argjson rid "$_ref_id" '
    if type == "array" then ([.[] | select(.id == $rid)] | length > 0) else false end
  ' 2>/dev/null)" || _ref_exists="false"

  if [ "$_ref_exists" != "true" ]; then
    envelope_fail "issue.subissues.reorder" "NOT_FOUND" "$_ref_label $_ref_id not found in the sub-issues of issue #$number" false
    exit 1
  fi

  local _correct_position
  _correct_position="$(position_is_correct "$current_sub_issues" "$sub_issue_id" "$after_id" "$before_id")"

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
  _now_correct="$(position_is_correct "$after_state" "$sub_issue_id" "$after_id" "$before_id")"

  if [ "$_now_correct" != "true" ]; then
    envelope_unknown_outcome "issue.subissues.reorder" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '[.[] | {id, number: (.number // .id), title, state: (.state // "open"), html_url}]')"

  envelope_ok "issue.subissues.reorder" "$issue_target" "$formatted"
}

main "$@"
