#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number milestone
  number="$(echo "$input" | jq -r '.number')"
  milestone="$(echo "$input" | jq -r '.milestone')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "milestone.set" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "milestone.set" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_milestone
  current_milestone="$(echo "$before_state" | jq -r '.milestone.number // empty')"

  if [ "$current_milestone" = "$milestone" ]; then
    envelope_already_applied "milestone.set" "$issue_target" "$before_state"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson milestone "$milestone" '{milestone: $milestone}' > "$body_file"

  local _res; _res="$(call_gh_api "repos/$owner_repo/issues/$number" "PATCH" --input "$body_file")" || {
    gh_cleanup "$body_file"
    envelope_fail "milestone.set" "API_ERROR" "Failed to set milestone" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "milestone.set" "$issue_target" "{}"
    exit 1
  }

  local after_milestone
  after_milestone="$(echo "$after_state" | jq -r '.milestone.number // empty')"

  if [ "$after_milestone" != "$milestone" ]; then
    envelope_unknown_outcome "milestone.set" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "milestone.set" "$issue_target" "$formatted"
}

main "$@"
