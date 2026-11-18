#!/usr/bin/env bash
# Check that the neutral skill manifest and the derived representations agree,
# and that every skill sits in exactly one directory level.
#
# skills.json is the authoritative definition of the served skill set.  The
# `pi.skills` array in package.json is a derived mirror for the legacy pi
# package install and must not be maintained by hand, so this check compares
# the two in both directions.  The one-level rule matters because Claude Code
# discovers skills one directory below a scan path only: a nested `SKILL.md`
# silently disappears from that harness while the others still load it.
#
# Usage: check-skill-manifest.sh [<repository-root>]
#
# Exit status: 0 when every check passes, 1 on the first failed check, 2 on
# usage errors or missing tools.  The check reads local files only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(dirname "$SCRIPT_DIR")}"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  printf 'FAIL: jq is required\n' >&2
  exit 2
}

MANIFEST="$ROOT/skills.json"
PACKAGE="$ROOT/package.json"

[ -f "$MANIFEST" ] || die "missing $MANIFEST"
[ -f "$PACKAGE" ] || die "missing $PACKAGE"

jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 ||
  die "skills.json is not a JSON object"
jq -e '.schema_version == 1' "$MANIFEST" >/dev/null ||
  die "skills.json must declare schema_version 1"
jq -e '(.skills | type) == "array" and (.skills | length) > 0' "$MANIFEST" >/dev/null ||
  die "skills.json must declare a non-empty skills array"

# Names become path components and symlink names, so reject anything that is
# not a plain directory name.
jq -r '.skills[] | select(type != "string" or . == "" or (contains("/")) or startswith("."))' \
  "$MANIFEST" | while IFS= read -r bad; do
  [ -z "$bad" ] || die "invalid skill name in skills.json: $bad"
done

jq -r '.skills[]' "$MANIFEST" | sort -c ||
  die "skills.json skills must be sorted"
jq -r '.skills[]' "$MANIFEST" | uniq -d | while IFS= read -r dup; do
  [ -z "$dup" ] || die "duplicate skill in skills.json: $dup"
done

jq -e '.pi.skills | type == "array"' "$PACKAGE" >/dev/null ||
  die "package.json must declare a pi.skills array"

manifest_list="$(jq -r '.skills[]' "$MANIFEST")"
package_list="$(jq -r '.pi.skills[]' "$PACKAGE")"

[ "$manifest_list" = "$package_list" ] ||
  die "package.json pi.skills must mirror skills.json exactly"

while IFS= read -r skill; do
  [ -d "$ROOT/$skill" ] || die "skills.json lists a missing directory: $skill"
  [ -f "$ROOT/$skill/SKILL.md" ] || die "skill has no SKILL.md: $skill"
done <<EOF
$manifest_list
EOF

# Every SKILL.md in the tree must sit exactly one directory below the root.
while IFS= read -r relative; do
  nested="${relative#./}"
  case "$nested" in
    */*/*) die "SKILL.md is nested more than one level: $nested" ;;
    */*) ;;
    *) die "SKILL.md is not inside a skill directory: $nested" ;;
  esac
done <<EOF
$(cd "$ROOT" && find . -path ./.git -prune -o -name SKILL.md -print)
EOF

# Every directory that holds a SKILL.md must be declared, so a new skill
# cannot be added without reaching every harness.
while IFS= read -r dir; do
  skill="${dir#./}"
  printf '%s\n' "$manifest_list" | grep -qx -- "$skill" ||
    die "skill directory is not listed in skills.json: $skill"
done <<EOF
$(cd "$ROOT" && find . -path ./.git -prune -o -name SKILL.md -print | sed 's|/SKILL\.md$||')
EOF

printf 'PASS: skill manifest (%s skills, one level each)\n' "$(printf '%s\n' "$manifest_list" | wc -l | tr -d ' ')"
