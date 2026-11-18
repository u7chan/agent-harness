#!/usr/bin/env bash
# Harness-neutral distribution of this repository's skills.
#
# The served skill set is one immutable tree per revision below
# <dist-root>/releases/<sha>, with <dist-root>/current a symlink to the tree in
# service.  A harness reads the skills through per-skill links in its own skill
# directory, so a switch changes every reader with one rename and a rollback is
# the same operation.
#
# The command never calls pi, claude, codex, or any other harness CLI: it needs
# only git, tar, jq, and GNU coreutils.  The fetch source is a bare mirror under
# <dist-root>/git, so uncommitted work in a development checkout is never on a
# serving path.
#
# Usage:
#   dist.sh update [--sha <full-sha>] [--pr <url>] [--link-dir <dir>]...
#                  [--no-link] [--replace-links]
#   dist.sh rollback <full-sha> [--pr <url>] [--link-dir <dir>]...
#                  [--no-link] [--replace-links]
#   dist.sh status [--link-dir <dir>]...
#   dist.sh verify [--expect <full-sha>] [--link-dir <dir>]... [--no-link]
#
# Environment:
#   AGENT_HARNESS_HOME      distribution root; default
#                           ${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness
#   AGENT_HARNESS_REPO_URL  fetch source; default
#                           https://github.com/u7chan/agent-harness.git
#
# Exit status: 0 success, 1 failure (the served revision is left unchanged
# unless the output says otherwise), 2 usage error.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  dist.sh update [--sha <full-sha>] [--pr <url>] [--link-dir <dir>]...
                 [--no-link] [--replace-links]
  dist.sh rollback <full-sha> [--pr <url>] [--link-dir <dir>]...
                 [--no-link] [--replace-links]
  dist.sh status [--link-dir <dir>]... [--no-link]
  dist.sh verify [--expect <full-sha>] [--link-dir <dir>]... [--no-link]

Environment:
  AGENT_HARNESS_HOME      distribution root; default
                          ${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness
  AGENT_HARNESS_REPO_URL  fetch source; default
                          https://github.com/u7chan/agent-harness.git
EOF
  exit 2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ROOT="${AGENT_HARNESS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness}"
REPO_URL="${AGENT_HARNESS_REPO_URL:-https://github.com/u7chan/agent-harness.git}"
GIT_DIR_PATH="$ROOT/git"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
RECORD="$ROOT/rollout.jsonl"
MAIN_REF="refs/remotes/origin/main"
DEFAULT_LINK_DIR="$HOME/.agents/skills"

export GIT_TERMINAL_PROMPT=0

COMMAND=""
WANT_SHA=""
PR_URL=""
EXPECT_SHA=""
LINK_DIRS=""
NO_LINK=0
REPLACE_LINKS=0
STAGING=""
SWITCH_TMP=""

cleanup() {
  if [ -n "$STAGING" ]; then rm -rf "$STAGING"; fi
  if [ -n "$SWITCH_TMP" ]; then rm -f "$SWITCH_TMP"; fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    update|rollback|status|verify)
      [ -z "$COMMAND" ] || usage
      COMMAND="$1"
      shift
      ;;
    --sha)
      [ "$#" -ge 2 ] || usage
      WANT_SHA="$2"
      shift 2
      ;;
    --pr)
      [ "$#" -ge 2 ] || usage
      PR_URL="$2"
      shift 2
      ;;
    --expect)
      [ "$#" -ge 2 ] || usage
      EXPECT_SHA="$2"
      shift 2
      ;;
    --link-dir)
      [ "$#" -ge 2 ] || usage
      LINK_DIRS="$LINK_DIRS$2"$'\n'
      shift 2
      ;;
    --no-link)
      NO_LINK=1
      shift
      ;;
    --replace-links)
      REPLACE_LINKS=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ "$COMMAND" = rollback ] && [ -z "$WANT_SHA" ]; then
        WANT_SHA="$1"
        shift
        continue
      fi
      usage
      ;;
  esac
done

[ -n "$COMMAND" ] || usage

require_full_sha() {
  local value="$1" label="$2"
  case "$value" in
    *[!0-9a-f]*) die "invalid $label: expected a lowercase full SHA, got '$value'" ;;
  esac
  [ "${#value}" -eq 40 ] || die "invalid $label: expected a 40-character SHA, got '$value'"
}

