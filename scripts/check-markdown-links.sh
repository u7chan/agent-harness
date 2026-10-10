#!/usr/bin/env bash
# Check that relative links and anchor fragments in skill markdown resolve.
#
# Usage: check-markdown-links.sh <skill-dir> [<skill-dir> ...]
#
# Each argument is a skill directory.  The script scans its *.md files and the
# *.md files directly under references/, and for every relative link it checks
# that the target file exists and that any '#fragment' names a heading of the
# target file.  Links that are examples rather than navigation -- inline code
# spans (`...`) and fenced code blocks (``` / ~~~) -- are not checked.  External
# targets (http://, https://, mailto:) are neither resolved nor fetched, so the
# check is hermetic and offline.
#
# Exit status: 0 when every checked link resolves, 1 on the first broken link,
# on a root without SKILL.md, or on a failed parser self-test, 2 on usage errors.
set -euo pipefail

usage() {
  printf 'usage: %s <skill-dir> [<skill-dir> ...]\n' "${0##*/}" >&2
}

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

# GitHub-compatible heading slugs.  Headings in this repository are ASCII, so
# LC_ALL=C keeps the character class deterministic across environments.  The
# rules match GitHub's anchor generation closely enough for this check:
# lowercase, drop characters outside \w, hyphen and space, then space to
# hyphen.  Markdown markup that renders to plain text is unwrapped first.
markdown_slugs() {
  local file="$1"
  LC_ALL=C sed -E \
    -e '/^#{1,6}[[:space:]]/!d' \
    -e 's/^#{1,6}[[:space:]]+//' \
    -e 's/[[:space:]]+#+[[:space:]]*$//' \
    -e 's/[[:space:]]+$//' \
    -e 's/<[^>]*>//g' \
    -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    -e 's/\[([^]]*)\]\[[^]]*\]/\1/g' \
    -e 's/[*`]//g' \
    "$file" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E \
    -e 's/[^a-z0-9 _-]//g' \
    -e 's/ /-/g'
}

# Emit the slugs of one file, suffixing duplicates with -1, -2, ... like
# GitHub does.  A space-separated list keeps this free of bash 4 features.
markdown_anchors() {
  local file="$1" slug base suffix seen=""
  while IFS= read -r slug; do
    base="$slug"
    suffix=0
    while [[ " $seen " == *" $slug "* ]]; do
      suffix=$((suffix + 1))
      slug="$base-$suffix"
    done
    seen="$seen $slug"
    printf '%s\n' "$slug"
  done < <(markdown_slugs "$file")
}

markdown_anchor_exists() {
  local file="$1" wanted="$2" slug
  while IFS= read -r slug; do
    [ "$slug" = "$wanted" ] && return 0
  done < <(markdown_anchors "$file")
  return 1
}

# Drop fenced code blocks (``` / ~~~, at least three characters, closed by the
# same character) and inline code spans (a backtick run and the next run of the
# same length).  What remains is the prose the renderer turns into links.
markdown_without_code() {
  LC_ALL=C awk '
    function strip_inline_code(s,   out, i, run, j, closing, closed) {
      out = ""
      i = 1
      while (i <= length(s)) {
        if (substr(s, i, 1) != "`") {
          out = out substr(s, i, 1)
          i++
          continue
        }
        run = 0
        while (substr(s, i + run, 1) == "`") run++
        j = i + run
        closed = 0
        while (j <= length(s)) {
          if (substr(s, j, 1) == "`") {
            closing = 0
            while (substr(s, j + closing, 1) == "`") closing++
            if (closing == run) {
              closed = 1
              break
            }
            j += closing
          } else {
            j++
          }
        }
        if (!closed) {
          # An unmatched backtick is prose, not a code span: keep the rest.
          out = out substr(s, i)
          break
        }
        i = j + run
      }
      return out
    }
    function scan_fence(line,   rest, ch, run, tail) {
      rest = line
      sub(/^[[:blank:]]*/, "", rest)
      fence_char_at = ""
      fence_run_at = 0
      fence_tail_blank = 0
      ch = substr(rest, 1, 1)
      if (ch != "`" && ch != "~") return
      run = 0
      while (substr(rest, run + 1, 1) == ch) run++
      tail = substr(rest, run + 1)
      fence_char_at = ch
      fence_run_at = run
      if (tail ~ /^[[:blank:]]*$/) fence_tail_blank = 1
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (fence != "") {
        scan_fence(line)
        # A closing fence repeats the opening character at least as many times
        # and carries nothing else.
        if (fence_char_at == fence && fence_run_at >= fence_length && fence_tail_blank) {
          fence = ""
          fence_length = 0
        }
        print ""
        next
      }
      scan_fence(line)
      if (fence_char_at != "" && fence_run_at >= 3) {
        fence = fence_char_at
        fence_length = fence_run_at
        print ""
        next
      }
      print strip_inline_code(line)
    }
  ' "$@"
}

