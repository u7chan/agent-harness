#!/usr/bin/env bash
# Run team-record.mjs, which owns the team-profile user asset.
#
# This wrapper stays thin: it only checks that node is available and forwards
# every argument (including --help and --resolver) to the .mjs. The profile
# selection, the `active` file, the atomic 0600 writes, and the model-spec
# resolver call all live there, and `--help` prints their contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$SCRIPT_DIR/team-record.mjs"

command -v node >/dev/null 2>&1 || {
  printf 'team-record: node is required to run %s\n' "$MJS" >&2
  exit 1
}

exec node "$MJS" "$@"
