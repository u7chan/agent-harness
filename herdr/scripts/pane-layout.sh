#!/usr/bin/env bash
# Plan and build a deterministic grid of panes for a team in Herdr.
#
#   pane-layout.sh plan  --count <n> --area <WxH> [--label <label>]
#   pane-layout.sh apply --count <n> [--label <label>] [--pane <pane-id>] [--cwd <dir>]
#
# `--count` is the number of panes the command creates (the team). `plan` is
# pure computation and never calls herdr; `apply` reads the caller's live
# layout, runs the same plan, then creates the tab(s) and splits them.
#
# When the caller's rectangle can hold the team, the caller pane is the
# top-left cell of a grid of count + 1 cells and `apply` creates exactly
# `count` panes. Otherwise the caller is left untouched and the team goes to
# new tabs. Nothing is ever moved, resized, closed, or focused.
#
# Constants, grid selection order, tab policy, and failure behavior are
# documented in references/pane-layout.md; the values below are authoritative.
set -euo pipefail

# Hard minimum size of one pane, in cells.
MIN_CELLS_X=55
MIN_CELLS_Y=14
# Cell width / cell height, in percent (a cell is about 0.48x as wide as tall).
CELL_RATIO_PCT=48
# Accepted pixel aspect window and its preferred center, in percent.
ASPECT_MIN_PCT=70
ASPECT_MAX_PCT=260
TARGET_ASPECT_PCT=140

