#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number state_reason
  number="$(echo "$input" | jq -r '.number')"
  state_reason="$(echo "$input" | jq -r '.state_reason // empty')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.close" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "issue.close" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_state
  current_state="$(echo "$before_state" | jq -r '.state')"

  if [ "$current_state" = "closed" ]; then
    envelope_already_applied "issue.close" "$issue_target" "$before_state"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc \
    --arg state_reason "$state_reason" \
    '{
      state: "closed"
    } + (if $state_reason != "" then {state_reason: $state_reason} else {} end)' > "$body_file"

  local _res; _res="$(call_gh_api "repos/$owner_repo/issues/$number" "PATCH" --input "$body_file")" || {
    gh_cleanup "$body_file"
    envelope_fail "issue.close" "API_ERROR" "Failed to close issue" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "issue.close" "$issue_target" "{}"
    exit 1
  }

  local after_state_status
  after_state_status="$(echo "$after_state" | jq -r '.state')"
  if [ "$after_state_status" != "closed" ]; then
    envelope_unknown_outcome "issue.close" "$issue_target" "$after_state"
    exit 1
  fi

  if [ -n "$state_reason" ] && [ "$state_reason" != "null" ]; then
    local after_reason
    after_reason="$(echo "$after_state" | jq -r '.state_reason // empty')"
    if [ "$after_reason" != "$state_reason" ]; then
      envelope_unknown_outcome "issue.close" "$issue_target" "$after_state"
      exit 1
    fi
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "issue.close" "$issue_target" "$formatted"
}

main "$@"
