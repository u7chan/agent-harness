#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"

  local state head base sort_dir direction per_page
  state="$(echo "$input" | jq -r '.state // "open"')"
  head="$(echo "$input" | jq -r '.head // empty')"
  base="$(echo "$input" | jq -r '.base // empty')"
  sort_dir="$(echo "$input" | jq -r '.sort // "created"')"
  direction="$(echo "$input" | jq -r '.direction // "desc"')"
  per_page="$(echo "$input" | jq -r '.per_page // 30')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "prs.list" "TARGET_ERROR" "Failed to resolve target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local filter_args=()
  filter_args+=(-f "state=$state")
  filter_args+=(-f "sort=$sort_dir")
  filter_args+=(-f "direction=$direction")
  [ -n "$head" ] && filter_args+=(-f "head=$head")
  [ -n "$base" ] && filter_args+=(-f "base=$base")

  local raw_data
  raw_data="$(call_gh_api_paginated "repos/$owner_repo/pulls" '[.[]]' "$per_page" "${filter_args[@]}")" || {
    envelope_fail "prs.list" "API_ERROR" "Failed to list PRs" false
    exit 1
  }

  local data
  data="$(echo "$raw_data" | jq -c '[.[] | {
    id, number, title, state, html_url, draft,
    user: {login: .user.login},
    labels: [.labels[].name],
    head: {ref: .head.ref, sha: .head.sha, repo: {full_name: .head.repo.full_name}},
    base: {ref: .base.ref, sha: .base.sha, repo: {full_name: .base.repo.full_name}},
    created_at, updated_at
  }]')"

  envelope_ok "prs.list" "$target" "$data"
}

main "$@"
