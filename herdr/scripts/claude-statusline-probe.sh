#!/usr/bin/env bash
# Record the launched Claude session's effective model and effort.
#
# Claude Code runs a `statusLine.command` once per refresh and passes the
# statusline JSON on stdin. The shared launcher points that command at this
# script with its per-launch probe file and nonce, so a delegated pane reports
# the values that were actually applied instead of the values that were
# requested: the launcher only accepts a record whose nonce is its own.
#
# The record is one small JSON object, written atomically (temporary file plus
# rename) with mode 0600. `model` and `effort` are empty strings when the
# statusline document omitted them, which the launcher reads as "not
# available" rather than as a value to trust. This script always exits 0: a
# statusline failure must not disturb the session, and the launcher's own
# bounded wait reports a record that never arrived.
#
# Usage: claude-statusline-probe.sh <probe-file> <nonce>
set -uo pipefail

probe="${1:-}"
nonce="${2:-}"
[ -n "$probe" ] && [ -n "$nonce" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)" || exit 0
temporary="${probe}.$$.tmp"
if ! printf '%s' "$input" | jq -c --arg nonce "$nonce" \
  '{nonce: $nonce, model: (.model.id // ""), effort: (.effort.level // "")}' \
  > "$temporary" 2>/dev/null; then
  rm -f "$temporary"
  exit 0
fi
chmod 600 "$temporary" 2>/dev/null || true
mv -f "$temporary" "$probe" 2>/dev/null || rm -f "$temporary"
exit 0
