---
name: herdr
description: Delegate work to coding agents in sibling Herdr panes. Use only when the user explicitly mentions Herdr or asks to use Herdr to delegate, inspect, prompt, or coordinate another agent. Requires HERDR_ENV=1.
---

# Herdr

Use the `herdr` CLI directly to delegate work to coding agents in the current workspace and tab.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

If either check fails, explain that Herdr is unavailable and stop.

## Inspect workspace panes

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID" | jq -r '.result.panes[] | [.pane_id, .tab_id, (.label // "-"), (.agent // "-")] | @tsv'
```

Columns: `pane_id`, `tab_id`, `label`, `agent`

## Delegate to a new agent

### 1. Create a sibling pane

Honor a direction requested by the user. Otherwise inspect the current layout:

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split right when there is enough width; otherwise split down.

```bash
herdr pane split \
  --current \
  --direction right \
  --cwd "$PWD" \
  --no-focus
```

Read the new pane ID from `.result.pane.pane_id`. Do not guess it.

### 2. Start or rename the agent

Inspect the new pane:

```bash
herdr pane get <pane-id>
```

- If a recognized agent is already running, assign it a unique name:

```bash
herdr agent rename <pane-id> <name>
```

- If the pane contains an available shell, start the requested agent:

```bash
herdr agent start <name> --kind <kind> --pane <pane-id>
```

- If an unrecognized agent or another foreground process occupies the pane, do not overwrite it. Inspect the pane or create another pane.

Use the kind requested by the user. When unspecified:

| Task | Default kind |
|---|---|
| Implementation | `opencode` |
| Review or verification | `codex` |

Name agents using `<kind>-<role>`, adding a short suffix when the name is already in use.

Examples:

```text
opencode-impl
codex-review
codex-check
```

### 3. Send the task

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

The default is fire-and-forget: the command returns immediately without blocking the caller's session. Retrieve results after the delegate becomes idle via `herdr agent get` / `herdr agent read` (the user's next turn).

Use `--wait --timeout <ms>` only when the caller is running in auto mode with no user interaction and cannot continue without the delegate's result. Be aware that `--wait` blocks the caller's event loop until the delegate idles (or until the timeout), preventing new user prompts from being processed during that window.

For long-running work when `--wait` is used, wait again only when the agent is still working:

```bash
herdr agent wait <name-or-pane-id> --timeout 1800000
```

### 4. Read the result

```bash
herdr agent get <name-or-pane-id>
herdr agent read <name-or-pane-id> \
  --source recent-unwrapped \
  --lines 200
```

Treat `blocked` as requiring input. Treat `unknown` as unclassified, not completed.

If prompt, wait, or read fails, inspect `agent get` and `agent read` before retrying. Do not blindly resend a prompt that may already have been delivered.

## Send to an existing agent

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

The default is fire-and-forget. See [Send the task](#3-send-the-task) for notes on `--wait` usage. Once the delegate becomes idle, read the result:

```bash
herdr agent read <name-or-pane-id> \
  --source recent-unwrapped \
  --lines 200
```

## Create a worktree workspace

Resolve real workspace IDs first; `w1` style IDs are session-local and never reused:

```bash
herdr workspace list
```

Create a Git worktree and open it as a new workspace:

```bash
herdr worktree create --cwd "$PWD" --branch <branch-name>
```

- Prefer `--cwd` over `--workspace ID`; a guessed ID fails with `workspace_not_found`.
- The checkout is created under the configured worktree directory and the branch is created from `HEAD` when it does not exist locally.
- Focus stays unchanged by default; use `--focus` to switch to the new workspace.
- Read new IDs from `.result.workspace.workspace_id`, `.result.tab.tab_id`, and `.result.root_pane.pane_id`. Do not guess them.

## Remove a worktree workspace

Confirm the target workspace is a linked worktree, not the base checkout:

```bash
herdr worktree list --cwd "$PWD" | jq -r '.result.worktrees[] | [.branch, .open_workspace_id, .is_linked_worktree] | @tsv'
```

Remove the checkout:

```bash
herdr worktree remove --workspace <workspace-id>
```

- Only pass a workspace whose `is_linked_worktree` is `true`. Passing the base workspace fails with `not_linked_worktree`.
- The linked workspace closes automatically when its checkout is removed.
- `worktree remove` deletes the checkout only; the branch is never deleted.
- A dirty checkout (modified or untracked files) fails with `dirty_worktree_requires_force`; add `--force` only when discarding those files is acceptable.

## Rules

- Use Herdr only when explicitly requested.
- Keep delegation in the current workspace, tab, and working directory unless the user requests otherwise.
- Use `--no-focus` for background work.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on UI focus.
- Parse IDs and state from JSON responses. Do not infer them from pane order.
- Do not create a workspace, tab, or worktree unless explicitly requested.
- Do not close panes, kill agents, or stop the Herdr server unless explicitly requested.
- When command syntax is unclear, inspect the installed CLI with `herdr agent` or `herdr pane`. Do not run bare `herdr`, because it may launch or attach the TUI.