require_absolute_root() {
  case "$ROOT" in
    /*) ;;
    *) die "AGENT_HARNESS_HOME must be an absolute path: $ROOT" ;;
  esac
}

# --- Repository and revision -------------------------------------------------

ensure_git_repo() {
  if [ ! -d "$GIT_DIR_PATH" ]; then
    mkdir -p "$GIT_DIR_PATH"
    git -C "$GIT_DIR_PATH" init --quiet --bare
  fi
  local url
  if url=$(git -C "$GIT_DIR_PATH" remote get-url origin 2>/dev/null); then
    [ "$url" = "$REPO_URL" ] ||
      die "origin mismatch: $GIT_DIR_PATH points at $url, not $REPO_URL"
  else
    git -C "$GIT_DIR_PATH" remote add origin "$REPO_URL"
  fi
}

fetch_main() {
  git -C "$GIT_DIR_PATH" fetch --quiet --no-tags origin \
    "+refs/heads/main:$MAIN_REF" || die "fetch failed: $REPO_URL"
}

gate_main() {
  local sha="$1"
  [ -d "$GIT_DIR_PATH" ] || die "gate failed: $GIT_DIR_PATH is missing"
  git -C "$GIT_DIR_PATH" rev-parse --verify --quiet "$MAIN_REF^{commit}" >/dev/null ||
    die "gate failed: $MAIN_REF is missing; fetch before rolling back"
  git -C "$GIT_DIR_PATH" cat-file -e "$sha^{commit}" 2>/dev/null ||
    die "gate failed: $sha is not in $GIT_DIR_PATH"
  git -C "$GIT_DIR_PATH" merge-base --is-ancestor "$sha" "$MAIN_REF" ||
    die "gate failed: $sha is not reachable from $MAIN_REF"
}

# --- Releases ----------------------------------------------------------------

release_verify() {
  local tree="$1" skill
  [ -d "$tree" ] || return 1
  [ -f "$tree/skills.json" ] || return 1
  [ ! -e "$tree/.git" ] || return 1
  jq -e '(.schema_version == 1) and ((.skills | type) == "array") and ((.skills | length) > 0)' \
    "$tree/skills.json" >/dev/null 2>&1 || return 1
  while IFS= read -r skill; do
    case "$skill" in
      ""|*/*|.*) return 1 ;;
    esac
    [ -f "$tree/$skill/SKILL.md" ] || return 1
  done < <(jq -r '.skills[]' "$tree/skills.json")
}

prepare_release() {
  local sha="$1" dest="$RELEASES/$1"
  if [ -d "$dest" ]; then
    release_verify "$dest" || die "release verification failed: $dest (remove it and retry)"
    printf 'release=reused\n'
    return 0
  fi

  STAGING="$(mktemp -d "$ROOT/.staging.XXXXXX")"
  git -C "$GIT_DIR_PATH" archive --format=tar "$sha" | tar -xf - -C "$STAGING" ||
    die "cannot export $sha from $GIT_DIR_PATH"
  release_verify "$STAGING" ||
    die "release verification failed for $sha: the tree needs skills.json and a SKILL.md for every listed skill"
  # rename(2) publishes the tree in one step and fails instead of nesting when a
  # concurrent run already published the same revision.
  if mv -T "$STAGING" "$dest" 2>/dev/null; then
    STAGING=""
    printf 'release=created\n'
  elif [ -d "$dest" ] && release_verify "$dest"; then
    rm -rf "$STAGING"
    STAGING=""
    printf 'release=reused\n'
  else
    die "cannot publish release $sha"
  fi
}

