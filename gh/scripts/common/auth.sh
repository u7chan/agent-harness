#!/usr/bin/env bash
set -euo pipefail

check_auth() {
  command -v gh >/dev/null || {
    echo "gh CLI is not available." >&2
    return 1
  }

  gh auth status >/dev/null 2>&1 || {
    echo "gh is not authenticated. Run 'gh auth login'." >&2
    return 1
  }

  local host
  host="$(gh auth status 2>&1 | grep -oP '(?<=Logged in to )[^\s]+' || true)"

  if [ -z "$host" ]; then
    echo "Could not determine the gh authenticated host." >&2
    return 1
  fi

  if [ "$host" != "github.com" ]; then
    echo "Unsupported host: $host. Only github.com is supported." >&2
    return 1
  fi

  return 0
}

get_host() {
  gh auth status 2>&1 | grep -oP '(?<=Logged in to )[^\s]+' || true
}
