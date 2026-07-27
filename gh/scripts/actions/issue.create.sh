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
  labels_json="$(echo "$input" | jq -c '.labels')"
  assignees_json="$(echo "$input" | jq -c '.assignees')"
  milestone="$(echo "$input" | jq -c '.milestone')"
  parent="$(echo "$input" | jq -r '.parent // empty')"

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

  local result
  result="$(call_gh_api "repos/$owner_repo/issues" "POST" --input "$body_file" 2>/dev/null)" || {
    gh_cleanup "$body_file"
    envelope_fail "issue.create" "API_ERROR" "Failed to create issue" false
    exit 1
  }
  gh_cleanup "$body_file"

  local created_number
  created_number="$(echo "$result" | jq -r '.number')"

  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    local parent_id
    parent_id="$(call_gh_api "repos/$owner_repo/issues/$parent" | jq -r '.id')" || true
    if [ -n "$parent_id" ] && [ "$parent_id" != "null" ]; then
      local sub_body_file
      sub_body_file="$(gh_make_temp "write-body")"
      echo "$result" | jq -c '{sub_issue_id: .id}' > "$sub_body_file"
      call_gh_api "repos/$owner_repo/issues/$parent/sub_issues" "POST" --input "$sub_body_file" >/dev/null 2>&1 || true
      gh_cleanup "$sub_body_file"
    fi
  fi

  local verified
  verified="$(call_gh_api "repos/$owner_repo/issues/$created_number")" || {
    envelope_unknown_outcome "issue.create" "$target" "$result"
    exit 1
  }

  local formatted
  formatted="$(echo "$verified" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$created_number" '{type: "issue", repository: .repository, number: $number}')"

  envelope_ok "issue.create" "$issue_target" "$formatted"
}

main "$@"
