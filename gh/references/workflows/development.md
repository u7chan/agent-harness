# Development Workflow

Common GitHub action sequences for issue-driven development.

## 1. Read issue

Basic:
- `issue.get`
- `comments.read`

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
