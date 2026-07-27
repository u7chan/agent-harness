#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/envelope.sh"
source "$SCRIPT_DIR/http.sh"
source "$SCRIPT_DIR/target.sh"
source "$SCRIPT_DIR/file.sh"

write_api_call() {
  local endpoint="$1" method="$2" body="$3"
  shift 3
  local tmp
  tmp="$(gh_make_temp "write")"
  echo "$body" > "$tmp"
  call_gh_api "$endpoint" "$method" --input "$tmp" "$@"
  local rc=$?
  gh_cleanup "$tmp"
  return $rc
}
