#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number name
  number="$(echo "$input" | jq -r '.number')"
  name="$(echo "$input" | jq -r '.name')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "labels.remove" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "labels.remove" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local has_label
  has_label="$(echo "$before_state" | jq -r --arg name "$name" '
    [.labels[]?.name] | index($name) != null
  ')"

  if [ "$has_label" != "true" ]; then
    envelope_already_applied "labels.remove" "$issue_target" "$before_state"
    exit 0
  fi

  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/labels/$name" "DELETE" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    envelope_fail "labels.remove" "API_ERROR" "Failed to remove label" false
    exit 1
  }

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "labels.remove" "$issue_target" "{}"
    exit 1
  }

  local _label_removed
  _label_removed="$(echo "$after_state" | jq -r --arg name "$name" '
    [.labels[]?.name] | index($name) == null
  ')"

  if [ "$_label_removed" != "true" ]; then
    envelope_unknown_outcome "labels.remove" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "labels.remove" "$issue_target" "$formatted"
}

main "$@"
