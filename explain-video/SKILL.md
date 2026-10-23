---
name: explain-video
description: Explain an agreed design or implemented functionality in a short, captioned animated-diagram video. Use for design explainers, PR walkthroughs, or visual explanations of code changes; produces local artifacts without publishing them.
---

# Explain Video

Turn evidence into a short, silent MP4 whose motion explains a sequence, transfer,
state change, or before/after difference. Produce animated diagrams, not application
screen recordings. Stop at local artifact handoff; never upload, post, or edit an
Issue/PR as part of this skill.

## Prerequisites

Linux, Node.js, FFmpeg with the `libx264` encoder, ffprobe, and the existing
[Playwright skill](../playwright/SKILL.md) with playwright-cli and its Chromium.
Fonts covering the caption language must already be installed (for example, IPA
Gothic for Japanese). These are requirements for this skill, not every repository skill;
FFmpeg remains optional for other workflows.

Check that `node --version`, `ffmpeg -version`, and `ffprobe -version` succeed.
Use the Playwright skill's `open` to check the actual browser; check font rendering
in a sample frame, not just a font-name lookup. If a prerequisite is missing, stop
with the missing item. Do not install dependencies or change global settings.
A caller may explicitly select an already installed tool version for this run.

Resolve this skill's `scripts/video.mjs` relative to the **SKILL.md actually read**.
Read [the rendering procedure](references/rendering.md) before generating media.

## Workflow

1. **Frame the explanation.** Establish the audience, one-sentence takeaway, and
   scope from the request. Ask only when missing information changes the result.
   Accept conversational agreements, design documents, PRs, local diffs, relevant
   code, and tests. Neither a PR nor GitHub access is required.
2. **Check the evidence.** Read the relevant sources, not just a PR description.
   Use the [gh skill](../gh/SKILL.md) for GitHub reads. Keep design intent,
   implemented behavior, and actually verified behavior distinct. Label an
   unimplemented design and illustrative data visibly. Do not invent measurements,
   counts, guarantees, or performance claims. Animation time is not execution time.
3. **Storyboard.** Write a brief outline with scene times, one message per scene,
   the motion that explains it, captions, and evidence/limitations. Select only the
   necessary parts of purpose → mechanism/change → concrete flow → result. For a
   comparison, show the shared foundation as well as what changes; do not pretend
   the alternative lacks capabilities it actually has. Keep this outline beside
   the editable source, outside the repository.
4. **Draw and preview.** Author self-contained HTML/SVG with burned-in captions
   and the timestamp function described in the rendering procedure. Use labels
   and shapes, not color alone. Prefer splitting a scene or reducing content over
   shrinking text. Motion should explain, not decorate; keep labels stationary
   while a token moves along an arrow. Avoid flashing and gratuitous transitions.
   Capture and inspect the key scenes before rendering the whole video.
5. **Render and encode.** Use the existing Playwright wrapper, an isolated session,
   and a fresh private output directory outside the repository. Capture explicit
   timestamps rather than recording elapsed wall time. Run every generated capture
   chunk, then encode and validate with `video.mjs`. Always close the owned browser
   session from the same cwd, including after a failure; do not run global recovery.
6. **Validate the explanation.** Compare the captions and key frames to the outline
   and evidence. Inspect frames throughout each scene and around transitions for
   missing glyphs, clipping, overlap, contrast, and pacing. Play the MP4 when a video
   viewer is available; otherwise inspect timestamped decoded frames and disclose
   that continuous playback was not checked. Check that captions remain long enough
   to read. Metadata/decode success alone does not prove accuracy or clarity.
   Revise and regenerate when the explanation is misleading or hard to follow.
7. **Hand off.** Return the validated MP4 path, editable HTML and outline paths,
   key preview paths, a synopsis, duration, resolution, frame rate, file size, and
   verification caveats. Do not claim completion after a failed or unknown render.

## Boundaries

- Follow [the shared language rule](../kabeuchi/SKILL.md#language) for captions,
  outlines, questions, and reports.
- Do not redesign or implement the subject, fabricate missing evidence, or
  expose secrets/personal data in examples. Confirm material unknowns or report
  them as limitations.
- Keep generated HTML, frames, videos, and reports outside the repository. Use
  trusted, locally authored source without remote resources, timers, or randomness.
- Do not add speech, GIFs, mandatory loops, themes, plugins, a video DSL, a job
  service, or a new browser/GitHub management layer.
- Verify by actually generating and inspecting a short representative result.
  Do not build a dedicated mock suite, visual-regression system, or browser CI
  environment to prove that this instruction workflow exists.
