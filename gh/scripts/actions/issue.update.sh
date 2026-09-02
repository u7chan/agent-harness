#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local number attachments_json
  number="$(echo "$input" | jq -r '.number')"
  attachments_json="$(echo "$input" | jq -c '.attachments // []')"

  local _has_title _has_body
  _has_title="$(echo "$input" | jq -r 'has("title")')"
  _has_body="$(echo "$input" | jq -r 'has("body")')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.update" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local before_state
  before_state="$(call_gh_api "repos/$owner_repo/issues/$number" 2>/dev/null)" || {
    envelope_fail "issue.update" "API_ERROR" "Failed to fetch issue" false
    exit 1
  }

  local current_title current_body
  current_title="$(echo "$before_state" | jq -r '.title // ""')"
  current_body="$(echo "$before_state" | jq -r '.body // ""')"

  local new_title new_body
  new_title="$(echo "$input" | jq -r '.title // empty')"
  new_body="$(echo "$input" | jq -r '.body // empty')"

  local eff_title eff_body
  if [ "$_has_title" = "true" ]; then
    eff_title="$new_title"
  else
    eff_title="$current_title"
  fi
  if [ "$_has_body" = "true" ]; then
    eff_body="$new_body"
  else
    eff_body="$current_body"
  fi

  local needs_change=false
  if [ "$_has_title" = "true" ] && [ "$new_title" != "$current_title" ]; then
    needs_change=true
  fi
  if [ "$_has_body" = "true" ] && [ "$new_body" != "$current_body" ]; then
    needs_change=true
  fi
  if [ "$attachments_json" != "[]" ]; then
    needs_change=true
  fi

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  if [ "$needs_change" != "true" ]; then
    envelope_already_applied "issue.update" "$issue_target" "$before_state"
    exit 0
  fi

  if [ "$attachments_json" = "[]" ]; then
    local body_file
    body_file="$(gh_make_temp "write-body")"
    jq -nc \
      --arg title "$new_title" \
      --arg body "$new_body" \
      --argjson has_title "$_has_title" \
      --argjson has_body "$_has_body" \
      '{} + (if $has_title then {title: $title} else {} end)
          + (if $has_body  then {body:  $body}  else {} end)' > "$body_file"

    local _res
    _res="$(call_gh_api "repos/$owner_repo/issues/$number" "PATCH" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
      gh_cleanup "$body_file"
      envelope_fail "issue.update" "API_ERROR" "Failed to update issue" false
      exit 1
    }
    gh_cleanup "$body_file"
  else
    # gh CLI subcommand path (--attach is CLI-only); always passes the
    # effective body through --body-file for deterministic, non-interactive
    # edits. A failed exit is not trusted; read-back verification decides.
    source "$SCRIPT_DIR/../common/attach.sh"

    if ! attach_prepare "issue.update" "$attachments_json"; then
      exit 1
    fi

    local cli_body_file
    cli_body_file="$(gh_make_temp "cli-body")"
    printf '%s' "$eff_body" > "$cli_body_file"

    local cli_args=("issue" "edit" "$number" "--repo" "$owner_repo" "--body-file" "$cli_body_file")
    local _a
    for _a in "${ATTACH_FLAGS[@]}"; do
      cli_args+=(--attach "$_a")
    done
    if [ "$_has_title" = "true" ]; then
      cli_args+=(--title "$new_title")
    fi

    local cli_out=""
    cli_out="$(gh "${cli_args[@]}" 2>"$GH_TEMP_DIR/gh-stderr")" || true
    gh_cleanup "$cli_body_file"
  fi

  local after_state
  after_state="$(call_gh_api "repos/$owner_repo/issues/$number")" || {
    envelope_unknown_outcome "issue.update" "$issue_target" "{}"
    exit 1
  }

  local after_title after_body
  after_title="$(echo "$after_state" | jq -r '.title // ""')"
  after_body="$(echo "$after_state" | jq -r '.body // ""')"

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

  if [ "$after_title" != "$eff_title" ] || [ "$body_matches" != "true" ]; then
    envelope_unknown_outcome "issue.update" "$issue_target" "$after_state"
    exit 1
  fi

  local formatted
  formatted="$(echo "$after_state" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "issue.update" "$issue_target" "$formatted"
}

main "$@"
