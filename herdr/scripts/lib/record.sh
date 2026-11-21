#!/usr/bin/env bash
# One `key=value` field of a one-line helper record.
#
# The shared helpers (`team-record.sh`, `claude-auth-status.sh`) print exactly
# one line of space-separated `key=value` tokens and never put whitespace inside
# a value. Sourcing this file gives a caller the same reader, so the token
# grammar is stated once; it must be sourced, not executed.
#
# Sourced by start-agent.sh and worktree-team-start.sh.

# record_field <line> <key>
#
# Print the value of <key>, or return nonzero when the line carries no such
# key. The line is split without globbing, so a value is never expanded into
# filenames, and the first occurrence wins.
record_field() {
  local rest="$1" key="$2" token
  while [ -n "$rest" ]; do
    token="${rest%% *}"
    case "$token" in
      "$key"=*) printf '%s' "${token#*=}"; return 0 ;;
    esac
    case "$rest" in
      *' '*) rest="${rest#* }" ;;
      *) rest='' ;;
    esac
  done
  return 1
}