current_rev() {
  [ -L "$CURRENT" ] || return 1
  local target rev
  target="$(readlink "$CURRENT")"
  case "$target" in
    releases/*) rev="${target#releases/}" ;;
    *) return 1 ;;
  esac
  [ "${#rev}" -eq 40 ] || return 1
  [ -d "$CURRENT" ] || return 1
  printf '%s\n' "$rev"
}

switch_current() {
  local sha="$1"
  SWITCH_TMP="$ROOT/.current.$$"
  ln -s "releases/$sha" "$SWITCH_TMP"
  mv -T "$SWITCH_TMP" "$CURRENT" || die "cannot switch $CURRENT to $sha"
  SWITCH_TMP=""
}

# --- Rollout record ----------------------------------------------------------

record_last() {
  [ -f "$RECORD" ] || return 1
  local last
  last="$(tail -n 1 "$RECORD")"
  [ -n "$last" ] || return 1
  jq -e '(.sha | type == "string") and (.sha | length == 40)' <<<"$last" >/dev/null 2>&1 ||
    die "rollout record is corrupt: $RECORD"
  jq -r '.sha' <<<"$last"
}

record_append() {
  local sha="$1" previous="$2" pr="$3" line
  (umask 077; : >>"$RECORD")
  line="$(jq -nc \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sha "$sha" \
    --arg previous "$previous" \
    --arg pr "$pr" \
    '{at: $at, sha: $sha, previous: (if $previous == "" then null else $previous end),
      pr: (if $pr == "" then null else $pr end)}')"
  printf '%s\n' "$line" >>"$RECORD"
}

# An already-serving revision with no record is the baseline: record it before
# switching away, so the record keeps naming what is installed.
record_ensure_baseline() {
  [ -f "$RECORD" ] && return 0
  local rev
  rev="$(current_rev)" || return 0
  release_verify "$CURRENT" || die "current release is invalid: $CURRENT"
  record_append "$rev" "" ""
}

# --- Harness links -----------------------------------------------------------

link_dirs() {
  if [ -n "$LINK_DIRS" ]; then
    printf '%s' "$LINK_DIRS"
  else
    printf '%s\n' "$DEFAULT_LINK_DIR"
  fi
}

manifest_skills() {
  jq -r '.skills[]' "$CURRENT/skills.json"
}

in_manifest() {
  local name="$1" skill
  while IFS= read -r skill; do
    [ "$skill" = "$name" ] && return 0
  done < <(manifest_skills)
  return 1
}

link_is_ours() {
  case "$1" in
    "$CURRENT"/*|"$RELEASES"/*|releases/*) return 0 ;;
  esac
  return 1
}

reconcile_link_dir() {
  local dir="$1" skill link want cur entry name count=0 removed=0
  while IFS= read -r skill; do
    link="$dir/$skill"
    want="$CURRENT/$skill"
    if [ -L "$link" ]; then
      cur="$(readlink "$link")"
      if [ "$cur" = "$want" ]; then
        count=$((count + 1))
        continue
      fi
      if link_is_ours "$cur"; then
        :
      elif [ "$REPLACE_LINKS" = 1 ]; then
        :
      else
        die "refusing to replace a foreign symlink: $link -> $cur (pass --replace-links to migrate)"
      fi
      SWITCH_TMP="$link.tmp.$$"
      ln -s "$want" "$SWITCH_TMP"
      mv -T "$SWITCH_TMP" "$link" || die "cannot replace link: $link"
      SWITCH_TMP=""
    elif [ -e "$link" ]; then
      die "refusing to replace a real path: $link"
    else
      ln -s "$want" "$link" || die "cannot create link: $link"
    fi
    count=$((count + 1))
  done < <(manifest_skills)

  # Drop links this command created for skills that are no longer served.
  for entry in "$dir"/*; do
    [ -L "$entry" ] || continue
    name="${entry##*/}"
    link_is_ours "$(readlink "$entry")" || continue
    if ! in_manifest "$name"; then
      unlink "$entry" || die "cannot remove stale link: $entry"
      removed=$((removed + 1))
    fi
  done

  printf '%s %s' "$count" "$removed"
}

# Reads only: reports the first inconsistency and returns 1. A link must
# resolve to the served tree, not merely to some directory with a SKILL.md.
links_problem() {
  local dir skill link want
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    while IFS= read -r skill; do
      link="$dir/$skill"
      want="$CURRENT/$skill"
      if [ ! -e "$link" ]; then
        printf '%s is missing (want %s)\n' "$link" "$want"
        return 1
      fi
      if [ "$(readlink -f "$link")" != "$(readlink -f "$want")" ]; then
        printf '%s does not resolve to %s\n' "$link" "$want"
        return 1
      fi
    done < <(manifest_skills)
  done < <(link_dirs)
  return 0
}

reconcile_links() {
  if [ "$NO_LINK" = 1 ]; then
    printf 'links=skipped reason=no-link\n'
    return 0
  fi
  local dir counts
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ ! -d "$dir" ]; then
      printf 'link-dir=%s status=skipped reason=missing\n' "$dir"
      continue
    fi
    counts="$(reconcile_link_dir "$dir")"
    printf 'link-dir=%s status=ok skills=%s removed=%s\n' \
      "$dir" "${counts% *}" "${counts#* }"
  done < <(link_dirs)
}

verify_links() {
  [ "$NO_LINK" = 1 ] && return 0
  local dir count=0 problem
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] && count=$((count + 1))
  done < <(link_dirs)
  [ "$count" -gt 0 ] || die "no link directory exists; create one or pass --no-link"
  problem="$(links_problem)" || die "link verification failed: $problem"
}

# --- Checks ------------------------------------------------------------------

verify_release_and_links() {
  local expect="$1" rev
  [ -L "$CURRENT" ] || die "no current release under $ROOT"
  rev="$(current_rev)" || die "$CURRENT is not a release link"
  release_verify "$CURRENT" || die "release verification failed: $CURRENT"
  if [ -n "$expect" ]; then
    [ "$rev" = "$expect" ] || die "revision mismatch: current=$rev expected=$expect"
  fi
  verify_links
  printf '%s\n' "$rev"
}

