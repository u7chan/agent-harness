#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

main() {
  local request_file="$1"

  local number thread_id
  number="$(jq -r '.number' "$request_file")"
  thread_id="$(jq -r '.thread_id // empty' "$request_file")"

  local per_page_valid
  per_page_valid="$(jq -r '
    (has("per_page") | not) or
    (
      (.per_page | type == "number") and
      (.per_page == (.per_page | floor)) and
      (.per_page >= 1) and
      (.per_page <= 100)
    )
  ' "$request_file")"
  if [ "$per_page_valid" != "true" ]; then
    envelope_fail "review-threads.read" "INVALID_PARAMETER" "per_page must be an integer between 1 and 100" false
    exit 1
  fi

  local per_page
  per_page="$(jq -r '.per_page // 100' "$request_file")"

  local target
  target="$(resolve_pr_target)" || {
    envelope_fail "review-threads.read" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "$per_page")" || {
    envelope_fail "review-threads.read" "API_ERROR" "Failed to list review comments" false
    exit 1
  }

  local comments_file
  comments_file="$(gh_make_temp "comments")"
  echo "$raw_data" | jq -c '
    [.[] | {id, body, html_url, path, line, commit_id, in_reply_to_id,
             user: {login: .user.login}, created_at, updated_at,
             author_association, resolved: (.resolved // false)}]
  ' > "$comments_file"

  local lookup_file
  lookup_file="$(gh_make_temp "lookup")"
  jq -c 'reduce .[] as $c ({}; .[$c.id | tostring] = $c)' "$comments_file" > "$lookup_file"

  local thread_json
  thread_json="$(jq -c --slurpfile comments "$comments_file" --slurpfile lookup "$lookup_file" '
    $comments[0] as $all
    | $lookup[0] as $idmap
    | def find_root($cid):
        $idmap[$cid|tostring] as $node
        | if $node == null then $cid
          elif $node.in_reply_to_id == null then $cid
          else find_root($node.in_reply_to_id)
          end;
    $all
    | group_by(.id | find_root(.))
    | map({
        thread_id: .[0].id | find_root(.),
        resolved: ([.[] | .resolved] | max // false),
        comments: sort_by(.created_at)
      })
    | unique_by(.thread_id)
  ')" || {
    gh_cleanup "$comments_file"
    gh_cleanup "$lookup_file"
    envelope_fail "review-threads.read" "API_ERROR" "Failed to group review threads" false
    exit 1
  }
  gh_cleanup "$comments_file"
  gh_cleanup "$lookup_file"

  local collection_target
  collection_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{
      type: $type,
      repository: $repo,
      number: $number,
      url: $url
    }')"

  if [ -n "$thread_id" ]; then
    local filtered
    filtered="$(echo "$thread_json" | jq --argjson tid "$thread_id" '
      [ .[] | select(.thread_id == $tid) ]
    ')"
    local wrapper
    wrapper="$(jq -n --argjson threads "$filtered" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  else
    local wrapper
    wrapper="$(jq -n --argjson threads "$thread_json" '{threads: $threads}')"
    envelope_ok "review-threads.read" "$collection_target" "$wrapper"
  fi
}

main "$@"
