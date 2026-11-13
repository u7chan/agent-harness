# PR evidence screenshots

How to capture a still screenshot with the changed area marked, so a reviewer
can see what was wrong before and what changed after. The script lives next to
`pw.sh`: [scripts/mark.sh](../scripts/mark.sh).

This reference owns the mechanics only: marks, geometry, capture, and the
check to run before publishing. Which evidence to capture, how many images,
where to keep artifacts, attachment limits, and how to post belong to the
workflow documents that use this reference.

## Prerequisites

- Open the page through `pw.sh open` from the same cwd you will run `mark.sh`
  in, and use the same `PW_SESSION`. `mark.sh` always calls `pw.sh`, so browser
  pinning (`--browser=chromium`), the private artifact directory, the umask,
  and the update-banner stripping stay in effect.
- `playwright-cli` must support `screenshot [target]` (an element selector).
  It has no `--clip`; the marked area is captured as an element screenshot.
  Verified with 0.1.24.

## Marks

- Put marks on still before/after images. Do not publish a before/after pair
  without them.
- Before is a red dashed box; after is a green dashed box.
- The label says what is wrong or what changed in 1-8 characters (the script
  rejects a longer label). Prefer `切れる`, `余白なし`, `1 行に`, `新規`; avoid
  `ここ` and `変更`.
- One to three marks per image is the guideline. If you need more, split the
  screen instead of shrinking labels.
- Mark the same component on both sides. When a component exists on only one
  side, mark the parent component on the other side.

## Commands

```bash
PW_SESSION=<session> mark.sh before <target> <label>
PW_SESSION=<session> mark.sh after  <target> <label>
PW_SESSION=<session> mark.sh shot   <absolute-path.png> [margin]
PW_SESSION=<session> mark.sh clear
```

- `<target>` is a snapshot ref such as `e123` or a selector that matches one
  element. Take a fresh snapshot after the page changes; refs are per snapshot.
- `shot` accepts only an absolute `.png` path, for example under
  `PW_ARTIFACT_DIR`. Keep artifacts out of the working tree.
- `shot` prints the path, the PNG width and height, and the file size. The
  width and height come from the saved PNG, not from the page.
- `shot` removes the marks after saving. If capture fails, it keeps them so the
  next attempt can reuse them; run `clear` when giving up.
- `clear` succeeds when there is nothing to remove, including a closed session.

## Capture flow

```bash
export PW_ARTIFACT_DIR="${TMPDIR:-/tmp}/evidence/<topic>"
PW_SESSION=playwright mark.sh clear
PW_SESSION=playwright mark.sh before e6 "余白なし"
PW_SESSION=playwright mark.sh shot "$PW_ARTIFACT_DIR/01-before.png"
# open the changed screen, snapshot again, then mark the same component
PW_SESSION=playwright mark.sh after e4 "余白あり"
PW_SESSION=playwright mark.sh shot "$PW_ARTIFACT_DIR/01-after.png"
```

Capture before and after at the same viewport size: `pw.sh resize <width> <height>`.

Do not scroll between placing marks and running `shot`: marks are positioned
fixed at placement time and do not follow the page.

Read every saved image before publishing it. Check that the mark covers the
intended component, the label is readable, and nothing sensitive is visible.

## Geometry and limits

- Dialogs and popovers: a mark appended to the page body is painted under the
  top layer. The script places marks inside the open `dialog` or
  `[popover]:popover-open` that contains the target.
- `transform`, `filter`, `perspective`, or `contain` on the dialog changes the
  reference origin for fixed elements. The script measures the origin and keeps
  the mark inside the dialog border. Scaled or rotated dialogs are not
  verified; check the saved image.
- Iframes: a mark cannot be placed inside one. Mark the iframe element itself.
- Long elements: only the part inside the viewport is marked.
- The margin is clamped to the viewport, so a wide mark near the edge can
  produce an image narrower than mark + 2 x margin.
- Shadow roots: the script appends marks to the element's root when it is an
  open shadow root. A closed shadow root cannot be reached; the script then
  fails with `not-visible` instead of capturing an unmarked area.
- Page CSS that repaints `div` elements with `!important` can cover the
  capture helper. Check the saved image.
- Element screenshots scroll the target into view; a fixed mark does not move,
  so keep the page still between marking and capturing.

## When a mark cannot be placed

Do not drop the evidence. Take an unmarked screenshot with `pw.sh screenshot`,
record why the mark was impossible, and let the workflow report the fallback in
its evidence format.

## What not to capture

Close, filter, or switch to a test user before capturing a screen that shows
real names, email addresses, tokens, or API keys. Read the image before
publishing it; the script cannot detect personal data for you.

## Capturing an attachment test image

For a safe end-to-end check of the attachment path, use a local fixture page
with no personal data (for example a card that only says "まだありません。") and
capture it with this script. Do not use a real account screen.
