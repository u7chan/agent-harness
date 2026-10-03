# Development Workflow

Common GitHub action sequences for issue-driven development.

## 1. Read issue

Basic:
- `issue.get`
- `comments.read`

`issue.get` includes `blockedBy` and `blocking`. Each connection contains
`nodes` (`number`, `title`, lowercase `state`, `html_url`), `totalCount`, and
`hasNextPage`. At most 100 nodes per direction are read; cursors are not followed.

### Record or remove dependencies

- `issue.dependencies.add` / `issue.dependencies.remove` (category `dependency`,
  permission `write` for both).
- Supply `number`, at least one non-empty `blocked_by` or `blocking` array, and
  `grant: "write"`. All numbers are positive integers from the current repository;
  URLs and cross-repository references are not accepted.
- `blocked_by: [A]` means A blocks the target; `blocking: [B]` means the target
  blocks B. Both directions may be submitted together; duplicate numbers within
  a direction are ignored. Mutations are sent only for relationships that differ.
- Reapplying the desired state returns `already_applied` without a mutation.
  Writes return the same two connection objects as `issue.get`.
- GraphQL reads share REST's transport retries and sanitized diagnostics.
  Mutations are single-fire (`GH_RETRY_MAX=1`); GraphQL errors are never retried.
  An explicit GraphQL error before any successful mutation is `API_ERROR`, not
  `GRANT_INSUFFICIENT` (which describes the dispatcher's local grant).
- Unverifiable post-write state, malformed/transport-failed mutation responses,
  or a partially applied batch return `unknown_outcome`. Re-read before deciding
  whether to retry; batches are not atomic and are not rolled back automatically.
- A truncated list cannot prove absence: a requested but unseen relationship
  fails the pre-check with `API_ERROR`; deletion that cannot prove absence after
  the write returns `unknown_outcome`.

## 2. Create pull request

Prerequisites:
- Implementation branch is pushed to remote
- Base branch and head branch are determined
- Change summary and verification results are prepared

Action:
- `pr.create`

Optional:
- `reviewers.request`

## 3. Review pull request

PR and changes:
- `pr.read`
- `pr.diff.read`
- `pr.files.read`
- `pr.commits.read`
- `pr.checks.read`

Existing discussion and review state:
- `comments.read`
- `review-comments.read`
- `reviews.read`
- `review-threads.read`

## 4. Post feedback

General PR comments:
- `comments.create`
- `reviews.create`

Inline diff comments:
- `review-comments.create`

Replies to existing comments:
- `comments.reply`
- `review-comments.reply`

## 5. Follow up review feedback

- Use `review-threads.read` and `review-comments.read` to identify targets
- Confirm the issue has been addressed before replying
- Only use `review-threads.resolve` after the reviewer has re-confirmed
- Do not auto-resolve threads just because code was pushed

## Boundary

The following are outside the scope of the `gh` skill and are not automated by this workflow:
- Branch creation
- Code implementation
- Testing, linting, formatting
- Committing
- Pushing

`pr.create` requires a pushed branch as a prerequisite.
