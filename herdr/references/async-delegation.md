# Async delegation

This reference defines the small protocol used by the two Herdr helper scripts. The scripts are the authoritative source for argument counts, accepted status values, pane-ID syntax, environment checks, and process exit behavior.

## Parent to child

The parent must know its current pane ID in `$HERDR_PANE_ID`. Resolve the child from the current workspace before delegation:

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

Select the child pane ID from that response. Do not pass an agent name or a pane from another workspace. If the requested agent is absent, start it in a pane in `$HERDR_WORKSPACE_ID`, then use the pane ID returned by Herdr:

```bash
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
```

The wrapper rejects child and parent panes outside `$HERDR_WORKSPACE_ID`, then sends one `herdr agent prompt` call without waiting. It appends the current pane ID with its display name and an absolute path to the child helper to the prompt:

```text
Direct parent pane for result return: <pane-id> (<display-name>)
```

The display name is resolved with one read-only `herdr pane get` call and matches the pane border: the manual label first, then the detected agent kind. When the lookup fails or neither field is present, the line keeps the bare pane ID. The helper invocation always receives the raw pane ID. The child can then return its final answer with that exact helper path:

```bash
"<absolute-child-helper-path>" "<direct-parent-pane>" completed "<body>"
```

Use `blocked` when the child cannot continue without a decision or input from the parent:

```bash
"<absolute-child-helper-path>" "<direct-parent-pane>" blocked "<reason and required input>"
```

The body is free-form text and must be passed as one shell argument. Quote it when it contains spaces or newlines. It is delivered to the parent in this form:

```text
status: completed|blocked
body:
<free-form body>
```

The child does not discover or infer a parent. It uses only the pane ID included in its delegation prompt. The parent wrapper does not accept a caller-supplied return destination.

## Display names

The name shown on a pane border resolves as `label ?? agent kind`:

- `herdr pane get <pane-id>` returns the pane JSON. `result.pane.label` is present only when the label was set with `herdr pane rename`; an unset label is omitted from the JSON, not null. `result.pane.agent` is the detected agent kind, such as `pi` or `codex`.
- `herdr pane list --workspace <workspace-id>` carries the same fields for every pane in the workspace.
- `herdr agent get <target>` does not include the label. Use the pane commands to resolve display names.

When a child reports the return destination to the user in its own pane, it should use the display name embedded in its delegation prompt, for example `wG:p1 (bob)`, while passing the raw pane ID to the helper script.

## Direct edges

Each delegation edge carries one direct parent pane:

```text
A -> B -> D
```

D returns to B, and B returns to A after it has classified or summarized D's result. For parallel work, each child returns to the pane of the agent that delegated it:

```text
C -> E
C -> F
```

E and F both return to C. There is no global parent tree, fan-out return destination, attempt identifier, terminal marker, or state file.

## State and failure handling

`parent-delegate-async.sh` and `child-return-result.sh` never wait for an agent to become idle or done. After a prompt is submitted, the parent observes the existing CLI state and terminal output later:

```bash
herdr agent get <agent-or-pane>
herdr agent read <agent-or-pane> --source recent-unwrapped --lines 200
```

An idle or working parent can receive a return through the same existing `agent prompt` operation. The wrappers do not claim that delivery means task completion, and they do not implement a retry or queue when a parent is busy. If a particular agent kind cannot accept a return while working, stop with the reproduction and track that behavior separately.

Invalid arguments, a missing `HERDR_ENV=1`, a missing `herdr` executable, or a failed `herdr agent prompt` are failures of the helper invocation. The helper exits nonzero and leaves retry or recovery decisions to the caller. It does not treat a prompt submission as proof that the child completed.

## Workspace and worktree ownership

Agents that edit the same deliverable share the current Herdr workspace and worktree. A subtree that needs an independent branch must first be placed in an explicitly created Herdr worktree workspace:

```bash
herdr workspace list
herdr worktree create --cwd "$PWD" --branch <branch-name>
```

Resolve the real workspace ID from the creation response. Remove only a linked worktree workspace, using the corresponding Herdr command:

```bash
herdr worktree list --cwd "$PWD"
herdr worktree remove --workspace <linked-workspace-id>
```

The helper scripts never create, share, or remove workspaces, worktrees, tabs, or panes. A caller must explicitly establish the workspace topology before delegation.
