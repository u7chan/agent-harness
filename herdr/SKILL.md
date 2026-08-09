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

Name agents by responsibility, independently of `kind`. Use `<role>[-<scope>]`, adding a short suffix when the name is already in use.

Examples:

```text
impl
review
verify-api
```

### 3. Send the task

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

Keep delegation fire-and-forget. Do not pass `--wait` or block while the delegate works. Return control to the user immediately, then follow the [delegation contract](#delegation-contract) on a later turn.

Compose every prompt according to [Skill loading](#skill-loading) and [Completion report](#completion-report).

### 4. Read the result

```bash
herdr agent get <name-or-pane-id>
herdr agent read <name-or-pane-id> \
  --source recent-unwrapped \
  --lines 200
```

Read the state with `agent get` before reading output. `agent read` returns a terminal snapshot, not a structured final answer. Interpret it only as defined in [Async flow](#async-flow).

If prompt, get, or read fails, inspect `agent get` and `agent read` before retrying. Do not blindly resend a prompt that may already have been delivered.

## Send to an existing agent

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

Follow the asynchronous behavior in [Send the task](#3-send-the-task). On a later turn, inspect the state and terminal snapshot:

```bash
herdr agent get <name-or-pane-id>
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

## Delegation contract

This section defines the protocol for every task delegated through this skill. The parent carries the protocol in the prompt, so it applies even when the delegate does not load this skill.

### Skill loading

- The Herdr skill is not auto-loaded. A delegate reads `herdr/SKILL.md` only when the parent explicitly requires it in the delegation prompt.
- When the delegate must perform Herdr operations, such as delegating again, the parent must tell it to read and follow the Herdr skill.
- Otherwise, the delegate works on the task without assuming Herdr is available. The completion-report protocol still applies because the parent includes it in the prompt.

### Completion report

The parent must include the following response protocol in every delegation prompt. The delegate puts one compact report block at the end of its final response, uses the exact boundary markers, and writes nothing after the closing marker:

```text
HERDR_RESULT_BEGIN
status: <completed|blocked>
summary:
- <work performed and conclusion>
changed_files:
- <changed or created path, or none>
verification:
- <check and result, or not run with reason>
unresolved:
- <required input, remaining issue, or none>
HERDR_RESULT_END
```

The report block must fit within 100 terminal lines. `blocked` means the delegate cannot continue without parent input; `unresolved` must state exactly what is missing and what response is needed. The delegate performs no additional Herdr return operation.

### Async flow

Submit prompts without `--wait`. Agent kinds differ in wait and interruption behavior, and a settled task may be reported as `idle`, `done`, or `blocked` rather than reaching one universal state. On a later turn, use `agent get`, then handle its state as follows:

| State | Parent action |
|---|---|
| `working` | Return control and inspect again on a later turn. Do not read the snapshot as a result. |
| `idle` or `done` | Read the snapshot and accept only its last complete `HERDR_RESULT_BEGIN` / `HERDR_RESULT_END` block. Never report completion without a complete block whose status is `completed`. |
| `blocked` | Read the snapshot and treat the task as blocked. Use a complete report block when present; otherwise use the snapshot only to diagnose the missing input. Ask the user for that input before resuming. |
| `unknown` | Do not classify the task as completed. Inspect the pane and snapshot; if no resumable agent can be identified, report the unknown state and ask before retrying or delegating again. |

If the opening marker was truncated, read more lines and retry extraction. An incomplete or unmarked snapshot is not a completion report. For `idle` or `done` without a complete report, prompt the same agent to return only the missing report; do not rerun the task. To resume `blocked`, send the required input to the same agent in a new prompt that requests a fresh report block. Send both prompts without `--wait`, return control, and retrieve their results on a later turn.

## Rules

- Use Herdr only when explicitly requested.
- Keep delegation in the current workspace, tab, and working directory unless the user requests otherwise.
- Use `--no-focus` for background work.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on UI focus.
- Parse IDs and state from JSON responses. Do not infer them from pane order.
- Do not create a workspace, tab, or worktree unless explicitly requested.
- Do not close panes, kill agents, or stop the Herdr server unless explicitly requested.
- When command syntax is unclear, inspect the installed CLI with `herdr agent` or `herdr pane`. Do not run bare `herdr`, because it may launch or attach the TUI.
