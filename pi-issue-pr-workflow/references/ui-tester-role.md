# ui-tester role

Record formats for the optional `ui-tester` role, the rules that decide
whether it joins a run, and the environment separation values it uses. The
role rules are in [Team specification](../SKILL.md#team-specification) and
[ui-tester verification](../SKILL.md#ui-tester-verification); this file owns
the participation decision, the default task, the evidence contract, its
posting shape, and the one-line report forms.

## Participation

Participation is decided at the Kickoff gate from the Issue body and comments
plus the target repository's conventions. The decision adds no approval round,
and the user can override it in the same reply. It is one of three:

- include — the Issue, its comments, or the repository conventions name a
  user-visible surface (a screen, a page, a component, a rendered document, or
  a message the user receives) that the change can affect;
- exclude — the change is backend, CLI, or an internal refactor only, and no
  user-visible surface is named;
- ambiguous — the material does not settle it. Include the role and re-decide
  from the Draft PR's actual diff.

Never stack guesses to reach a decision: quote the Issue text that supports it
in the one line, and keep the ambiguous state when the material does not settle
the case.

Playwright availability decides participation too. The Playwright skill is
available when `playwright/scripts/pw.sh` exists and `PW_BIN` (default
`playwright-cli`) is executable. When it is unavailable, exclude the role and
name that reason in the line; a task the user supplies overrides this and is
used for the delegation.

State the decision as exactly one line in the kickoff reply:

```text
ui-tester: 同梱（<根拠>）
ui-tester: 除外（<根拠>）
ui-tester: 同梱（曖昧: <根拠>; Draft PR の差分で再判定）
```

## Default task

The task is E2E verification of the Issue's user-visible surface through the
Playwright skill. It is the task whenever this run supplies no other one, so it
never waits for approval; a task this run supplies is preserved as-is and is
never replaced by the default.

## Evidence

The evidence proves the acceptance surface the task names, and the orchestrator
posts it to the PR comment. The `ui-tester` never posts it and never comments
on GitHub itself: it returns the files and their mapping to the verification
items, and posting belongs to the orchestrator
([ui-tester verification](../SKILL.md#ui-tester-verification)).

- Default to screenshots: the smallest count that proves the surface — the
  before and after states, or the completed state.
- Record a video only for a claim that lives in time (an animation, a drag, a
  multi-step flow). The format is WebM, the playwright-cli default.
- Never produce a GIF and never add text overlays with ffmpeg drawtext.
  Explain a video in the PR comment instead, by returning a short timeline with
  clip times (`0:00-0:05 <step> / 0:05-0:12 <step>`).
- Keep every artifact under `PW_ARTIFACT_DIR` and name it after its content,
  because a post needs the body reference and the attachment path to be the
  same literal string, and a video has no alt text.
- The attachment size limit is 10 MB. A larger video is re-encoded with ffmpeg
  by adjusting resolution and CRF until it fits; ffmpeg is optional and is not
  a repository dependency. When it is unavailable or the re-encoded video is
  still over 10 MB, fall back to screenshots and record the fallback in the
  return instead of handing over a file over the limit.

The orchestrator checks the size of every artifact before it posts one.

## Evidence posting

The orchestrator posts the returned artifacts to a PR comment, never into the
PR body; this section fixes the comment shape it builds from the return.

The first line is the marker that identifies the head, with the full SHA:

```text
<!-- pi-issue-pr-workflow:ui-evidence head=<head SHA> -->
```

The body then names every item the return passed and references each artifact
next to the item it proves, using the artifact's absolute path exactly as the
return gives it:

- an image is an inline reference with its alt text,
  `![<what it shows>](<absolute path>)`, and the same path goes into
  `attachments` as `<absolute path>#<what it shows>`;
- a video is a standalone paragraph `![](<absolute path>)` so it renders as a
  player, with the return's timeline below it, because a video has no alt
  text;
- every attachment is referenced: a file the body does not reference is
  appended by the gh CLI and makes the post-write check undecidable.

One comment carries one head. The same head reuses its comment only when the
body already names every item the new return passes; a missing item means a
new comment, because `comments.update` cannot add attachments.

```text
<!-- pi-issue-pr-workflow:ui-evidence head=<head SHA> -->

- <item>: ![<what it shows>](<absolute path>)
- <item>: <description>

![](<absolute path to the video>)

<timeline from the return>
```

## Draft PR re-judgment

After the Draft PR exists and before delegating, re-decide participation from
the actual diff. Delegate when the diff changes a user-visible surface; when it
does not, do not delegate and leave the pane to
[Completion cleanup](#completion-cleanup). Report the re-judgment as the same
one line as at kickoff.

## Completion cleanup

Completion closes only the `ui-tester` pane this workflow created that received
no delegation, once every other completion condition is confirmed, with
`herdr pane close <pane-id>`, and reports exactly one line:

```text
ui-tester: <pane-id> をクローズ（未委譲）
```

Never close a user-created pane or a pane that received a delegation, and close
nothing when the run fails or stops before completion. Only that single pane is
closed: `herdr tab close` and `herdr workspace close` would close delegated
panes with it, so they are not used for this cleanup.

## Delegation body

The body uses the delegation contract that applies to every role and records:

- the task set at the Kickoff gate (this run's task, or the default);
- the target PR and its head SHA;
- the scope the task names (the user-visible surface for a default E2E task);
- the [evidence](#evidence) contract: the artifacts to return, their location
  under `PW_ARTIFACT_DIR`, the 10 MB limit, and the video conditions;
- the environment separation block below;
- the expected return: one line per verification item, each with its artifact
  lines.

## Return report

The return states the head SHA and one line per item; every artifact line
belongs to the item above it, so the item-to-artifact mapping is positional:

```text
item: <verification item>
head: <head SHA>
result: pass | fail | unverified
evidence: <command or observation>
artifact: <absolute path> | <media type> | <bytes> | screenshot | video
timeline: <start>-<end> <step> / <start>-<end> <step>
reason: <required for unverified>
fallback: video -> screenshots; <reason>
```

- `artifact:` repeats once per file and is required for every item whose
  acceptance surface is visual.
- `timeline:` is optional, video-only, and written for the orchestrator to
  quote in the PR comment.
- `fallback:` is optional and records evidence that was replaced, such as a
  video over the 10 MB limit.

After a fix push, the same block is used for the re-verified items; the
re-verification scope is fixed in
[ui-tester verification](../SKILL.md#ui-tester-verification). Per-item findings stay
in the report for the orchestrator's triage, and the mandatory-check rule for
`completed` is the one that applies to every role
([Delegation contract](../SKILL.md#delegation-contract)).

## Environment separation

Take the values from the target repository's conventions. Keep the ui-tester's
state away from the implementation agent's state:

| State | Variable | Note |
|---|---|---|
| pi session storage | `PI_CODING_AGENT_SESSION_DIR` | `--session-dir` wins over the environment variable |
| Playwright session | `PW_SESSION` | named session; `playwright` by default |
| Playwright artifacts | `PW_ARTIFACT_DIR` | screenshots, traces, downloads |
| application state | the application's own variables | follow the application's README or implementation |
| application ports | the application's own variables | bind a port the implementation agent does not use |
