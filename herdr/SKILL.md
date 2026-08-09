---
name: herdr
description: Delegate work to coding agents in sibling Herdr panes. Use only when the user explicitly mentions Herdr or asks to use Herdr to delegate, inspect, prompt, or coordinate another agent. Requires HERDR_ENV=1.
---

# Herdr

Use the existing `herdr` CLI for pane and agent operations. Do not create a workspace, worktree, or pane implicitly.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

Resolve pane and workspace IDs from Herdr JSON responses. Do not guess IDs. Create or remove a worktree workspace only when the user explicitly requests it; use `herdr worktree create` and `herdr worktree remove`.

## Async delegation

Normal delegation is fire-and-forget. Do not use `--wait`. Send the task to an existing agent, then inspect its state and terminal output on a later turn with `herdr agent get` and `herdr agent read`.

Use the thin wrappers for the direct-parent result flow:

```bash
herdr/scripts/parent-delegate-async.sh <agent-or-pane> "<prompt>"
herdr/scripts/child-return-result.sh <direct-parent-pane> <completed|blocked> "<body>"
```

The parent wrapper adds the current `$HERDR_PANE_ID` to the child prompt. The child wrapper returns one status and free-form body to that pane. Each delegation edge has exactly one direct parent; see [Async delegation](references/async-delegation.md) for multi-stage, parallel, state, and worktree rules.

The wrappers validate their arguments and environment, call only the existing `herdr agent prompt` command, and propagate its result. They do not wait, retry, queue, persist state, or create Herdr resources.

If a return to a working parent exposes an agent-kind-specific problem, stop and record the reproduction. Do not add waiting or queueing to the wrappers.

## Pane operations

Inspect the current workspace before any explicitly requested pane operation:

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr pane get <pane-id>
```

When starting an agent, use an existing interactive pane and a responsibility-based name. Read the returned pane and agent IDs from JSON, then prompt it without `--wait`.

## Rules

- Use Herdr only when explicitly requested.
- Keep shared work in the current workspace and worktree.
- Use an explicit Herdr worktree workspace for independent branches.
- Do not close panes, kill agents, stop the Herdr server, or manage raw Git worktrees unless explicitly requested.
