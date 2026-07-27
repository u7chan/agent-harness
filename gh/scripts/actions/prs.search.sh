#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"

main() {
  local input="$1"

  local q sort_by order
  q="$(echo "$input" | jq -r '.q')"
  sort_by="$(echo "$input" | jq -r '.sort // empty')"
  order="$(echo "$input" | jq -r '.order // "desc"')"

  local target
  target="$(resolve_target)" || {
    envelope_fail "prs.search" "TARGET_ERROR" "Failed to resolve target" false
    exit 1
  }

  local owner_repo
  owner_repo="$(echo "$target" | jq -r '.repository')"

  local search_q="repo:$owner_repo is:pr ${q}"

  local filter_args=(-f "q=$search_q" -f "order=$order")
  [ -n "$sort_by" ] && filter_args+=(-f "sort=$sort_by")

  local page=1
  local per_page=100
  local all_results="[]"

  local max_results=1000
  local total_count=0

  while :; do
    local page_result
    local page_args=(-f "per_page=$per_page" -f "page=$page" "${filter_args[@]}")

    page_result="$(call_gh_api "search/issues" "GET" "${page_args[@]}" 2>&1)" || {
      echo "$page_result" >&2
      envelope_fail "prs.search" "API_ERROR" "Failed to search PRs" false
      exit 1
    }

    total_count="$(echo "$page_result" | jq -r '.total_count')"
    local items_count
    items_count="$(echo "$page_result" | jq -r '.items | length')"

    local retained
    retained="$(echo "$all_results" | jq 'length')"

    local to_take="$items_count"
    local possible="$((retained + items_count))"
    if [ "$possible" -gt "$max_results" ]; then
      to_take="$((max_results - retained))"
    fi

    local page_items
    page_items="$(echo "$page_result" | jq -c "[.items[:$to_take] | .[] | {
      id, number, title, state, html_url, draft,
      user: {login: .user.login},
      labels: [.labels[].name],
      created_at, updated_at
    }]")"

    all_results="$(echo "$page_items" | jq -c --slurpfile old <(echo "$all_results") '$old[0] + .')"

    local fetched_total
    fetched_total="$(echo "$all_results" | jq 'length')"

    if [ "$fetched_total" -ge "$max_results" ]; then
      break
    fi

    if [ "$items_count" -lt "$per_page" ]; then
      break
    fi

    page=$((page + 1))
  done

  local truncated=false
  if [ "$total_count" -gt "$max_results" ]; then
    truncated=true
  fi

  all_results="$(echo "$all_results" | jq -c \
    --argjson total "$total_count" \
    --argjson truncated "$truncated" \
    '{items: ., truncated: $truncated, total_count: $total}')"

  envelope_ok "prs.search" "$target" "$all_results"
}

main "$@"
