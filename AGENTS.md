# AGENTS.md

## Rules

- Direct push to `main` or `epic` is prohibited. Always create a branch and open a PR.
- When working on an `epic` branch, open the PR targeting the `epic` branch. Otherwise, target `main`.
- Branch names must use lowercase kebab-case (e.g. `feat/add-login-page`).
- Commit messages must include a prefix and be written in English (e.g. `feat(auth): add login page`).
- PR descriptions must be written in Japanese and include the following sections:
  - `## Issues`
    - Format: `- #{No}`
  - `## Why`
  - `## Summary`
  - `## Changes`
  - `## Verification`
    - Format: `- [ ] {CheckList}`
- When addressing PR feedback, always reply to the relevant comment. For non-inline comments, reply with `Re: ` as a top-level comment.
