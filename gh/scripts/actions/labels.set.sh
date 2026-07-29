#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number labels_json
  number="$(echo "$input" | jq -r '.number')"
  labels_json="$(echo "$input" | jq -c '.labels')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "labels.set" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "labels.set" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_labels
  current_labels="$(echo "$before_state" | jq -c '[.labels[]?.name] | sort')"

  local new_labels_sorted
  new_labels_sorted="$(echo "$labels_json" | jq -c 'sort')"

  if [ "$current_labels" = "$new_labels_sorted" ]; then
    envelope_already_applied "labels.set" "$issue_target" "$before_state"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc --argjson labels "$labels_json" '{labels: $labels}' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/issues/$number/labels" "PUT" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "labels.set" "API_ERROR" "Failed to set labels" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "labels.set" "$issue_target" "{}"
    exit 1
  }

  local _after_labels
  _after_labels="$(echo "$after_state" | jq -c '[.labels[]?.name] | sort')"

  if [ "$_after_labels" != "$new_labels_sorted" ]; then
    envelope_unknown_outcome "labels.set" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "labels.set" "$issue_target" "$formatted"
}

main "$@"
