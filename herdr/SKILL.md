---
name: herdr
description: Delegate work to coding agents in sibling Herdr panes. Use when the user explicitly mentions Herdr or asks to delegate, inspect, prompt, or coordinate another agent in a separate pane, including requests using the Japanese term "別ペイン" without mentioning Herdr. Requires HERDR_ENV=1.
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
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
herdr/scripts/child-return-result.sh <direct-parent-pane> <completed|blocked> "<body>"
```

Before calling the parent wrapper, resolve the target from `herdr pane list --workspace "$HERDR_WORKSPACE_ID"`. Pass the returned pane ID, never an agent name. If the requested agent is absent, start it in the current workspace as described in [Pane operations](#pane-operations), then use its returned pane ID.

The parent wrapper verifies that both panes belong to `$HERDR_WORKSPACE_ID` and adds the current `$HERDR_PANE_ID` plus the absolute child-wrapper path to the prompt. The child wrapper returns one status and free-form body to that pane. Each delegation edge has exactly one direct parent; see [Async delegation](references/async-delegation.md) for multi-stage, parallel, state, and worktree rules.

The wrappers validate their arguments and environment, call only the existing `herdr agent prompt` command, and propagate its result. They do not wait, retry, queue, persist state, or create Herdr resources.

If a return to a working parent exposes an agent-kind-specific problem, stop and record the reproduction. Do not add waiting or queueing to the wrappers.

## Pane operations

Inspect the current workspace before any explicitly requested pane operation:

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr pane get <pane-id>
```

When starting an agent, use an existing interactive pane in `$HERDR_WORKSPACE_ID` and a responsibility-based name. If none is available, split from `$HERDR_PANE_ID` without changing focus. Read the returned pane and agent IDs from JSON, then prompt the pane ID without `--wait`.

After starting the agent, set the pane label to the same responsibility-based name with `herdr pane rename <pane-id> <name>`, then verify `herdr pane get <pane-id>` returns that `label`. The agent name and pane label are separate; without a manual pane label, `show_agent_labels_on_pane_borders = true` displays the detected agent kind, such as `codex`.

## Rules

- Treat an explicit request involving another or separate pane, including "別ペイン", as a request to use Herdr even when Herdr is not named.
- Keep shared work in the current workspace and worktree.
- Use an explicit Herdr worktree workspace for independent branches.
- Do not close panes, kill agents, stop the Herdr server, or manage raw Git worktrees unless explicitly requested.
