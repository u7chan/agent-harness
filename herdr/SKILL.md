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

### 2. Agent detection

```bash
herdr pane get <pane-id>
# read .result.pane.agent_status
```

- `agent_status != unknown` → agent is already auto-detected. Assign a name and go to step 3:

```bash
herdr agent rename <pane-id> <name>
```

- `agent_status == unknown` → start manually:

```bash
herdr agent start <name> --kind <kind> --pane <pane-id>
```

Kind: `codex`, `opencode`, `claude`, etc. See `herdr agent start --help` for supported kinds.

### 3. Send prompt

```bash
herdr agent prompt <target> "<text>" --wait --timeout 30000
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

### Error recovery

- **name conflict** on `agent start` → check existing agents with `herdr agent list`. If an agent is already registered on the same pane via auto-detection, use `agent rename` instead. If the desired name is already taken by an agent on a different pane, choose a different name.
- **pane not found** on `pane get` → the pane may not have finished initializing. Wait a moment and retry.

## Send to an existing agent

Find the agent, then prompt, wait, and read:

```bash
herdr agent list
herdr agent prompt <name-or-pane-id> "<text>" --wait --timeout 30000
herdr agent wait <name-or-pane-id> --timeout 1800000
herdr agent read <name-or-pane-id> --source recent-unwrapped --lines 200
```

## Map user intent to agent kind

| User says | Agent kind |
|-----------|------------|
| codex / レビュー / review | `codex` |
| opencode / 実装 / impl | `opencode` |

## Agent naming

Name agents by `<kind>-<role>`:

| Role | Example name |
|------|-------------|
| Review PR | `codex-review` |
| Implement feature | `opencode-impl` |
| Verify fix | `codex-check` |

## Rules

- Use `--no-focus` for background work. Do not switch focus unless asked.
- Parse IDs from JSON responses. Do not guess pane or agent IDs.
- Do not close panes or kill agents unless explicitly requested.
- All delegation happens within the current workspace via `pane split`. Do not create a separate workspace for delegation — this causes workspace-scoped context confusion for the receiving agent.
