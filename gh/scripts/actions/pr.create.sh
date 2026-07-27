#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local title body base head
  title="$(echo "$input" | jq -r '.title')"
  head="$(echo "$input" | jq -r '.head')"
  base="$(echo "$input" | jq -r '.base')"

  local _has_body _has_draft _has_maintainer_can_modify _has_head_repository
  _has_body="$(echo "$input" | jq -r 'has("body")')"
  _has_draft="$(echo "$input" | jq -r 'has("draft")')"
  _has_maintainer_can_modify="$(echo "$input" | jq -r 'has("maintainer_can_modify")')"
  _has_head_repository="$(echo "$input" | jq -r 'has("head_repository")')"

  local body draft maintainer_can_modify head_repository
  body="$(echo "$input" | jq -r '.body // empty')"
  draft="$(echo "$input" | jq -c '.draft // null')"
  maintainer_can_modify="$(echo "$input" | jq -c '.maintainer_can_modify // null')"
  head_repository="$(echo "$input" | jq -r '.head_repository // empty')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "pr.create" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local check_owner check_repo head_branch
  if echo "$head" | grep -q ':'; then
    check_owner="${head%%:*}"
    head_branch="${head#*:}"
  else
    check_owner="${owner_repo%%/*}"
    head_branch="$head"
  fi
  check_repo="${owner_repo##*/}"

  if [ -n "$head_repository" ] && [ "$head_repository" != "null" ]; then
    check_owner="${head_repository%%/*}"
    check_repo="${head_repository##*/}"
  fi

  call_gh_api "repos/$check_owner/$check_repo/git/ref/heads/$head_branch" >/dev/null 2>&1 || {
    envelope_fail "pr.create" "BRANCH_ERROR" "Head branch '$head' does not exist on remote" false
    exit 1
  }

  local head_owner="${owner_repo%%/*}"
  if [ -n "$head_repository" ] && [ "$head_repository" != "null" ]; then
    head_owner="${head_repository%%/*}"
  fi

  local existing
  existing="$(call_gh_api "repos/$owner_repo/pulls?head=${head_owner}:${head_branch}&base=${base}&state=open" 2>/dev/null)" || existing="[]"

  local existing_count
  existing_count="$(echo "$existing" | jq 'length')"
  if [ "$existing_count" -gt 0 ]; then
    local existing_pr existing_number
    existing_pr="$(echo "$existing" | jq '.[0]')"
    existing_number="$(echo "$existing_pr" | jq -r '.number')"
    local pr_target
    pr_target="$(echo "$target" | jq --argjson number "$existing_number" '{type: "pull_request", repository: .repository, number: $number}')"
    local formatted
    formatted="$(echo "$existing_pr" | jq '{
      id, number, title, state, html_url, draft,
      head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
      base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
    }')"
    envelope_already_applied "pr.create" "$pr_target" "$formatted"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"

  jq -nc \
    --arg title "$title" \
    --arg head "$head" \
    --arg base "$base" \
    --arg body "$body" \
    --argjson draft "$draft" \
    --argjson maintainer_can_modify "$maintainer_can_modify" \
    --argjson has_body "$_has_body" \
    --argjson has_draft "$_has_draft" \
    --argjson has_maintainer_can_modify "$_has_maintainer_can_modify" \
    --arg head_repo "$head_repository" \
    --argjson has_head_repository "$_has_head_repository" \
    '{
      title: $title,
      head: $head,
      base: $base
    } + (if $has_body and $body != "" then {body: $body} else {} end)
      + (if $has_draft and $draft != null then {draft: $draft} else {} end)
      + (if $has_maintainer_can_modify and $maintainer_can_modify != null then {maintainer_can_modify: $maintainer_can_modify} else {} end)
      + (if $has_head_repository and $head_repo != "" then {head_repo: $head_repo} else {} end)' > "$body_file"

  local _saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local _res
  _res="$(call_gh_api "repos/$owner_repo/pulls" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "pr.create" "$target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$_saved_retry"
  gh_cleanup "$body_file"

  local created_number
  created_number="$(echo "$_res" | jq -r '.number')"

  local pr_target
  pr_target="$(echo "$target" | jq --argjson number "$created_number" '{type: "pull_request", repository: .repository, number: $number}')"

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/$created_number")" || {
    envelope_unknown_outcome "pr.create" "$pr_target" "$_res"
    exit 1
  }

  local _title_ok _body_ok _base_ok
  _title_ok="$(echo "$verified" | jq -r --arg expected "$title" '.title == $expected')"

  _body_ok="true"
  if [ "$_has_body" = "true" ]; then
    _body_ok="$(echo "$verified" | jq -r --arg expected "$body" '
      ((.body // "") == $expected)
    ')"
  fi

  _base_ok="$(echo "$verified" | jq -r --arg expected "$base" '.base.ref == $expected')"

  if [ "$_title_ok" != "true" ] || [ "$_body_ok" != "true" ] || [ "$_base_ok" != "true" ]; then
    envelope_unknown_outcome "pr.create" "$pr_target" "$verified"
    exit 1
  fi

  local formatted
  formatted="$(echo "$verified" | jq '{
    id, number, title, state, html_url, body, draft,
    user: {login: .user.login},
    labels: [.labels[]? | {name: .name}],
    assignees: [.assignees[]? | {login: .login}],
    milestone: {title: .milestone.title},
    created_at, updated_at,
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}}
  }')"

  envelope_ok "pr.create" "$pr_target" "$formatted"
}

main "$@"
