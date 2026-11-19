#!/usr/bin/env bash
# Check that the repository holds no screenshot or recording outside its
# documentation assets, and that every documentation asset is linked from a
# document.
#
# UI evidence belongs in the PR body as an uploaded attachment, and its files
# live in a temporary directory such as PW_ARTIFACT_DIR: _docs/pr-evidence.md
# forbids committing them.  A committed screenshot is picked up by the next
# `git add -A`, and from then on it describes a UI that keeps changing, so it
# has to be re-shot on every UI diff or removed.
#
# A static picture that a document explains is a different thing, so
# _docs/assets/ is allowed.  That allowance does not make the directory a
# dumping ground: an asset no document links to is either a leftover or a
# document that lost its link, and both are worth failing on.  A name that
# merely appears in prose is not a link, and a document inside the asset
# directory cannot vouch for its neighbour, or the directory grades its own
# homework.
#
# .gitignore covers the ordinary `git add -A`; this check covers a forced add,
# a file written by a script, an extension in upper case, and a non-PNG
# recording.  It scans the working tree instead of the index, so a stray
# artifact fails locally before it is staged; CI checks out tracked files only,
# so there it covers the index.
#
# Usage: check-media-artifacts.sh [<repository-root>]
#
# Exit status: 0 when the tree holds no media artifact, 1 when one is present.
# The check reads local files only and needs no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(dirname "$SCRIPT_DIR")}"
ASSET_DIR="_docs/assets"

[ -d "$ROOT" ] || {
  printf 'FAIL: not a directory: %s\n' "$ROOT" >&2
  exit 1
}

# -E with -i, because a capture tool can name the file .PNG or .JPG.
media="$(
  cd "$ROOT" &&
    find . -path ./.git -prune -o -type f -print |
    grep -Ei '\.(png|jpe?g|gif|webp|bmp|tiff?|mp4|webm|mov|mkv)$' |
    sort || true
)"

# Every Markdown image or link target and every HTML src, reduced to the bare
# path.  Only these count as a reference; prose that names a file does not.
references="$(
  cd "$ROOT" &&
    find . -type f -name '*.md' ! -path './.git/*' ! -path "./$ASSET_DIR/*" |
    sort |
    while IFS= read -r doc; do
      grep -ohE -e '!?\[[^]]*\]\([^)[:space:]]*\)' -e 'src="[^"]*"' "$doc" 2>/dev/null || true
    done |
    sed -e 's/^!\[[^]]*\](//' -e 's/^\[[^]]*\](//' -e 's/)$//' \
        -e 's/^src="//' -e 's/"$//' -e 's/[?#].*$//' || true
)"

stray=""
orphans=""
assets=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  relative="${path#./}"

  if [ "${relative#"$ASSET_DIR"/}" = "$relative" ]; then
    stray="$stray  $relative"$'\n'
    continue
  fi

  assets=$((assets + 1))
  # A link may be written from _docs/ (assets/x.png) or from the root
  # (_docs/assets/x.png); both end with the path relative to _docs/.
  suffix="${relative#_docs/}"
  linked=0
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      *"$suffix") linked=1 ;;
    esac
  done <<EOF
$references
EOF
  [ "$linked" -eq 1 ] || orphans="$orphans  $relative"$'\n'
done <<EOF
$media
EOF

status=0

if [ -n "$stray" ]; then
  printf 'FAIL: media artifacts must not be committed:\n%s' "$stray" >&2
  status=1
fi

if [ -n "$orphans" ]; then
  printf 'FAIL: documentation assets must be linked from a document:\n%s' "$orphans" >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  printf 'UI evidence is attached to the PR body, not committed; keep its files in a temporary directory such as PW_ARTIFACT_DIR and see _docs/pr-evidence.md. A documentation image belongs in %s/ and keeps a Markdown link to it from outside that directory.\n' "$ASSET_DIR" >&2
  exit 1
fi

printf 'PASS: no media artifacts (%s documentation asset(s))\n' "$assets"
