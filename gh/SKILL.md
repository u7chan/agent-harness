---
name: gh
description: Perform GitHub operations through a low-level common layer. Reads SKILL.md for action selection, validates input via actions.json, and dispatches through gh.sh with unified auth, target resolution, and error handling.
---

# GH

Use `gh.sh` as the single dispatcher for all GitHub operations.

```bash
gh/scripts/gh.sh <action-name> [json-input-file]
```

## Action Index

| Intent | Action | Permission |
|--------|--------|------------|
| List all available actions | `actions.list` | read |
| Describe an action's schema | `actions.describe` | read |
| Get repository metadata | `repo.get` | read |
| Get a single issue | `issue.get` | read |
| List repository issues | `issue.list` | read |
| Create a new issue | `issue.create` | write |
| Update issue title/body | `issue.update` | write |
| Close an issue | `issue.close` | sensitive-write |
| Reopen an issue | `issue.reopen` | sensitive-write |
| Add labels to an issue | `labels.add` | write |
| Remove a label from an issue | `labels.remove` | sensitive-write |
| Replace all labels on an issue | `labels.set` | sensitive-write |
| Add assignees to an issue | `assignees.add` | write |
| Remove assignees from an issue | `assignees.remove` | sensitive-write |
| Set milestone on an issue | `milestone.set` | write |
| Clear milestone from an issue | `milestone.clear` | sensitive-write |
| Add a sub-issue | `issue.subissues.add` | write |
| Remove a sub-issue | `issue.subissues.remove` | sensitive-write |
| Reprioritize a sub-issue | `issue.subissues.reorder` | write |
| List pull requests | `prs.list` | read |
| Search pull requests | `prs.search` | read |
| Get a pull request | `pr.read` | read |
| Get pull request diff | `pr.diff.read` | read |
| List pull request files | `pr.files.read` | read |
| List pull request commits | `pr.commits.read` | read |
| List pull request check runs | `pr.checks.read` | read |

## Permission

- `read` — No side effects. Read-only GitHub data access.
- `write` — Creates or modifies GitHub data. Requires confirmed intent from the user.
- `sensitive-write` — Irreversible operations that affect others. Requires explicit user confirmation.

## Rules

- Only the active `gh` account is used; stop on any host other than `github.com`.
- Stop when the target is ambiguous; do not guess.
- All actions return a common JSON envelope with `status`, `action`, `target`, `data`, and optional `error`.
- Large output is saved to working-directory temp files, not streamed into conversation context.
- Do not modify API arguments or endpoints on retry.
