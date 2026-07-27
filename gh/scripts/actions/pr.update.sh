#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local reference number
  reference="$(echo "$input" | jq -r '.reference // empty')"
  number="$(echo "$input" | jq -r '.number // empty')"

  local _has_title _has_body _has_base _has_maintainer_can_modify
  _has_title="$(echo "$input" | jq -r 'has("title")')"
  _has_body="$(echo "$input" | jq -r 'has("body")')"
  _has_base="$(echo "$input" | jq -r 'has("base")')"
  _has_maintainer_can_modify="$(echo "$input" | jq -r 'has("maintainer_can_modify")')"

  local title body base maintainer_can_modify
  title="$(echo "$input" | jq -r '.title // empty')"
  body="$(echo "$input" | jq -r '.body // empty')"
  base="$(echo "$input" | jq -r '.base // empty')"
  maintainer_can_modify="$(echo "$input" | jq -c '.maintainer_can_modify // null')"

  local pr_target
  pr_target="$(resolve_pr_target "$reference" "$number")" || {
    envelope_fail "pr.update" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }

  local owner_repo pr_number
  owner_repo="$(echo "$pr_target" | jq -r '.repository')"
  pr_number="$(echo "$pr_target" | jq -r '.number')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" 2>/dev/null)" || {
    envelope_fail "pr.update" "API_ERROR" "Failed to fetch PR" false
    exit 1
  }

  local current_title current_body current_base current_maintainer_can_modify
  current_title="$(echo "$before_state" | jq -r '.title // ""')"
  current_body="$(echo "$before_state" | jq -r '.body // ""')"
  current_base="$(echo "$before_state" | jq -r '.base.ref // ""')"
  current_maintainer_can_modify="$(echo "$before_state" | jq -r '.maintainer_can_modify // null')"

  local needs_change=false
  if [ "$_has_title" = "true" ] && [ "$title" != "$current_title" ]; then
    needs_change=true
  fi
  if [ "$_has_body" = "true" ] && [ "$body" != "$current_body" ]; then
    needs_change=true
  fi
  if [ "$_has_base" = "true" ] && [ "$base" != "$current_base" ]; then
    needs_change=true
  fi
  if [ "$_has_maintainer_can_modify" = "true" ] && [ "$maintainer_can_modify" != "$current_maintainer_can_modify" ]; then
    needs_change=true
  fi

  if [ "$needs_change" != "true" ]; then
    local formatted_before
    formatted_before="$(echo "$before_state" | jq '{
      id, number, title, state, html_url, body, draft,
      user: {login: .user.login},
      labels: [.labels[]? | {name: .name}],
      assignees: [.assignees[]? | {login: .login}],
      milestone: {title: .milestone.title},
      created_at, updated_at,
      head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
      base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
    }')"
    envelope_already_applied "pr.update" "$pr_target" "$formatted_before"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -nc \
    --arg title "$title" \
    --arg body "$body" \
    --arg base "$base" \
    --argjson maintainer_can_modify "$maintainer_can_modify" \
    --argjson has_title "$_has_title" \
    --argjson has_body "$_has_body" \
    --argjson has_base "$_has_base" \
    --argjson has_maintainer_can_modify "$_has_maintainer_can_modify" \
    '{} + (if $has_title then {title: $title} else {} end)
        + (if $has_body and $body != "" then {body: $body} else (if $has_body then {body: ""} else {} end) end)
        + (if $has_base and $base != "" then {base: $base} else {} end)
        + (if $has_maintainer_can_modify and $maintainer_can_modify != null then {maintainer_can_modify: $maintainer_can_modify} else (if $has_maintainer_can_modify then {maintainer_can_modify: null} else {} end) end)' > "$body_file"

  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    gh_cleanup "$body_file"
    envelope_fail "pr.update" "API_ERROR" "Failed to update PR" false
    exit 1
  }
  gh_cleanup "$body_file"

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number")" || {
    envelope_unknown_outcome "pr.update" "$pr_target" "{}"
    exit 1
  }

  local eff_title eff_body eff_base
  eff_title="${title:-$current_title}"
  eff_body="$(echo "$input" | jq -r 'if has("body") then .body // "" else empty end')"
  if [ -z "$eff_body" ] && [ "$_has_body" != "true" ]; then
    eff_body="$current_body"
  fi
  eff_base="${base:-$current_base}"

  local after_title after_body after_base
  after_title="$(echo "$after_state" | jq -r '.title // ""')"
  after_body="$(echo "$after_state" | jq -r '.body // ""')"
  after_base="$(echo "$after_state" | jq -r '.base.ref // ""')"

  if [ "$after_title" != "$eff_title" ] || [ "$after_body" != "$eff_body" ] || [ "$after_base" != "$eff_base" ]; then
    envelope_unknown_outcome "pr.update" "$pr_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url, body, draft,
    user: {login: .user.login},
    labels: [.labels[]? | {name: .name}],
    assignees: [.assignees[]? | {login: .login}],
    milestone: {title: .milestone.title},
    created_at, updated_at,
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
  }')"

  envelope_ok "pr.update" "$pr_target" "$formatted"
}

main "$@"
