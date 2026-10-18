#!/usr/bin/env bash
# Report the records that outgrew their limit and the relative links that no
# longer resolve. It only reports: rotation and rewriting stay a human decision.
#
# Generalized shape, not a supported harness.
#
# Usage: size-check.sh
set -euo pipefail

record_dir="${RECORD_DIR:-$HOME/operator-team}"
# '<file>:<line limit>' entries, one per record that must not grow forever.
limits="AGENTS.md:40 STATE.md:120 LOG.md:80"

status=0
for entry in $limits; do
  file="${entry%%:*}"
  max="${entry##*:}"
  path="$record_dir/$file"
  if [ ! -f "$path" ]; then
    printf 'skip   %-12s (not found)\n' "$file"
    continue
  fi
  lines="$(wc -l <"$path" | tr -d ' ')"
  if [ "$lines" -gt "$max" ]; then
    printf 'ROTATE %-12s %s lines / limit %s\n' "$file" "$lines" "$max"
    status=1
  else
    printf 'ok     %-12s %s lines / limit %s\n' "$file" "$lines" "$max"
  fi
done

# Every relative markdown link must name a file that exists, and an anchor must
# name a heading of its target. External links and code spans are not checked.
python3 -I - "$record_dir" <<'PY' || status=1
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
links = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
heading = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$")
fence = re.compile(r"^\s*(```|~~~)")

def slug(text):
    return re.sub(r"[^\w \-]", "", text.strip().lower()).replace(" ", "-")

def anchors(path):
    found = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = heading.match(line)
        if match:
            found.add(slug(match.group(1)))
    return found

broken = []
for path in sorted(root.rglob("*.md")):
    inside_fence = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if fence.match(line):
            inside_fence = not inside_fence
            continue
        if inside_fence:
            continue
        for link in links.findall(line):
            if link.startswith(("http://", "https://", "mailto:")):
                continue
            target, _, fragment = link.partition("#")
            target_path = (path.parent / target).resolve() if target else path
            if target and not target_path.exists():
                broken.append(f"{path}: broken link: {link}")
            elif fragment and target_path.suffix == ".md" and fragment not in anchors(target_path):
                broken.append(f"{path}: broken anchor: {link}")

for line in broken:
    print(f"ROTATE {line}")
sys.exit(1 if broken else 0)
PY

exit "$status"
