#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <direct-parent-pane> <completed|blocked> "<body>"\n' "$0" >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_pane() {
  [[ "$1" =~ ^[[:alnum:]_.-]+:[[:alnum:]_.-]+$ ]]
}

[ "$#" -eq 3 ] || usage

parent_pane="$1"
status="$2"
body="$3"

valid_pane "$parent_pane" || usage
case "$status" in
  completed|blocked) ;;
  *) usage ;;
esac
[ -n "$body" ] || usage
[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'

result_message="status: ${status}
body:
${body}"

exec herdr agent prompt "$parent_pane" "$result_message"
