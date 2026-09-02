#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local input="$1"

  local title body labels_json assignees_json milestone parent attachments_json
  title="$(echo "$input" | jq -r '.title')"
  body="$(echo "$input" | jq -r '.body // empty')"
  labels_json="$(echo "$input" | jq -c '.labels // null')"
  assignees_json="$(echo "$input" | jq -c '.assignees // null')"
  milestone="$(echo "$input" | jq -c '.milestone // null')"
  parent="$(echo "$input" | jq -r '.parent // empty')"
  attachments_json="$(echo "$input" | jq -c '.attachments // []')"

  local _has_body _has_labels _has_assignees _has_milestone
  _has_body="$(echo "$input" | jq -r 'has("body")')"
  _has_labels="$(echo "$input" | jq -r 'has("labels")')"
  _has_assignees="$(echo "$input" | jq -r 'has("assignees")')"
  _has_milestone="$(echo "$input" | jq -r 'has("milestone")')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "issue.create" "TARGET_ERROR" "Failed to resolve repository target" false
    exit 1
  }
  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local created_number=""
  if [ "$attachments_json" = "[]" ]; then
    local body_file
    body_file="$(gh_make_temp "write-body")"

    jq -nc \
      --arg title "$title" \
      --arg body "$body" \
      --argjson labels "$labels_json" \
      --argjson assignees "$assignees_json" \
      --argjson milestone "$milestone" \
      '{
        title: $title
      } + (if $body != "" then {body: $body} else {} end)
        + (if $labels then {labels: $labels} else {} end)
        + (if $assignees then {assignees: $assignees} else {} end)
        + (if $milestone then {milestone: $milestone} else {} end)' > "$body_file"

    local _saved_retry="${GH_RETRY_MAX:-3}"
    GH_RETRY_MAX=1
    local _res
    _res="$(call_gh_api "repos/$owner_repo/issues" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
      GH_RETRY_MAX="$_saved_retry"
      gh_cleanup "$body_file"
      envelope_unknown_outcome "issue.create" "$target" "{}"
      exit 1
    }
    GH_RETRY_MAX="$_saved_retry"
    gh_cleanup "$body_file"

    created_number="$(echo "$_res" | jq -r '.number')"
  else
    # gh CLI subcommand path (--attach is CLI-only); non-interactive: all
    # required flags are supplied and the body always goes through
    # --body-file. The issue URL is printed even when some uploads fail, so
    # a failed exit still proceeds to read-back verification.
    source "$SCRIPT_DIR/../common/attach.sh"

    if ! attach_prepare "issue.create" "$attachments_json"; then
      exit 1
    fi

    local cli_body_file
    cli_body_file="$(gh_make_temp "cli-body")"
    printf '%s' "$body" > "$cli_body_file"

    local cli_args=("issue" "create" "--repo" "$owner_repo" "--title" "$title" "--body-file" "$cli_body_file")
    local _a
    for _a in "${ATTACH_FLAGS[@]}"; do
      cli_args+=(--attach "$_a")
    done
    if [ "$labels_json" != "null" ]; then
      while IFS= read -r _a; do
        [ -n "$_a" ] && cli_args+=(--label "$_a")
      done < <(echo "$labels_json" | jq -r '.[]')
    fi
    if [ "$assignees_json" != "null" ]; then
      while IFS= read -r _a; do
        [ -n "$_a" ] && cli_args+=(--assignee "$_a")
      done < <(echo "$assignees_json" | jq -r '.[]')
    fi
    if [ "$milestone" != "null" ]; then
      local milestone_name
      milestone_name="$(call_gh_api "repos/$owner_repo/milestones/$(echo "$milestone" | jq -r '.')" 2>/dev/null | jq -r '.title // empty')" || milestone_name=""
      if [ -z "$milestone_name" ]; then
        gh_cleanup "$cli_body_file"
        envelope_fail "issue.create" "API_ERROR" "Failed to resolve milestone" false
        exit 1
      fi
      cli_args+=(--milestone "$milestone_name")
    fi
    if [ -n "$parent" ] && [ "$parent" != "null" ]; then
      cli_args+=(--parent "$parent")
    fi

    local cli_out=""
    cli_out="$(gh "${cli_args[@]}" 2>"$GH_TEMP_DIR/gh-stderr")" || true
    gh_cleanup "$cli_body_file"

    created_number="$(printf '%s\n' "$cli_out" | grep -oE 'https://github.com/[^/]+/[^/]+/issues/[0-9]+' | head -n1 | sed -E 's#.*/##')" || created_number=""
    if [ -z "$created_number" ]; then
      envelope_unknown_outcome "issue.create" "$target" "{}"
      exit 1
    fi
  fi

  local issue_target
  issue_target="$(echo "$target" | jq --argjson number "$created_number" '{type: "issue", repository: .repository, number: $number}')"

  if [ -n "$parent" ] && [ "$parent" != "null" ] && [ "$attachments_json" = "[]" ]; then
    local parent_id
    parent_id="$(call_gh_api "repos/$owner_repo/issues/$parent" | jq -r '.id')" || true
    if [ -n "$parent_id" ] && [ "$parent_id" != "null" ]; then
      local sub_body_file
      sub_body_file="$(gh_make_temp "write-body")"
      echo "$_res" | jq -c '{sub_issue_id: .id}' > "$sub_body_file"
      GH_RETRY_MAX=1
      call_gh_api "repos/$owner_repo/issues/$parent/sub_issues" "POST" --input "$sub_body_file" >/dev/null 2>&1 || true
      GH_RETRY_MAX="$_saved_retry"
      gh_cleanup "$sub_body_file"
    fi
  fi

  local verified
  verified="$(call_gh_api "repos/$owner_repo/issues/$created_number")" || {
    envelope_unknown_outcome "issue.create" "$issue_target" "${_res:-}"
    exit 1
  }

  local _title_ok _body_ok _labels_ok _assignees_ok _milestone_ok
  _title_ok="$(echo "$verified" | jq -r --arg expected "$title" '.title == $expected')"

  _body_ok="true"
  if [ "$_has_body" = "true" ] && [ "$attachments_json" = "[]" ]; then
    _body_ok="$(echo "$verified" | jq -r --arg expected "$body" '
      ((.body // "") == $expected)
    ')"
  fi

  _labels_ok="true"
  if [ "$_has_labels" = "true" ]; then
    _labels_ok="$(echo "$verified" | jq -c --argjson expected "$labels_json" '
      ([.labels[]?.name] | sort) == ($expected | sort)
    ')"
  fi

  _assignees_ok="true"
  if [ "$_has_assignees" = "true" ]; then
    _assignees_ok="$(echo "$verified" | jq -c --argjson expected "$assignees_json" '
      ([.assignees[]?.login] | sort) == ($expected | sort)
    ')"
  fi

  _milestone_ok="true"
  if [ "$_has_milestone" = "true" ]; then
    _milestone_ok="$(echo "$verified" | jq -r --argjson expected "$milestone" '
      (.milestone.number // null) == $expected
    ')"
  fi

  if [ "$attachments_json" != "[]" ]; then
    local expect_body_file verified_body_file
    expect_body_file="$(gh_make_temp "expect-body")"
    verified_body_file="$(gh_make_temp "verify-body")"
    printf '%s' "$body" > "$expect_body_file"
    echo "$verified" | jq -j '.body // ""' > "$verified_body_file"
    if ! attach_verify "$expect_body_file" "$verified_body_file"; then
      gh_cleanup "$expect_body_file"
      gh_cleanup "$verified_body_file"
      envelope_unknown_outcome "issue.create" "$issue_target" "$verified"
      exit 1
    fi
    gh_cleanup "$expect_body_file"
    gh_cleanup "$verified_body_file"
  fi

  if [ "$_title_ok" != "true" ] || [ "$_body_ok" != "true" ] || [ "$_labels_ok" != "true" ] || [ "$_assignees_ok" != "true" ] || [ "$_milestone_ok" != "true" ]; then
    envelope_unknown_outcome "issue.create" "$issue_target" "$verified"
    exit 1
  fi

  if [ -n "$parent" ] && [ "$parent" != "null" ]; then
    local _parent_sub_issues _child_found _created_id
    _parent_sub_issues="$(call_gh_api "repos/$owner_repo/issues/$parent/sub_issues" 2>/dev/null)" || true
    _created_id="$(echo "$verified" | jq -r '.id')"
    _child_found="$(echo "$_parent_sub_issues" | jq -r --argjson cid "$_created_id" '
      if type == "array" then ([.[] | select(.id == $cid)] | length > 0) else false end
    ' 2>/dev/null)" || _child_found="false"
    if [ "$_child_found" != "true" ]; then
      envelope_unknown_outcome "issue.create" "$issue_target" "$verified"
      exit 1
    fi
  fi

  local formatted
  formatted="$(echo "$verified" | jq '{
    id, number, title, state, html_url,
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    milestone: {title: .milestone.title}
  }')"

  envelope_ok "issue.create" "$issue_target" "$formatted"
}

main "$@"
