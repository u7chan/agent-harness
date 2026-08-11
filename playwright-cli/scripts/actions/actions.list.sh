#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ACTIONS_JSON="${PW_ACTIONS_JSON:-$PW_ROOT/actions.json}"
source "$SCRIPT_DIR/../common/envelope.sh"

main() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    input='{}'
  fi

  local categories permissions query
  categories="$(jq -c '.categories // []' <<< "$input")"
  permissions="$(jq -c '.permissions // []' <<< "$input")"
  query="$(jq -r '.query // ""' <<< "$input")"

  local actions
  actions="$(jq -c \
    --argjson cats "$categories" \
    --argjson perms "$permissions" \
    --arg query_arg "$query" \
    '
    .actions
    | if ($cats | length) > 0 then
        map(select(.category as $c | $cats | index($c)))
      else . end
    | if ($perms | length) > 0 then
        map(select(.permission as $p | $perms | index($p)))
      else . end
    | if $query_arg != "" then
        map(select(
          (.name | ascii_downcase | index($query_arg | ascii_downcase))
          or (.description | ascii_downcase | index($query_arg | ascii_downcase))
        ))
      else . end
    | map({name: .name, description: .description, category: .category, permission: .permission})
    | sort_by(.name)
    ' "$ACTIONS_JSON")"

  pw_envelope_ok "$actions" "[]" "null"
}

main "$@"
