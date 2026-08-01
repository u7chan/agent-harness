#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$SCRIPT_DIR/../common/envelope.sh"

main() {
  local input="$1"

  local categories permissions query
  categories="$(echo "$input" | jq -c '.categories // []')"
  permissions="$(echo "$input" | jq -c '.permissions // []')"
  query="$(echo "$input" | jq -r '.query // ""')"

  local query_lower
  query_lower="$(echo "$query" | tr '[:upper:]' '[:lower:]')"

  local actions
  actions="$(jq -c \
    --argjson cats "$categories" \
    --argjson perms "$permissions" \
    --arg query_lower "$query_lower" \
    '
    .actions
    | if ($cats | length) > 0 then
        map(select(.category as $c | $cats | index($c)))
      else . end
    | if ($perms | length) > 0 then
        map(select(.permission as $p | $perms | index($p)))
      else . end
    | if $query_lower != "" then
        map(select(
          (.name | ascii_downcase | index($query_lower))
          or (.description | ascii_downcase | index($query_lower))
        ))
      else . end
    | map({name: .name, description: .description, category: .category, permission: .permission})
    ' "$GH_DIR/actions.json")"

  envelope_ok "actions.list" '{"type":"catalog"}' "$actions"
}

main "$@"
