#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/manifest.sh"

main() {
  local manifests
  manifests="$(herdr_manifest_list)"

  if [ "$manifests" = "[]" ]; then
    envelope_ok "team.list" '{"type":"team-collection"}' '[]'
    return 0
  fi

  local summaries
  summaries="$(echo "$manifests" | jq -c '[.[] | {
    team_id: .team_id,
    workspace_id: .workspace_id,
    member_count: (.members | length),
    created_at: .created_at,
    status: .status
  }]')"

  envelope_ok "team.list" '{"type":"team-collection"}' "$summaries"
}

main "$@"
