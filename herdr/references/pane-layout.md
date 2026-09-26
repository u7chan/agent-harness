# Pane layout

`herdr/scripts/pane-layout.sh` turns a region in cells and a team size into a
deterministic pane grid, then builds it. It exists because the guidance the
Herdr CLI ships ("split a wide pane to the right and a narrow or tall pane
down", [upstream skill](../SKILL.md#pane-operations)) leaves the split order
and ratios to the agent, so the result varies between runs.

Use it when one delegation round needs several sibling agent panes. Single-pane
delegation keeps the existing rules of [`herdr/SKILL.md`](../SKILL.md).

```bash
herdr/scripts/pane-layout.sh plan  --count <n> --area <WxH> [--label <label>]
herdr/scripts/pane-layout.sh apply --count <n> [--label <label>] [--pane <pane-id>] [--cwd <dir>]
```

- `--count` is the number of panes `apply` creates (the team). It must be at
  least 2.
- `plan` is pure computation: it never calls `herdr`, so it can be used to
  preview a layout or to test the planner. `--area WxH` is the region in cells
  and stands for both the caller rectangle and the tab area.
- `apply` reads `herdr pane layout --pane <pane>`, plans from the live caller
  rectangle and tab area, then creates the tab(s) and splits. `--pane`
  defaults to `$HERDR_PANE_ID` and `--cwd` to `$PWD`; `--cwd` must be an
  absolute existing directory and is passed to every creation.
- `--label` names new tabs. Drafts (`plan`) and results (`apply`) are one
  JSON document each, reporting the tab policy, the grid of every tab, the
  capacity, and the aspect tier (`aspect_window`, see below).

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| hard minimum | 55 x 14 cells | Smallest pane this skill treats as usable. Always required. |
| cell ratio | 0.48 | Cell width divided by cell height. |
| aspect window | 0.7 – 2.6 | Preferred pixel aspect of one pane. Relaxed only when no grid of the requested size fits it. |
| target aspect | 1.4 | Preferred pixel aspect within the window. |

A cell's pixel aspect is `0.48 * (region_width / cols) / (region_height / rows)`,
that is, the width and height the region gives one pane, converted to pixels.

## Grid selection

For one region and a required cell count, the planner enumerates every column
count from 1 to `floor(width / 55)` with `rows = ceil(cells / cols)` and picks
the grid in two tiers:

- **tier A** — every pane meets the hard minimum (55 x 14 cells) **and** the
  pixel aspect is inside the window;
- **tier B** — used only when tier A has no candidate for this size: every pane
  meets the hard minimum, whatever its aspect.

Within the best tier that has candidates, the grids are ranked in this order:

1. fewest empty slots (`rows * cols - cells`);
2. largest worst-case fill, `min(cell width / 55, cell height / 14)`;
3. aspect closest to the target 1.4;
4. fewest rows, then fewest columns (the widest grid).

The window is a preference and the minimum is hard, so a plan only fails when
the minimum cannot be met. The plan reports the tier it used as
`aspect_window`: `"ok"` when every tab stayed in tier A, `"relaxed"` when at
least one tab fell back to tier B. Each tab carries the same field for its own
grid.

For a 247 x 47 region, `cells` maps to a grid as follows:

| Cells | Grid (rows x columns) | `plan --count` |
| --- | --- | --- |
| 3 | 1 x 3 | 2 |
| 4 | 2 x 2 | 3 |
| 8 | 2 x 4 | 7 |
| 9 | 3 x 3 | 8 |
| 12 | 3 x 4 | 11 |
| 16 | two tabs | 15 |

The `--count` column is `cells - 1` because in the current tab the caller pane
occupies cell 0 (see [Tab policy](#tab-policy)). The grid shapes are the
acceptance list of Issue #217; its 12-cell case is the largest single-tab
layout for this region, and 16 cells exceed the tab's capacity of 12.

Rows other than the last are filled completely. A partially filled last row
keeps its own, smaller column count, and the last pane of that row absorbs the
remaining width; no pane is created for an empty slot.

## Split order and ratios

`herdr pane split --ratio R --direction right|down` keeps the share `R` of the
split region in the source pane and gives `1 - R` to the new pane, which
becomes the second child: on the right for `right`, below for `down`. The
`ratio` field of `herdr pane layout` is the same value. Measured on Herdr
0.9.1: splitting a 247-wide pane with `--ratio 0.33` left 82 columns to the
source pane and gave 165 columns to the new pane.

The planner emits the operations that produce its rectangles from the caller
pane:

1. row cuts, top to bottom: the source keeps the next row, the remainder
   becomes the following rows;
2. then each row, left to right: the source keeps the next cell, the remainder
   becomes the rest of the row.

Ratios are relative to the region the split source holds at that moment,
rounded to six decimals. Planned rectangles are relative to the region origin
and use `floor` boundaries, so `apply` can compare them with the live layout
within one cell per dimension; the actual panes are not resized afterwards.

## Tab policy

`capacity` is the largest pane count a full grid of the tab area can hold at
the hard minimum, so every size up to it is placeable. For a 247 x 47 tab that
is 12 panes (3 rows x 4 columns). A tab whose size only fits tier B is
reported as `"relaxed"`, for example 110 x 40 split into 3 and 2 panes: the
three-pane tab is `"ok"` and the two-pane tab is `"relaxed"`.

- **current** — a grid for `count + 1` cells exists in the caller rectangle
  (tier A or tier B). The caller pane is cell 0 (top-left) and the plan covers
  the caller's rectangle with `count + 1` cells, so `apply` creates exactly
  `count` panes and does not change the caller's position.
- **new** — no such grid exists. The caller pane is left untouched and the
  whole team goes to `ceil(count / capacity)` new tabs, sized as evenly as
  possible with the larger tabs first. Tab labels are `<label>`, `<label>-2`,
  `<label>-3`; without `--label` the tabs keep the default label.

`apply` pins `--workspace` on `tab create` from the workspace ID reported by
`herdr pane layout`, so a new tab always lands in the caller's workspace.

## Exceptions to the skill's pane rules

Both exceptions apply only to a planned multi-pane layout built by this script:

- an existing empty shell pane is not adopted as a delegation target. The
  planner cannot move or resize an unrelated pane into a planned cell, so a
  planned layout is built from the caller pane and new tabs. Single-pane
  delegation keeps the existing reuse rule of [`herdr/SKILL.md`](../SKILL.md#when-the-requested-agent-is-absent).
- creating a tab is allowed without asking when the planner determines that
  the current tab cannot hold the team. The script never creates a workspace
  or worktree; that stays behind an explicit user request.

## Failure behavior

`plan` exits non-zero with a reason on stderr only when the hard minimum
cannot be met (an area smaller than 55 x 14 cells for even one pane); the
aspect window alone never fails a plan. `apply` stops the same way, without
repairs, when:

- `herdr pane layout` fails or does not describe the requested pane;
- a `tab create` or `pane split` fails, or its response carries no ID;
- a built pane's rectangle differs from the plan by more than one cell in any
  dimension.

The script never moves, resizes, closes, or focuses an existing pane, and it
passes `--no-focus` to every tab and split it creates, so it never takes focus
from the user.

## Non-goals

Following window resizes, continuous tiling management, configurable
thresholds, and the unpublished `layout.apply` socket method are out of scope.
The constants above live in `herdr/scripts/pane-layout.sh`, which is
authoritative; this page documents them.