verify_record() {
  local rev="$1" last
  if [ -f "$RECORD" ]; then
    last="$(record_last)" || die "rollout record is corrupt: $RECORD"
    [ "$last" = "$rev" ] || die "rollout record mismatch: record=$last current=$rev"
  fi
}

# --- Commands ----------------------------------------------------------------

apply_revision() {
  local target="$1" before rev
  before="$(current_rev)" || before=""

  if [ "$before" = "$target" ] && release_verify "$CURRENT"; then
    record_ensure_baseline
    reconcile_links
    verify_links
    verify_record "$target"
    printf 'state=already-current\nprevious=%s\n' "$before"
    printf 'revision=%s\n' "$target"
    return 0
  fi

  record_ensure_baseline
  switch_current "$target"
  if ! (reconcile_links && verify_links); then
    if [ -n "$before" ]; then
      switch_current "$before"
      die "post-switch verification failed; restored $before"
    fi
    unlink "$CURRENT"
    die "post-switch verification failed; no current release is served"
  fi
  record_append "$target" "$before" "$PR_URL"
  verify_record "$target"
  printf 'state=%s\nprevious=%s\n' \
    "$([ "$COMMAND" = rollback ] && printf 'rolled-back' || printf 'updated')" \
    "$([ -n "$before" ] && printf '%s' "$before" || printf 'null')"
  printf 'revision=%s\n' "$target"
}

run_update() {
  require_absolute_root
  mkdir -p "$ROOT" "$RELEASES"
  ensure_git_repo
  fetch_main

  local target
  if [ -n "$WANT_SHA" ]; then
    require_full_sha "$WANT_SHA" "revision"
    target="$(git -C "$GIT_DIR_PATH" rev-parse --verify --quiet "$WANT_SHA^{commit}")" ||
      die "unknown revision: $WANT_SHA is not in $GIT_DIR_PATH"
  else
    target="$(git -C "$GIT_DIR_PATH" rev-parse --verify --quiet "$MAIN_REF^{commit}")" ||
      die "cannot resolve $MAIN_REF"
  fi
  gate_main "$target"
  prepare_release "$target"
  apply_revision "$target"
}

run_rollback() {
  [ -n "$WANT_SHA" ] || usage
  require_full_sha "$WANT_SHA" "revision"
  require_absolute_root

  # A release that is already on disk is switched without touching the network,
  # so a rollback stays available while the fetch source is unreachable.
  if [ -d "$RELEASES/$WANT_SHA" ]; then
    release_verify "$RELEASES/$WANT_SHA" ||
      die "release verification failed: $RELEASES/$WANT_SHA (remove it and retry)"
    printf 'release=reused\n'
    gate_main "$WANT_SHA"
  else
    mkdir -p "$ROOT" "$RELEASES"
    ensure_git_repo
    fetch_main
    gate_main "$WANT_SHA"
    prepare_release "$WANT_SHA"
  fi
  apply_revision "$WANT_SHA"
}

run_status() {
  local rev="" release=absent record_sha=none record_match=no links=ok dir existing=0
  printf 'root=%s\n' "$ROOT"
  if rev="$(current_rev)"; then
    printf 'installed=yes\n'
    printf 'revision=%s\n' "$rev"
    if release_verify "$CURRENT"; then release=ok; else release=invalid; fi
  else
    printf 'installed=no\n'
  fi
  printf 'release=%s\n' "$release"
  if [ -f "$RECORD" ]; then
    record_sha="$(record_last)" || die "rollout record is corrupt: $RECORD"
    if [ -n "$rev" ] && [ "$record_sha" = "$rev" ]; then record_match=yes; fi
  fi
  printf 'record=%s\n' "$record_sha"
  printf 'record-match=%s\n' "$record_match"
  if [ -n "$rev" ] && [ "$release" = ok ]; then
    if [ "$NO_LINK" = 0 ]; then
      while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] && existing=$((existing + 1))
      done < <(link_dirs)
      if [ "$existing" -eq 0 ]; then
        links=absent
      elif ! links_problem >/dev/null; then
        links=drift
      fi
    fi
  fi
  printf 'links=%s\n' "$links"

  [ -n "$rev" ] && [ "$release" = ok ] && [ "$record_match" = yes ] && [ "$links" != drift ] ||
    die "distribution is not consistent (see the fields above)"
}

run_verify() {
  local rev
  rev="$(verify_release_and_links "$EXPECT_SHA")" || exit 1
  verify_record "$rev"
  printf 'revision=%s\nverify=ok\n' "$rev"
}

case "$COMMAND" in
  update) run_update ;;
  rollback) run_rollback ;;
  status) run_status ;;
  verify) run_verify ;;
  *) usage ;;
esac
