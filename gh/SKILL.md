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
