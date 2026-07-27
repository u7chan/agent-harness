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
    envelope_fail "assignees.remove" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "assignees.remove" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_assignees
  current_assignees="$(echo "$before_state" | jq -c '[.assignees[]?.login]')"

  local none_present
  none_present="$(echo "$assignees_json" | jq -c --argjson current "$current_assignees" '
    [.[] | select(. as $a | $current | index($a) != null)] | length == 0
  ')"

  if [ "$none_present" = "true" ]; then
    envelope_already_applied "assignees.remove" "$issue_target" "$before_state"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson assignees "$assignees_json" '{assignees: $assignees}' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/assignees" "DELETE" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "assignees.remove" "API_ERROR" "Failed to remove assignees" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "assignees.remove" "$issue_target" "{}"
    exit 1
  }

  local _all_removed
  _all_removed="$(echo "$after_state" | jq -c --argjson expected "$assignees_json" '
    [.assignees[]?.login] as $after | [$expected[] | select(. as $a | $after | index($a) != null)] | length == 0
  ')"

  if [ "$_all_removed" != "true" ]; then
    envelope_unknown_outcome "assignees.remove" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "assignees.remove" "$issue_target" "$formatted"
}

main "$@"
