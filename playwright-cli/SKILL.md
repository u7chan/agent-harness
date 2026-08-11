---
name: playwright-cli
description: Drive a Playwright browser through a low-level common layer. Reads SKILL.md for action selection, validates input via actions.json, and dispatches through playwright.sh with session state, request journaling, and unified error envelopes.
---

# Playwright CLI

Use `playwright.sh` as the single dispatcher for all browser operations.

```bash
playwright-cli/scripts/playwright.sh <action-name> [json-input-file]
```

## Action Selection

Select the smallest matching category set.

| Intent | Categories |
|---|---|
| Discover or describe actions | `catalog` |
| Check the CLI runtime contract | `runtime` |
| List, open, or close browser sessions | `browser` |
| Navigate or inspect the current page | `page` |
| Manage browser tabs | `tab` |
| Read console diagnostics | `debug` |
| Click, fill, select, check, or hover | `interaction` |
| Capture artifacts | `artifact` |
| Resolve an unknown-outcome session | `recovery` |

### Selection rules

- Do not list all actions upfront.
- Search only the minimal categories needed for the user intent.
- You may skip `actions.describe` when the action input is clear.
- Refer to `actions.json` for action descriptions, permissions, and schemas.
- Browser actions operate on a harness-owned session; never touch a session that `browser.list` does not report as owned.

## Permission

- `read` — No side effects. Requires no grant.
- `write` — Creates or modifies browser state. Requires a confirmed user intent expressed as `grant: "write"` in the input.
- Write actions also require a caller-generated `request_id` (UUID); it is the idempotency key for one user intent.

## Rules

- A browser session is owned by this harness from the moment `browser.open` is requested; never operate on a live session without an ownership marker.
- Never retry a write action with the same `request_id`, and never unconditionally retry a failed write. A new attempt needs a new `request_id`.
- After `unknown_outcome`, only `recovery.observe` and `page.snapshot` are allowed until the user resolves the outcome.
- Session names, URLs, and selectors are validated before any CLI process starts; do not bypass validation.
- Snapshot and screenshot outputs may contain credentials; confirm with the user before sharing them externally.
- All actions return a common JSON envelope with `status`, `action`, `permission`, `session`, `data`, `artifacts`, `runtime`, and optional `error`.
