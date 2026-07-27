#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number assignees_json
  number="$(echo "$input" | jq -r '.number')"
  assignees_json="$(echo "$input" | jq -c '.assignees')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "assignees.add" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "assignees.add" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_assignees
  current_assignees="$(echo "$before_state" | jq -c '[.assignees[]?.login]')"

  local all_present
  all_present="$(echo "$assignees_json" | jq -c --argjson current "$current_assignees" '
    [.[] | select(. as $a | $current | index($a) == null)] | length == 0
  ')"

  if [ "$all_present" = "true" ]; then
    envelope_already_applied "assignees.add" "$issue_target" "$before_state"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson assignees "$assignees_json" '{assignees: $assignees}' > "$body_file"

  local _res; _res="$(call_gh_api "repos/$owner_repo/issues/$number/assignees" "POST" --input "$body_file")" || {
    gh_cleanup "$body_file"
    envelope_fail "assignees.add" "API_ERROR" "Failed to add assignees" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "assignees.add" "$issue_target" "{}"
    exit 1
  }

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "assignees.add" "$issue_target" "$formatted"
}

main "$@"