usage() {
  {
    printf 'Usage:\n'
    printf '  %s plan --count <n> --area <WxH> [--label <label>]\n' "$0"
    printf '  %s apply --count <n> [--label <label>] [--pane <pane-id>] [--cwd <dir>]\n' "$0"
  } >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_pane() {
  [[ "$1" =~ ^[[:alnum:]_.-]+:[[:alnum:]_.-]+$ ]]
}

# Single-line tab label: letters, digits, and the punctuation a team label
# needs. The planner and the herdr calls carry it verbatim, so reject every
# separator the internal line protocol uses.
valid_label() {
  local pattern='^[[:alnum:]_.:/ -]+$'
  [ -n "$1" ] || return 1
  [ "${#1}" -le 64 ] || return 1
  [[ "$1" =~ $pattern ]]
}

require_python() {
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
}

# Planner: region and tab area in cells, the team size, the optional label,
# and the constants. Prints the plan JSON, or a reason on stderr when the
# region cannot hold the requested grid.
plan_json_for() { # $1=region_w $2=region_h $3=area_w $4=area_h $5=count $6=label
  python3 -I - "$1" "$2" "$3" "$4" "$5" "$6" \
    "min_x=$MIN_CELLS_X" "min_y=$MIN_CELLS_Y" "ratio_pct=$CELL_RATIO_PCT" \
    "aspect_min_pct=$ASPECT_MIN_PCT" "aspect_max_pct=$ASPECT_MAX_PCT" \
    "target_pct=$TARGET_ASPECT_PCT" <<'PY'
import json
import sys

if len(sys.argv) < 13:
    sys.stderr.write("ERROR: the planner needs a region, a tab area, a count, a label, and the constants\n")
    sys.exit(2)

region_w, region_h, area_w, area_h, count, label = sys.argv[1:7]
region_w, region_h = int(region_w), int(region_h)
area_w, area_h = int(area_w), int(area_h)
count = int(count)
values = dict(pair.split("=", 1) for pair in sys.argv[7:])
min_x = int(values["min_x"])
min_y = int(values["min_y"])
ratio_pct = int(values["ratio_pct"])
aspect_min = int(values["aspect_min_pct"])
aspect_max = int(values["aspect_max_pct"])
target = int(values["target_pct"])

if region_w < 1 or region_h < 1 or area_w < 1 or area_h < 1 or count < 2:
    sys.stderr.write("ERROR: the planner needs a positive region and a count of at least 2\n")
    sys.exit(2)


def fits_minimum(width, height, cols, rows):
    """Can every pane in a cols x rows grid meet the hard minimum size?"""
    if cols < 1 or rows < 1:
        return False
    return cols * min_x <= width and rows * min_y <= height


def in_window(width, height, cols, rows):
    """Is the grid's pixel aspect inside the preferred window?"""
    # Pixel aspect = ratio_pct/100 * (width/cols) / (height/rows). Compared
    # without floats: aspect_min <= 100 * aspect <= aspect_max.
    scaled = ratio_pct * width * rows
    bound = 100 * height * cols
    return aspect_min * bound <= 100 * scaled <= aspect_max * bound


def fill_pair(width, height, cols, rows):
    """min(cell width / min_x, cell height / min_y) as an exact fraction."""
    return (min(width * rows * min_y, height * cols * min_x),
            cols * rows * min_x * min_y)


def distance_pair(width, height, cols, rows):
    """|pixel aspect - target aspect| as an exact fraction."""
    return (abs(ratio_pct * width * rows - target * height * cols),
            100 * height * cols)


def compare(left, right):
    first, second = left[0] * right[1], right[0] * left[1]
    return (first > second) - (first < second)


def better(candidate, best):
    if candidate["empty"] != best["empty"]:
        return candidate["empty"] < best["empty"]
    order = compare(candidate["fill"], best["fill"])
    if order:
        return order > 0
    order = compare(candidate["distance"], best["distance"])
    if order:
        return order < 0
    if candidate["rows"] != best["rows"]:
        return candidate["rows"] < best["rows"]
    return candidate["cols"] < best["cols"]


def choose_grid(width, height, cells):
    """Grid for `cells` panes, preferring the aspect window, or None.

    Tier A meets the hard minimum and the aspect window; tier B, used only
    when tier A has no candidate for this size, meets the hard minimum alone.
    The size and shape rules apply inside the best tier that has candidates.
    A grid of `cols` columns and `rows = ceil(cells / cols)` rows is enough:
    rows beyond that only add empty slots to a wider grid.
    """
    for tier in ("ok", "relaxed"):
        best = None
        for cols in range(1, width // min_x + 1):
            rows = (cells + cols - 1) // cols
            if not fits_minimum(width, height, cols, rows):
                continue
            if tier == "ok" and not in_window(width, height, cols, rows):
                continue
            candidate = {
                "rows": rows,
                "cols": cols,
                "empty": rows * cols - cells,
                "fill": fill_pair(width, height, cols, rows),
                "distance": distance_pair(width, height, cols, rows),
            }
            if best is None or better(candidate, best):
                best = candidate
        if best is not None:
            best["aspect_window"] = tier
            return best
    return None


def capacity(width, height):
    """Largest pane count a full grid of this area can hold.

    The hard minimum is the only limit here, so every size up to the result
    is placeable (the window is a preference, see choose_grid).
    """
    most = 0
    for cols in range(1, width // min_x + 1):
        for rows in range(1, height // min_y + 1):
            if fits_minimum(width, height, cols, rows):
                most = max(most, cols * rows)
    return most


def build_tab(index, policy, tab_label, width, height, cells):
    """Cells and ordered split operations for one tab.

    Cell rects are relative to the tab area origin. Rows other than the last
    are filled completely; the last row holds the remaining cells and its
    final pane keeps the rest of the width.
    """
    grid = choose_grid(width, height, cells)
    if grid is None:
        sys.stderr.write(
            "ERROR: no feasible pane grid for %d panes in a %d x %d cell area: every pane "
            "needs at least %dx%d cells\n"
            % (cells, width, height, min_x, min_y))
        return None
    rows, cols = grid["rows"], grid["cols"]
    y_bounds = [(row * height) // rows for row in range(rows + 1)]
    tab_cells = []
    for row in range(rows):
        in_row = min(cols, cells - row * cols)
        x_bounds = [(col * width) // in_row for col in range(in_row + 1)]
        for col in range(in_row):
            tab_cells.append({
                "index": row * cols + col,
                "row": row,
                "col": col,
                "x": x_bounds[col],
                "y": y_bounds[row],
                "width": x_bounds[col + 1] - x_bounds[col],
                "height": y_bounds[row + 1] - y_bounds[row],
                "source": row == 0 and col == 0,
            })
    splits = []
    # Row cuts first: the top-left pane keeps the first row and every
    # remainder becomes the next row, so each row pane spans the full width.
    for row in range(1, rows):
        keep = y_bounds[row] - y_bounds[row - 1]
        splits.append({
            "tab": index,
            "source_cell": (row - 1) * cols,
            "target_cell": row * cols,
            "direction": "down",
            "ratio": round(keep / (height - y_bounds[row - 1]), 6),
        })
    # Then each row in order, left to right. The last pane of the row keeps
    # the remaining width, which is what a partially filled last row leaves.
    for row in range(rows):
        in_row = min(cols, cells - row * cols)
        x_bounds = [(col * width) // in_row for col in range(in_row + 1)]
        for col in range(1, in_row):
            keep = x_bounds[col] - x_bounds[col - 1]
            splits.append({
                "tab": index,
                "source_cell": row * cols + col - 1,
                "target_cell": row * cols + col,
                "direction": "right",
                "ratio": round(keep / (width - x_bounds[col - 1]), 6),
            })
    return {
        "index": index,
        "policy": policy,
        "label": tab_label,
        "rows": rows,
        "cols": cols,
        "aspect_window": grid["aspect_window"],
        "cells": tab_cells,
        "splits": splits,
    }


caller_grid = choose_grid(region_w, region_h, count + 1)
room = capacity(area_w, area_h)
if caller_grid is not None:
    tab_policy = "current"
    tabs = [build_tab(0, "current", None, region_w, region_h, count + 1)]
    if tabs[0] is None:
        sys.exit(1)
    plan_rows, plan_cols = caller_grid["rows"], caller_grid["cols"]
else:
    if room < 1:
        sys.stderr.write(
            "ERROR: no feasible pane grid in a %d x %d cell area: every pane needs at "
            "least %dx%d cells\n" % (area_w, area_h, min_x, min_y))
        sys.exit(1)
    tab_policy = "new"
    tab_count = (count + room - 1) // room
    base, extra = divmod(count, tab_count)
    sizes = [base + 1] * extra + [base] * (tab_count - extra)
    tabs = []
    for index, size in enumerate(sizes):
        tab_label = None
        if label:
            tab_label = label if index == 0 else "%s-%d" % (label, index + 1)
        tab = build_tab(index, "new", tab_label, area_w, area_h, size)
        if tab is None:
            sys.exit(1)
        tabs.append(tab)
    plan_rows, plan_cols = None, None

plan = {
    "schema": "herdr.pane-layout.v1",
    "mode": "plan",
    "count": count,
    "label": label or None,
    "region": {"width": region_w, "height": region_h},
    "tab_area": {"width": area_w, "height": area_h},
    "tab_policy": tab_policy,
    "capacity": room,
    "aspect_window": "relaxed" if any(
        tab["aspect_window"] == "relaxed" for tab in tabs) else "ok",
    "rows": plan_rows,
    "cols": plan_cols,
    "tabs": [{
        "index": tab["index"],
        "policy": tab["policy"],
        "label": tab["label"],
        "rows": tab["rows"],
        "cols": tab["cols"],
        "aspect_window": tab["aspect_window"],
        "cells": tab["cells"],
    } for tab in tabs],
    "splits": [split for tab in tabs for split in tab["splits"]],
}
print(json.dumps(plan, sort_keys=True, separators=(",", ":")))
PY
}

# Read the caller rectangle, the tab area, and the identities of the caller's
# tab out of a `herdr pane layout` response.
layout_rects_for() { # $1=layout json $2=pane id
  python3 -I - "$2" "$1" <<'PY'
import json
import sys

pane_id, raw = sys.argv[1], sys.argv[2]
try:
    layout = json.loads(raw)["result"]["layout"]
    area = layout["area"]
    rect = None
    for pane in layout["panes"]:
        if pane.get("pane_id") == pane_id:
            rect = pane["rect"]
            break
    if rect is None:
        raise KeyError(pane_id)
    values = [rect["x"], rect["y"], rect["width"], rect["height"],
              area["x"], area["y"], area["width"], area["height"]]
    values = [int(value) for value in values]
    if values[2] < 1 or values[3] < 1 or values[6] < 1 or values[7] < 1:
        raise ValueError(values)
    if values[0] < 0 or values[1] < 0 or values[4] < 0 or values[5] < 0:
        raise ValueError(values)
    tail = [layout["tab_id"], layout["workspace_id"]]
    if not all(isinstance(value, str) and value for value in tail):
        raise ValueError(tail)
except Exception:
    sys.stderr.write("ERROR: %s is not described by a usable herdr pane layout response\n" % pane_id)
    sys.exit(1)
print(" ".join(str(value) for value in values + tail))
PY
}

# Print a single field of a herdr JSON response.
json_field() { # $1=dotted path $2=json
  python3 -I - "$1" "$2" <<'PY'
import json
import sys

path, raw = sys.argv[1], sys.argv[2]
try:
    value = json.loads(raw)
    for key in path.split("."):
        value = value[key]
    if not isinstance(value, str) or not value:
        raise ValueError(value)
except Exception:
    sys.stderr.write("ERROR: herdr response has no usable %s\n" % path)
    sys.exit(1)
print(value)
PY
}

# Turn a plan into the line protocol the apply loop consumes: one tab line
# followed by that tab's split operations, in execution order.
plan_operations() { # $1=plan json
  python3 -I - "$1" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
lines = ["policy|%s" % plan["tab_policy"], "capacity|%d" % plan["capacity"]]
for tab in plan["tabs"]:
    lines.append("tab|%d|%s|%s|%d|%d" % (
        tab["index"], tab["policy"], tab["label"] or "", tab["rows"], tab["cols"]))
    for split in plan["splits"]:
        if split["tab"] != tab["index"]:
            continue
        lines.append("split|%d|%d|%d|%s|%.6f" % (
            split["tab"], split["source_cell"], split["target_cell"],
            split["direction"], split["ratio"]))
print("\n".join(lines))
PY
}

# Verify one built tab against the plan: every planned cell must be present
# with the planned rectangle, within one cell per dimension.
verify_tab() { # $1=plan json $2=tab index $3=origin x $4=origin y $5=state file $6=layout json
  python3 -I - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
tab_index, origin_x, origin_y, state_path = (
    int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
try:
    layout = json.loads(sys.argv[6])["result"]["layout"]
except Exception:
    sys.stderr.write("ERROR: herdr pane layout returned an unusable response for tab %d\n" % tab_index)
    sys.exit(1)

panes = {}
try:
    for pane in layout["panes"]:
        panes[pane["pane_id"]] = [int(value) for value in (
            pane["rect"]["x"], pane["rect"]["y"], pane["rect"]["width"], pane["rect"]["height"])]
except Exception:
    sys.stderr.write("ERROR: herdr pane layout has an unusable pane rectangle for tab %d\n" % tab_index)
    sys.exit(1)

mapping = {}
with open(state_path, encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("|")
        if parts[0] == "cell":
            mapping[(int(parts[1]), int(parts[2]))] = parts[3]

tab = plan["tabs"][tab_index]
for cell in tab["cells"]:
    pane_id = mapping.get((tab_index, cell["index"]))
    if pane_id is None:
        sys.stderr.write("ERROR: planned cell %d of tab %d was never created\n" % (cell["index"], tab_index))
        sys.exit(1)
    actual = panes.get(pane_id)
    if actual is None:
        sys.stderr.write("ERROR: pane %s (cell %d of tab %d) is missing from herdr pane layout\n"
                         % (pane_id, cell["index"], tab_index))
        sys.exit(1)
    expected = [origin_x + cell["x"], origin_y + cell["y"], cell["width"], cell["height"]]
    for name, got, want in zip(("x", "y", "width", "height"), actual, expected):
        if abs(got - want) > 1:
            sys.stderr.write(
                "ERROR: pane %s does not match the plan: %s is %d, planned %d "
                "(cell %d of tab %d, planned rect %d,%d %dx%d)\n"
                % (pane_id, name, got, want, cell["index"], tab_index,
                   expected[0], expected[1], expected[2], expected[3]))
            sys.exit(1)
PY
}

# Merge the plan with the tab and pane identities that apply created.
apply_result() { # $1=plan json $2=state file
  python3 -I - "$1" "$2" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
tabs = {}
panes = {}
with open(sys.argv[2], encoding="utf-8") as handle:
    for line in handle:
        parts = line.rstrip("\n").split("|")
        if parts[0] == "tab":
            tabs[int(parts[1])] = {"tab_id": parts[2], "label": parts[3]}
        elif parts[0] == "cell":
            panes[(int(parts[1]), int(parts[2]))] = parts[3]

result = {
    "schema": plan["schema"],
    "mode": "apply",
    "count": plan["count"],
    "label": plan["label"],
    "region": plan["region"],
    "tab_area": plan["tab_area"],
    "tab_policy": plan["tab_policy"],
    "capacity": plan["capacity"],
    "aspect_window": plan["aspect_window"],
    "rows": plan["rows"],
    "cols": plan["cols"],
    "tabs": [],
    "splits": plan["splits"],
    "created_panes": [],
}
for tab in plan["tabs"]:
    info = tabs.get(tab["index"], {})
    entry = {
        "index": tab["index"],
        "policy": tab["policy"],
        "label": info.get("label") or None,
        "tab_id": info.get("tab_id"),
        "rows": tab["rows"],
        "cols": tab["cols"],
        "aspect_window": tab["aspect_window"],
        "cells": [],
    }
    for cell in tab["cells"]:
        pane_id = panes.get((tab["index"], cell["index"]))
        entry["cells"].append(dict(cell, pane_id=pane_id))
        if tab["policy"] == "new" or not cell["source"]:
            result["created_panes"].append(pane_id)
    result["tabs"].append(entry)
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
}

[ "$#" -ge 1 ] || usage
mode="$1"
shift

count=''
label=''
pane=''
cwd=''
area=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --count)
      [ "$#" -ge 2 ] || usage
      count="$2"
      shift 2
      ;;
    --label)
      [ "$#" -ge 2 ] || usage
      label="$2"
      shift 2
      ;;
    --pane)
      [ "$mode" = apply ] || usage
      [ "$#" -ge 2 ] || usage
      pane="$2"
      shift 2
      ;;
    --cwd)
      [ "$mode" = apply ] || usage
      [ "$#" -ge 2 ] || usage
      cwd="$2"
      shift 2
      ;;
    --area)
      [ "$mode" = plan ] || usage
      [ "$#" -ge 2 ] || usage
      area="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$mode" in
  plan|apply) ;;
  *) usage ;;
esac

[[ "$count" =~ ^[0-9]+$ ]] || usage
[ "$count" -ge 2 ] || fail '--count must be at least 2'
if [ -n "$label" ]; then
  valid_label "$label" || fail '--label must be a single-line label of at most 64 characters'
fi
require_python

if [ "$mode" = plan ]; then
  if [[ "$area" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    area_w="${BASH_REMATCH[1]}"
    area_h="${BASH_REMATCH[2]}"
  else
    usage
  fi
  [ "$area_w" -ge 1 ] && [ "$area_h" -ge 1 ] || fail '--area must be positive (WxH)'
  plan_json_for "$area_w" "$area_h" "$area_w" "$area_h" "$count" "$label"
  exit 0
fi

# apply: build the plan from the caller's live layout.
pane="${pane:-${HERDR_PANE_ID:-}}"
cwd="${cwd:-$PWD}"
valid_pane "$pane" || fail '--pane (or HERDR_PANE_ID) must be a pane ID'
[ "${HERDR_ENV:-}" = 1 ] || fail 'HERDR_ENV must be 1'
[ -n "$cwd" ] || fail '--cwd must not be empty'
case "$cwd" in
  /*) ;;
  *) fail '--cwd must be an absolute path' ;;
esac
[ -d "$cwd" ] || fail '--cwd must be an existing directory'
command -v herdr >/dev/null 2>&1 || fail 'herdr is required'

caller_layout="$(herdr pane layout --pane "$pane")" ||
  fail "herdr pane layout failed for $pane"
caller_rects="$(layout_rects_for "$caller_layout" "$pane")" ||
  fail "herdr pane layout did not describe $pane"
read -r caller_x caller_y caller_w caller_h area_x area_y area_w area_h tab_id workspace_id \
  <<< "$caller_rects" || fail "herdr pane layout did not report $pane"
[ -n "${workspace_id:-}" ] || fail "herdr pane layout did not report the workspace of $pane"

plan_json="$(plan_json_for "$caller_w" "$caller_h" "$area_w" "$area_h" "$count" "$label")" ||
  fail "no pane layout can place $count panes next to $pane"

state_file="$(mktemp "${TMPDIR:-/tmp}/herdr-pane-layout-XXXXXX")"
trap 'rm -f "$state_file"' EXIT

pending_tab=''
pending_root=''
pending_x=0
pending_y=0

verify_pending() {
  [ -n "$pending_tab" ] || return 0
  local layout
  layout="$(herdr pane layout --pane "$pending_root")" ||
    fail "herdr pane layout failed for the built tab $pending_tab"
  verify_tab "$plan_json" "$pending_tab" "$pending_x" "$pending_y" "$state_file" "$layout" ||
    fail "the built layout of tab $pending_tab does not match the plan: see the mismatch above"
  pending_tab=''
}

pane_for_cell() { # $1=tab index $2=cell index
  awk -F'|' -v tab="$1" -v cell="$2" \
    '$1 == "cell" && $2 == tab && $3 == cell { print $4; exit }' "$state_file"
}

operations="$(plan_operations "$plan_json")"
while IFS='|' read -r kind first second third fourth fifth; do
  case "$kind" in
    policy|capacity) ;;
    tab)
      verify_pending
      tab_index="$first"
      tab_policy="$second"
      tab_label="$third"
      if [ "$tab_policy" = current ]; then
        # The caller pane is cell 0 and the grid covers the caller rectangle.
        root_pane="$pane"
        tab_origin_x="$caller_x"
        tab_origin_y="$caller_y"
        tab_identity="$tab_id"
      else
        # A new tab starts as one pane that covers the whole tab area.
        create_args=(--workspace "$workspace_id" --cwd "$cwd" --no-focus)
        if [ -n "$tab_label" ]; then
          create_args=(--label "$tab_label" "${create_args[@]}")
        fi
        created="$(herdr tab create "${create_args[@]}")" ||
          fail "herdr tab create failed for tab $tab_index of the plan"
        tab_identity="$(json_field 'result.tab.tab_id' "$created")" ||
          fail "herdr tab create did not return a tab id for tab $tab_index"
        root_pane="$(json_field 'result.root_pane.pane_id' "$created")" ||
          fail "herdr tab create did not return a root pane for tab $tab_index"
        tab_origin_x="$area_x"
        tab_origin_y="$area_y"
      fi
      printf 'tab|%s|%s|%s\n' "$tab_index" "$tab_identity" "$tab_label" >> "$state_file"
      printf 'cell|%s|0|%s\n' "$tab_index" "$root_pane" >> "$state_file"
      pending_tab="$tab_index"
      pending_root="$root_pane"
      pending_x="$tab_origin_x"
      pending_y="$tab_origin_y"
      ;;
    split)
      split_tab="$first"
      source_cell="$second"
      target_cell="$third"
      direction="$fourth"
      ratio="$fifth"
      source_pane="$(pane_for_cell "$split_tab" "$source_cell")"
      [ -n "$source_pane" ] || fail "the plan has no pane for cell $source_cell of tab $split_tab"
      split_response="$(herdr pane split --pane "$source_pane" --direction "$direction" \
        --ratio "$ratio" --cwd "$cwd" --no-focus)" ||
        fail "herdr pane split failed for cell $source_cell of tab $split_tab ($direction, ratio $ratio)"
      new_pane="$(json_field 'result.pane.pane_id' "$split_response")" ||
        fail "herdr pane split did not return a pane for cell $source_cell of tab $split_tab"
      printf 'cell|%s|%s|%s\n' "$split_tab" "$target_cell" "$new_pane" >> "$state_file"
      ;;
    *)
      fail "the plan contains an unknown operation: $kind"
      ;;
  esac
done <<< "$operations"

verify_pending
apply_result "$plan_json" "$state_file"
