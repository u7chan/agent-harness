---
name: gh
description: Perform GitHub operations through a low-level common layer. Reads SKILL.md for action selection, validates input via actions.json, and dispatches through gh.sh with unified auth, target resolution, and error handling.
---

# GH

Use `gh.sh` as the single dispatcher for all GitHub operations.

```bash
gh/scripts/gh.sh <action-name> [json-input-file]
```

## Action Selection

Select the smallest matching category set.

| Intent | Categories |
|---|---|
| Discover or describe actions | `catalog` |
| Repository information | `repository` |
| Issue operations | `issue`, `subissue`, `metadata`, `comment` |
| Pull request operations | `pr`, `comment` |
| Pull request review | `pr`, `review-comment`, `review`, `review-thread`, `comment` |
| Common issue-driven development | `references/workflows/development.md` |

### Selection rules

- Do not list all actions upfront.
- Search only the minimal categories needed for the user intent.
- You may skip `actions.describe` when the action input is clear.
- Refer to `actions.json` for action descriptions, permissions, and schemas.

## Permission

- `read` — No side effects. Read-only GitHub data access.
- `write` — Creates or modifies GitHub data. Requires confirmed intent from the user.
- `sensitive-write` — Irreversible operations that affect others. Requires explicit user confirmation.

## Rules

- Only the active `gh` account is used; stop on any host other than `github.com`.
- Stop when the target is ambiguous; do not guess.
- All actions return a common JSON envelope with `status`, `action`, `target`, `data`, and optional `error`.
- Internal scratch files live in the dispatcher temp dir and are deleted when the dispatcher exits.
- Large output is saved to an artifact file, not streamed into conversation context. Artifacts are saved under `$GH_ARTIFACT_DIR` (default: a per-invocation `/tmp/gh-artifacts-XXXXXXXX` directory) and survive the dispatcher exit, so a later step can read `output_file`. The caller is responsible for deleting artifacts after use (`rm -f "$output_file"`). Set `GH_ARTIFACT_DIR` to control the save location.
- Read actions with potentially large responses (currently `pr.files.read`) bound what enters the conversation. Within the inline boundary (`GH_INLINE_MAX_BYTES`, default 20000 bytes) `data` is returned inline unchanged. Beyond it, `data` becomes `{items, truncated: true, total_count, inline_count, omitted, output_file, size_bytes}`: `items` is the lightened view with the fields named in `omitted` left out, capped at `GH_INLINE_MAX_ITEMS` (default 100) items and at `GH_INLINE_MAX_BYTES` bytes of encoded items; `output_file` holds the complete data including the omitted fields and items beyond `inline_count`. Nothing is discarded silently: read `output_file` for the parts left out and delete it when done. If the artifact cannot be saved, the action fails with `ARTIFACT_ERROR` instead of returning a truncated result.
- Do not modify API arguments or endpoints on retry.

## Targets

Actions address an issue/PR by `number`, and may take a `reference` in one of these forms:

- `owner/repo` — pins the repository (pair with `number` when the action targets one issue/PR).
- `https://github.com/<owner>/<repo>` — repository URL.
- `https://github.com/<owner>/<repo>/pull/<number>` and `.../issues/<number>` — issue/PR URL.

Target resolution (`gh/scripts/common/target.sh`) enforces a positive-integer contract:

- Issue/PR numbers must be positive integers. `0`, negatives, decimals, and non-numeric values fail with `TARGET_ERROR` before any API call — in URL number segments and in the numbers target resolution consumes (PR actions and owner/repo + number references). Number inputs that actions put straight into an API path without target resolution (e.g. `issue.*` number-only inputs) are not covered by this contract and fail at the API instead.
- URL fragments (`#...`), query strings (`?...`), trailing slashes, and any path after the number (e.g. `/pull/12/files`, `/pull/12/commits`) address the same issue/PR: they are normalized away, and the envelope `target.url` is the canonical, decoration-free URL. `target.repository` keeps the reference's spelling.
- Only `https://github.com` URLs are accepted, and every URL must name the repository: an owner-only URL (`https://github.com/<owner>` with optional query/fragment/trailing slash) fails with `TARGET_ERROR` instead of reusing the owner as the repo. Other hosts, non-URL input, missing number segments, and paths that are not `/<owner>/<repo>` plus optional `pull/<n>` / `issues/<n>` fail the same way; so does a reference whose type does not match the action (e.g. an `/issues/...` URL for a PR action). No API call happens for a rejected reference.
- Owner/repo segments must be GitHub-name characters (ASCII letters/digits plus `-`, `_`, `.`); only a segment that is exactly `.` or `..` is rejected — dots inside a name (e.g. `release..notes`) stay accepted.

## Attachments

`issue.create`, `issue.update`, `pr.create`, `pr.update`, and `comments.create` accept an `attachments` input: an array of local file references in `'path#alt'` form (alt text is images-only). Attachments route the write through the gh CLI subcommand (`--attach`; gh >= 2.99.0) instead of `gh api`.

- Requires gh >= 2.99.0, the `github.com` host, and repository write permission (write actions already require write).
- Supported formats: PNG/JPEG/GIF/WebP/SVG images up to 10 MB, MP4/MOV/WebM videos up to 10 MB in Free-plan repositories; 10-100 MB requires a paid plan. At most 50 files per command; the same file cannot be attached twice. Videos do not support alt text.
- On the `pr.create` attachment route, omitting `maintainer_can_modify` uses the `gh pr create` default of maintainer-editable (`true`), unlike the attachments-less API route default.
- Paths resolve against the current working directory; actions never `cd`. Make every body reference and its attachment item the same literal string (e.g. `![alt](./shot.png)` with `attachments: ["./shot.png"]`).
- A body reference to an attached path is rewritten in place to the uploaded URL (a video referenced as a standalone paragraph `![](path)` renders as a player; in a sentence it renders as a link). Attachments the body does not reference are appended to the end of the body.
- Post-write verification cannot compare uploaded URLs, so it checks: identity match; referenced path literals are gone from the stored body; and, when unreferenced attachments were appended, the submitted body is an exact prefix of the stored body. Do not mix referenced and unreferenced attachments in one command: the prefix check cannot hold and the result reports `unknown_outcome`.
- Comments created with attachments never return `already_applied`; retries or re-runs create duplicate comments, so check the comment list for an existing comment before retrying or re-running.
- Errors: `ATTACH_UNSUPPORTED` (gh version below 2.99.0, non-github.com host, or more than 50 files), `ATTACH_INVALID` (bad item format, unsupported extension, missing or empty file, size over the limit, video alt text, duplicate file, or `maintainer_can_modify` combined with `attachments` on `pr.update` because `gh pr edit` has no maintainer flag). To change `maintainer_can_modify`, first run an attachments-less update, then run the attachments update.
