#!/usr/bin/env bash
# Resolve the repository root and its `origin` remote URL, then run
# team-record.mjs.
#
# This wrapper stays thin: like resolve-model-spec.sh locating the pi package
# root, it locates the environment (the repository root and the remote URL that
# names the record) and forwards every other argument to the .mjs, which owns
# the record file and the model-spec resolver call. A root without a resolvable
# `origin` is forwarded as an empty --origin-url, so the .mjs falls back to the
# repository-root key.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$SCRIPT_DIR/team-record.mjs"

usage() {
  cat <<'EOF'
Usage: team-record.sh <resolve|write> [options]

Resolves the repository root (git toplevel of the current directory, or
--repo-root) and its `origin` remote URL, then runs team-record.mjs, which
reads, validates, and writes the approved team record at
${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow/teams/<key>.json.

Options are documented in team-record.mjs; --repo-root and --record skip the
git lookup, and --resolver replaces the model-spec resolver.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

command -v node >/dev/null 2>&1 || {
  printf 'team-record: node is required to run %s\n' "$MJS" >&2
  exit 1
}

args=()
repo_root=""
have_repo_root=0
have_record=0
skip_env=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root | --record)
      flag="$1"
      if [ "$#" -ge 2 ]; then
        args+=("$flag" "$2")
        if [ "$flag" = "--repo-root" ]; then
          repo_root="$2"
          have_repo_root=1
        else
          have_record=1
        fi
        shift 2
      else
        # A dangling flag is forwarded as-is so the .mjs reports the argument
        # error through its one-line output contract.
        args+=("$flag")
        skip_env=1
        shift
      fi
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [ "$skip_env" -eq 0 ] && [ "$have_record" -eq 0 ]; then
  if [ "$have_repo_root" -eq 0 ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
    if [ -z "$repo_root" ]; then
      repo_root="$(pwd -P)"
    fi
    args+=(--repo-root "$repo_root")
  fi
  origin_url=""
  if [ -n "$repo_root" ]; then
    origin_url="$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null)" || origin_url=""
  fi
  args+=(--origin-url "$origin_url")
fi

exec node "$MJS" "${args[@]}"
