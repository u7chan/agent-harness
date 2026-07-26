---
name: gh-inspect-ci
description: Inspect GitHub pull request checks and failed GitHub Actions logs with the GitHub CLI. Use when asked whether PR CI passed or why a GitHub Actions check failed.
---

# GH Inspect CI

Inspect CI with `gh`. Report results only; do not rerun jobs, edit code, commit, or push.

## Inspect checks

```bash
gh auth status
gh pr checks <pr-number-or-url>
```

If all checks pass, report the successful checks and stop. If a check is pending, report it as pending without treating it as a failure.

## Inspect a failure

Read the run ID from the failing check URL: `actions/runs/<run-id>/job/<job-id>`.

```bash
gh run view <run-id> \
  --json name,workflowName,status,conclusion,url,event,headBranch,headSha

gh run view <run-id> --log-failed
```

Report the failing check, run URL, failed step, concise error, and likely cause. State when logs are unavailable or insufficient; do not guess.
