#!/usr/bin/env bash
# Fast-forward the standing checkouts to the remote main branch.
#
# Generalized shape, not a supported harness. Targets come from the environment
# as a colon-separated list of 'path' or 'path=label' entries. A target with
# local changes or a diverged HEAD is skipped while the others continue, and one
# fetch covers every target of the same repository. A run's own worktree is
# never a target: the run owns its branch.
#
# Usage: sync.sh [--dry-run] [--quiet] [--print-targets]
set -euo pipefail

targets_spec="${SYNC_TARGETS:-$HOME/checkout=checkout:$HOME/operator-team=records}"
dry_run=0
quiet=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --quiet) quiet=1 ;;
    --print-targets) printf '%s\n' "$targets_spec" | tr ':' '\n' | sed 's/=.*//'; exit 0 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'sync: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

printf '%s' "$targets_spec" | tr ':' '\n' | while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  path="${entry%%=*}"
  label="${entry#*=}"
  [ -n "$label" ] || label="$path"

  if [ ! -d "$path" ]; then
    printf 'sync(%s): skipped (no such path)\n' "$label" >&2
    continue
  fi

  repo="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$repo" ]; then
    printf 'sync(%s): skipped (not a git repository)\n' "$label" >&2
    continue
  fi

  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    printf 'sync(%s): skipped (local changes; commit or stash first)\n' "$label" >&2
    continue
  fi

  if [ "$dry_run" -eq 0 ]; then
    git -C "$repo" fetch --quiet origin || {
      printf 'sync(%s): skipped (fetch failed)\n' "$label" >&2
      continue
    }
  fi

  head="$(git -C "$path" rev-parse HEAD)"
  target="$(git -C "$path" rev-parse --verify --quiet refs/remotes/origin/main || true)"
  if [ -z "$target" ]; then
    printf 'sync(%s): failed (origin/main is unknown)\n' "$label" >&2
    continue
  fi
  if [ "$head" = "$target" ]; then
    [ "$quiet" -eq 1 ] || printf 'sync(%s): unchanged\n' "$label"
    continue
  fi
  if ! git -C "$path" merge-base --is-ancestor "$head" "$target"; then
    printf 'sync(%s): skipped (HEAD is not an ancestor of origin/main)\n' "$label" >&2
    continue
  fi
  if [ "$dry_run" -eq 1 ]; then
    printf 'sync(%s): [dry-run] %s -> %s\n' "$label" "${head:0:8}" "${target:0:8}"
    continue
  fi
  git -C "$path" merge --ff-only "$target" >/dev/null || {
    printf 'sync(%s): failed (merge --ff-only)\n' "$label" >&2
    continue
  }
  printf 'sync(%s): %s -> %s (+%s)\n' "$label" "${head:0:8}" "${target:0:8}" \
    "$(git -C "$path" rev-list --count "$head..$target")"
done
