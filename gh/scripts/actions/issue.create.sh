#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local title body labels_json assignees_json milestone parent
  title="$(echo "$input" | jq -r '.title')"
  body="$(echo "$input" | jq -r '.body // empty')"
  labels_json="$(echo "$input" | jq -c '.labels // null')"
  assignees_json="$(echo "$input" | jq -c '.assignees // null')"
  milestone="$(echo "$input" | jq -c '.milestone // null')"
  parent="$(echo "$input" | jq -r '.parent // empty')"

  local _has_body _has_labels _has_assignees _has_milestone
  _has_body="$(echo "$input" | jq -r 'has("body")')"
  _has_labels="$(echo "$input" | jq -r 'has("labels")')"
  _has_assignees="$(echo "$input" | jq -r 'has("assignees")')"
  _has_milestone="$(echo "$input" | jq -r 'has("milestone")')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.create" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local body_file
  body_file="$(gh_make_temp "write-body")"

  jq -nc \
    --arg title "$title" \
    --arg body "$body" \
    --argjson labels "$labels_json" \
    --argjson assignees "$assignees_json" \
    --argjson milestone "$milestone" \
    '{
      title: $title
    } + (if $body != "" then {body: $body} else {} end)
      + (if $labels then {labels: $labels} else {} end)
      + (if $assignees then {assignees: $assignees} else {} end)
      + (if $milestone then {milestone: $milestone} else {} end)' > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "issue.create" "$target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local created_number
  created_number="$(echo "$_res" | jq -r '.number')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$created_number" '{type: "issue", repository: .repository, number: $number}')"

  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    local parent_id
    parent_id="$(call_gh_api "repos/$owner_repo/issues/$parent" | jq -r '.id')" || true
    if [ -n "$parent_id" ] && [ "$parent_id" != "null" ]; then
      local sub_body_file
      sub_body_file="$(gh_make_temp "write-body")"
      echo "$_res" | jq -c '{sub_issue_id: .id}' > "$sub_body_file"
      GH_RETRY_MAX=1
      call_gh_api "repos/$owner_repo/issues/$parent/sub_issues" "POST" --input "$sub_body_file" >/dev/null 2>&1 || true
      GH_RETRY_MAX="$_saved_retry"
      gh_cleanup "$sub_body_file"
    fi
  fi

  local verified
  verified="$(call_gh_api "repos/$owner_repo/issues/$created_number")" || {
    envelope_unknown_outcome "issue.create" "$issue_target" "$_res"
    exit 1
  }

  local _title_ok _body_ok _labels_ok _assignees_ok _milestone_ok
  _title_ok="$(echo "$verified" | jq -r --arg expected "$title" '.title == $expected')"

  _body_ok="true"
  if [ "$_has_body" = "true" ]; then
    _body_ok="$(echo "$verified" | jq -r --arg expected "$body" '
      ((.body // "") == $expected)
    ')"
  fi

  _labels_ok="true"
  if [ "$_has_labels" = "true" ]; then
    _labels_ok="$(echo "$verified" | jq -c --argjson expected "$labels_json" '
      ([.labels[]?.name] | sort) == ($expected | sort)
    ')"
  fi

  _assignees_ok="true"
  if [ "$_has_assignees" = "true" ]; then
    _assignees_ok="$(echo "$verified" | jq -c --argjson expected "$assignees_json" '
      ([.assignees[]?.login] | sort) == ($expected | sort)
    ')"
  fi

  _milestone_ok="true"
  if [ "$_has_milestone" = "true" ]; then
    _milestone_ok="$(echo "$verified" | jq -r --argjson expected "$milestone" '
      (.milestone.number // null) == $expected
    ')"
  fi

  if [ "$_title_ok" != "true" ] || [ "$_body_ok" != "true" ] || [ "$_labels_ok" != "true" ] || [ "$_assignees_ok" != "true" ] || [ "$_milestone_ok" != "true" ]; then
    envelope_unknown_outcome "issue.create" "$issue_target" "$verified"
    exit 1
  fi

  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    local _parent_sub_issues _child_found _created_id
    _parent_sub_issues="$(call_gh_api "repos/$owner_repo/issues/$parent/sub_issues" 2>/dev/null)" || true
    _created_id="$(echo "$verified" | jq -r '.id')"
    _child_found="$(echo "$_parent_sub_issues" | jq -r --argjson cid "$_created_id" '
      if type == "array" then ([.[] | select(.id == $cid)] | length > 0) else false end
    ' 2>/dev/null)" || _child_found="false"
    if [ "$_child_found" != "true" ]; then
      envelope_unknown_outcome "issue.create" "$issue_target" "$verified"
      exit 1
    fi
  fi

  local formatted
  formatted="$(echo "$verified" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "issue.create" "$issue_target" "$formatted"
}

main "$@"
