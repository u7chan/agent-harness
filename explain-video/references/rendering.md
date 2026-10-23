# Rendering animated diagrams

Use Node.js and the existing [Playwright wrapper](../../playwright/SKILL.md), then
FFmpeg. The helper only prepares timestamp capture code and encodes/checks its
frames; explanation, layout, and visual judgment remain the agent's work.

## Editable source

Create a trusted, self-contained UTF-8 HTML file outside the repository. Inline
SVG, CSS, and scripts; use installed fonts. Do not fetch remote images, fonts,
libraries, or data. Captions are part of the drawing, so no subtitle player or
FFmpeg text renderer is needed.

Define `window.renderAt(seconds)`, optionally async. It must set the **entire**
visible state from that absolute timestamp, including scene visibility and labels.
Calling it twice, or out of order, must produce the same picture. Do not depend on
previous calls, wall-clock time, CSS animations/transitions, timers, or randomness.
Each capture chunk reloads the HTML. Stop motion before a caption needs to change,
and give the final conclusion its own reading time.

For example, move a token along a labeled connection (leave the labels separate):

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<style>
  body { margin: 0; background: #102035; color: white; font: 32px sans-serif; }
  h1, p { margin: 40px; }
  svg { display: block; margin: 40px; }
</style>
<h1>Proposed design — not implemented</h1>
<p>One request moves from the client to the worker.</p>
<svg width="1160" height="200" viewBox="0 0 1160 200">
  <text x="20" y="50" fill="white">Client</text>
  <text x="920" y="50" fill="white">Worker</text>
  <path d="M80 130 H1000 l-20 -12 m20 12 l-20 12" fill="none"
        stroke="#9eb7cc" stroke-width="4"/>
  <circle id="request" cy="130" r="14" fill="#ffcc75"/>
</svg>
<p>Illustrative flow, not measured execution speed.</p>
<script>
  window.renderAt = seconds => {
    const progress = Math.min(1, Math.max(0, (seconds - 1) / 3));
    document.getElementById('request').setAttribute('cx', 80 + 920 * progress);
  };
  renderAt(0);
</script>
</html>
```

## Prepare

Use the absolute helper path resolved from the `SKILL.md` read. The output
directory must be new, its parent must exist, and it must be outside the checkout.
The helper refuses to replace an existing directory. Defaults are 24 fps and
1280×720, not mandatory presentation requirements; choose duration and dimensions
for the actual message. Width/height must be even for H.264 `yuv420p`.

```bash
VIDEO=<skill-dir>/scripts/video.mjs
SOURCE=<absolute-source.html>
OUT=<new-absolute-output-directory>
node "$VIDEO" prepare "$SOURCE" "$OUT" 12
# Optional positional settings: seconds fps width height
# node "$VIDEO" prepare "$SOURCE" "$OUT" 12 24 1280 720
```

`prepare` checks FFmpeg/ffprobe execution and copies the editable source to
`source.html`. `render.json` records the frame count, frame rate, dimensions, and
capture filenames. `capture-*.js` embeds that exact source, samples `i / fps`, and
writes `frames/frame-000000.png` onward. Each chunk captures at most 120 frames to
bound individual browser calls. Capture code blocks network requests, awaits
fonts and `renderAt`, and takes viewport PNGs in CSS pixels. No server is needed.

## Capture through Playwright

Read [running code](../../playwright/references/running-code.md) and use `pw.sh`
from the actual Playwright skill read. Keep the same cwd and a unique `PW_SESSION`
for every call. Keep `PW_ARTIFACT_DIR` outside the repository; use the output
directory or another private directory. Stay headless unless explicitly needed.

```bash
PW=<playwright-skill-dir>/scripts/pw.sh
export PW_SESSION=<unique-video-session>
export PW_ARTIFACT_DIR="$OUT"
"$PW" open about:blank
"$PW" --raw run-code --filename="$OUT/capture-0000.js"
# Run EVERY capture file listed by prepare, in order, through the same wrapper.
# Use the wrapper's batch mode for consecutive chunks needing no intermediate decision.
"$PW" close
```

Always close the owned session, even when a capture fails. Do not use `recover`,
`kill-all`, or someone else's session. Check each result for errors; do not treat
an empty or partial frame directory as success.

Preview key scene timestamps before full capture: use the first capture's
`setContent`/viewport setup, call `window.renderAt(t)` through `page.evaluate`,
and save a screenshot outside `frames/`. Inspect it with an image viewer. Do not
mix preview PNGs into the numbered encoding sequence.

## Encode and inspect

```bash
node "$VIDEO" encode "$OUT"
```

The helper requires the exact nonempty frame sequence, encodes a silent
`video.mp4` using H.264 / `yuv420p` with fast-start metadata, checks dimensions,
duration and decoded frame count with ffprobe, and fully decodes it with FFmpeg.
Only after these pass does it give the MP4 its final name and write
`verification.json` with the measured media properties. Existing videos/reports
are not replaced. A failed run may leave a partial file; inspect it, and use a
fresh output directory for a new run rather than silently overwriting evidence.

View the MP4 and compare its contents to the evidence and outline. If playback
is unavailable, extract decoded stills at scene and transition times with FFmpeg
and disclose this limitation; do not claim a continuous-playback review.
Keep publication separate: return local paths to the caller, who may use the gh
skill to attach them. This skill does not impose upload limits or post anything.

For an edit, change the HTML/outline and run `prepare` into a fresh directory;
capture files snapshot the source and do not follow subsequent HTML edits.
