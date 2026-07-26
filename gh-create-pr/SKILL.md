---
name: gh-create-pr
description: Create a GitHub pull request from an already-pushed branch with the GitHub CLI. Use when asked to open a PR with an explicit base, head, title, and Markdown body.
---

# GH Create PR

Create one pull request with `gh pr create`. Do not edit files, commit, push, merge, or review the PR.

## Preconditions

- Run `gh auth status`.
- Confirm the repository, base branch, head branch, and pushed commits.
- Stop on the default branch or if the head branch is not pushed.
- Return an existing PR instead of creating a duplicate.

## Create

Prepare the complete PR body in a temporary Markdown file. Follow repository-specific PR conventions when available. Pass Markdown through `--body-file`, not an inline shell argument.

```bash
gh pr create \
  --base <base-branch> \
  --head <head-branch> \
  --title "<title>" \
  --body-file <body-file>
```

Add `--draft` only when the user requests a draft. If creation fails, report the error without changing commits or branches.

## Verify

```bash
gh pr view <head-branch> \
  --json number,title,url,state,isDraft,baseRefName,headRefName,body
```

Confirm the title, body, base, and head. Remove the temporary body file and return the PR URL.