# Emit the target of every inline link in one file, one per line.
markdown_links_in_file() {
  markdown_without_code "$1" | grep -oE '\]\([^)]*\)' | sed -e 's/^](//' -e 's/)$//'
}

# Confirm the parser separates prose links from code examples.  If the
# stripper broke and returned nothing, every check would pass silently, so this
# runs on a fixed sample before the scan.  markdown_without_code reads stdin
# when it is given no file.
markdown_parser_self_test() {
  local stripped
  stripped="$(printf '%s\n' \
    '[prose](./prose.md) and `](inline.md)`.' \
    '' \
    '```text' \
    '](fenced.md)' \
    '```' | markdown_without_code)"
  case "$stripped" in
    *'[prose](./prose.md)'*) ;;
    *)
      printf 'FAIL: the link parser dropped a prose link\n' >&2
      return 1
      ;;
  esac
  case "$stripped" in
    *inline.md*|*fenced.md*)
      printf 'FAIL: the link parser kept a code example\n' >&2
      return 1
      ;;
  esac
}

# Emit the files to check in one skill directory.
markdown_files_in_root() {
  local root="$1" file
  for file in "$root"/*.md; do
    [ -e "$file" ] || continue
    printf '%s\n' "$file"
  done
  [ -d "$root/references" ] || return 0
  for file in "$root"/references/*.md; do
    [ -e "$file" ] || continue
    printf '%s\n' "$file"
  done
}

# Resolve every relative link in the given skill directories: file-only links
# by existence, links with a fragment against the target file's heading slugs,
# and same-file anchors against the linking file.
markdown_links_resolve() {
  local root file link target fragment target_file dir checked=0 files=0
  for root in "$@"; do
    if [ ! -f "$root/SKILL.md" ]; then
      printf 'FAIL: %s: no SKILL.md in the given root\n' "$root" >&2
      return 1
    fi
    while IFS= read -r file; do
      files=$((files + 1))
      dir="$(dirname "$file")"
      while IFS= read -r link; do
        case "$link" in
          http://*|https://*|mailto:*) continue ;;
        esac
        target="${link%%#*}"
        fragment=""
        case "$link" in
          *'#'*) fragment="${link#*#}" ;;
        esac
        target="${target%%[[:space:]]*}"
        target="${target#<}"
        target="${target%>}"
        fragment="${fragment%%[[:space:]]*}"
        [ -n "$target$fragment" ] || continue
        if [ -n "$target" ]; then
          target_file="$dir/$target"
          if [ ! -f "$target_file" ]; then
            printf 'FAIL: %s: relative link does not resolve: %s\n' "$file" "$link" >&2
            return 1
          fi
        else
          target_file="$file"
        fi
        if [ -n "$fragment" ] && ! markdown_anchor_exists "$target_file" "$fragment"; then
          printf 'FAIL: %s: anchor does not resolve: %s\n' "$file" "$link" >&2
          return 1
        fi
        checked=$((checked + 1))
      done < <(markdown_links_in_file "$file")
    done < <(markdown_files_in_root "$root")
  done
  # A root without relative links is valid, so the checks above are the whole
  # contract; the parser self-test guards against a vacuous pass.
  printf 'checked %s file(s) and %s relative link(s)\n' "$files" "$checked"
}

markdown_parser_self_test || exit 1
markdown_links_resolve "$@"
