---
name: herdr
description: Start and prompt coding agents in adjacent Herdr panes. Use when asked to delegate work to another agent (review, implement, check) via Herdr.
---

# Herdr (mini)

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

## Delegate to a new agent

### 1. Split pane

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
# read .result.pane.pane_id
```

Use `down` when the caller pane is already narrow.

### 2. Start agent

```bash
herdr agent start <name> --kind <kind> --pane <pane-id>
```

Kind: `codex`, `opencode`, `claude`, etc. See `herdr agent` for installed kinds.

### 3. Send prompt

```bash
herdr agent prompt <target> "<text>" --wait --until working --timeout 30000
```

Target = agent name or pane ID. Prefer agent name when known.

### 4. Wait

```bash
herdr agent wait <target> --timeout 1800000
```

### 5. Read output

```bash
herdr agent read <target> --source recent-unwrapped --lines 200
```

## Send to an existing agent

Find the agent, then `agent prompt`:

```bash
herdr agent list
herdr agent prompt <name-or-pane-id> "<text>" --wait --until working --timeout 30000
```

## Map user intent to agent kind

| User says | Agent kind |
|-----------|------------|
| codex / レビュー / review | `codex` |
| opencode / 実装 / impl | `opencode` |

## Rules

- Use `--no-focus` for background work. Do not switch focus unless asked.
- Parse IDs from JSON responses. Do not guess pane or agent IDs.
- Do not close panes or kill agents unless explicitly requested.
