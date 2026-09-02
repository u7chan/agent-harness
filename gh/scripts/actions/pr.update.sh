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

  local title body base maintainer_can_modify attachments_json
  title="$(echo "$input" | jq -r '.title // empty')"
  body="$(echo "$input" | jq -r '.body // empty')"
  base="$(echo "$input" | jq -r '.base // empty')"
  maintainer_can_modify="$(echo "$input" | jq -c '.maintainer_can_modify // null')"
  attachments_json="$(echo "$input" | jq -c '.attachments // []')"

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
  current_maintainer_can_modify="$(echo "$before_state" | jq -c '.maintainer_can_modify // null')"

  local eff_title eff_body eff_base eff_maintainer_can_modify
  if [ "$_has_title" = "true" ]; then
    eff_title="$title"
  else
    eff_title="$current_title"
  fi
  if [ "$_has_body" = "true" ]; then
    eff_body="$body"
  else
    eff_body="$current_body"
  fi
  if [ "$_has_base" = "true" ]; then
    eff_base="$base"
  else
    eff_base="$current_base"
  fi
  if [ "$_has_maintainer_can_modify" = "true" ]; then
    eff_maintainer_can_modify="$maintainer_can_modify"
  else
    eff_maintainer_can_modify="$current_maintainer_can_modify"
  fi

  if [ "$attachments_json" != "[]" ] && [ "$_has_maintainer_can_modify" = "true" ]; then
    envelope_fail "pr.update" "ATTACH_INVALID" "maintainer_can_modify cannot be combined with attachments (gh pr edit has no maintainer flag)" false
    exit 1
  fi

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
  if [ "$attachments_json" != "[]" ]; then
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

  if [ "$attachments_json" = "[]" ]; then
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
          + (if $has_base and $base != "" then {base: $base} else (if $has_base then {base: ""} else {} end) end)
          + (if $has_maintainer_can_modify and $maintainer_can_modify != null then {maintainer_can_modify: $maintainer_can_modify} else (if $has_maintainer_can_modify then {maintainer_can_modify: null} else {} end) end)' > "$body_file"

    local _res
    _res="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
      gh_cleanup "$body_file"
      envelope_fail "pr.update" "API_ERROR" "Failed to update PR" false
      exit 1
    }
    gh_cleanup "$body_file"
  else
    # gh CLI subcommand path (--attach is CLI-only); always passes the
    # effective body through --body-file for deterministic, non-interactive
    # edits. A failed exit is not trusted; read-back verification decides.
    source "$SCRIPT_DIR/../common/attach.sh"

    if ! attach_prepare "pr.update" "$attachments_json"; then
      exit 1
    fi

    local cli_body_file
    cli_body_file="$(gh_make_temp "cli-body")"
    printf '%s' "$eff_body" > "$cli_body_file"

    local cli_args=("pr" "edit" "$pr_number" "--repo" "$owner_repo" "--body-file" "$cli_body_file")
    local _a
    for _a in "${ATTACH_FLAGS[@]}"; do
      cli_args+=(--attach "$_a")
    done
    if [ "$_has_title" = "true" ]; then
      cli_args+=(--title "$title")
    fi
    if [ "$_has_base" = "true" ]; then
      cli_args+=(--base "$base")
    fi

    local cli_out=""
    cli_out="$(gh "${cli_args[@]}" 2>"$GH_TEMP_DIR/gh-stderr")" || true
    gh_cleanup "$cli_body_file"
  fi

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/pulls/$pr_number")" || {
    envelope_unknown_outcome "pr.update" "$pr_target" "{}"
    exit 1
  }

  local after_title after_body after_base after_maintainer_can_modify
  after_title="$(echo "$after_state" | jq -r '.title // ""')"
  after_body="$(echo "$after_state" | jq -r '.body // ""')"
  after_base="$(echo "$after_state" | jq -r '.base.ref // ""')"
  after_maintainer_can_modify="$(echo "$after_state" | jq -c '.maintainer_can_modify // null')"

  local body_matches=false
  if [ "$attachments_json" = "[]" ]; then
    if [ "$after_body" = "$eff_body" ]; then
      body_matches=true
    fi
  else
    local expect_body_file verified_body_file
    expect_body_file="$(gh_make_temp "expect-body")"
    verified_body_file="$(gh_make_temp "verify-body")"
    printf '%s' "$eff_body" > "$expect_body_file"
    echo "$after_state" | jq -j '.body // ""' > "$verified_body_file"
    if attach_verify "$expect_body_file" "$verified_body_file"; then
      body_matches=true
    fi
    gh_cleanup "$expect_body_file"
    gh_cleanup "$verified_body_file"
  fi

  if [ "$after_title" != "$eff_title" ] || [ "$body_matches" != "true" ] || [ "$after_base" != "$eff_base" ] || [ "$after_maintainer_can_modify" != "$eff_maintainer_can_modify" ]; then
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
