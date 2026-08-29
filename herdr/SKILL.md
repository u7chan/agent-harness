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

## Caller pinning

Delegation requires both `$HERDR_WORKSPACE_ID` and `$HERDR_PANE_ID`. If either is empty, or the `$HERDR_PANE_ID` workspace prefix does not match `$HERDR_WORKSPACE_ID`, fail closed: stop instead of falling back to argument-less commands. Take IDs only from Herdr JSON responses; never infer them from display order, labels, model names, or UI focus.

## Resolve the delegation target

This section is authoritative for candidate resolution, branching, and stop conditions. A request for "another pane" (別ペイン) means another pane in the current workspace, not a physical neighbor. These rules are an operational safeguard for skill-compliant agents; they do not add a technical enforcement boundary.

The invariant and responsibility split required for a hard boundary are defined in [Technical delegation boundary](references/technical-delegation-boundary.md). Do not infer a stronger guarantee from this skill or from the wrappers.

### Candidate set

Build candidates only from the response of:

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

Exclude `$HERDR_PANE_ID` itself and every pane whose `workspace_id` differs from `$HERDR_WORKSPACE_ID`. Global `workspace list`, argument-less `pane list` and `agent list`, `pane layout`, and UI focus are read-only investigation aids; never select a delegation candidate from them.

Select a candidate only when exactly one pane satisfies the explicitly stated conditions. Zero or multiple matches, unknown pane metadata, and JSON or API errors branch the same way: do not infer an alternative candidate, and move on to [When the requested agent is absent](#when-the-requested-agent-is-absent) or ask the user.

### Spatial neighbors

For 左, 右, 上, 下, ask exactly the requested direction:

```bash
herdr pane neighbor \
  --pane "$HERDR_PANE_ID" \
  --direction <left|right|up|down>
```

For a direction-less "隣" (next to), query all four directions from the same origin, deduplicate the returned `neighbor_pane_id` values, and use them only when exactly one satisfies the explicit conditions; if several remain, ask which direction or pane. Each direction returns at most one neighbor; Herdr resolves it by distance, overlap, and layout order.

Read only `neighbor_pane_id` as the target. When the field is omitted or null there is no neighbor; never fall back to the origin `pane_id`. Do not use `--current`, a neighbor call without `--pane`, or an argument-less `pane layout` to resolve a target. A nonzero exit, malformed JSON, or a workspace mismatch is a stop condition: do not fall back to a global search.

If the directional neighbor is occupied and does not match the request, do not overwrite it and do not switch direction silently; ask the user. An empty interactive-shell neighbor may run the requested agent.

## When the requested agent is absent

Branch without widening the search beyond the current workspace:

- Non-spatial request: prefer an existing empty interactive shell in `$HERDR_WORKSPACE_ID`; do not split while one is available.
- Spatial request: use the resolved neighbor when it is an empty interactive shell. If there is no neighbor and the request named no direction, split explicitly from `$HERDR_PANE_ID` to create the adjacent pane. When the requested direction cannot be created safely, do not guess another direction; ask the user.
- If no pane in `$HERDR_WORKSPACE_ID` is available, split explicitly from `$HERDR_PANE_ID`.

Read every split and agent-start ID from the JSON responses. After starting, verify interactive readiness plus the user-specified provider, model, and thinking settings before delegating; an unknown value is not a match. Start the agent as described in [Pane operations](#pane-operations). Do not equate "requested agent absent" with "no available pane": splitting is not the default response to a missing agent.

## Async delegation

Normal delegation is fire-and-forget. Do not use `--wait`. Send the task to an existing agent, then inspect its state and terminal output on a later turn with `herdr agent get` and `herdr agent read`.

Use the thin wrappers for the direct-parent result flow:

```bash
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
herdr/scripts/child-return-result.sh <direct-parent-pane> <completed|blocked> "<body>"
```

The parent wrapper is the mandatory route for a new parent-to-child delegation and for any additional task that expects a result return. Resolve the target as defined in [Resolve the delegation target](#resolve-the-delegation-target) and pass the returned pane ID, never an agent name. Treat the wrapper as part of the candidate: if it is unavailable, was not executed, exits nonzero, or you can predict that it would reject a workspace mismatch, the candidate is invalid — re-resolve within `$HERDR_WORKSPACE_ID` or report blocked. Do not rebuild the wrapper prompt by hand and do not fall back to raw `herdr agent prompt`, another wrapper, or `pane send-text`. After a transport failure or an unknown result, do not resend without confirming state first, and keep a scope reject distinct from a transport failure. The child wrapper's own raw `herdr agent prompt` call is its fixed return transport, not a license for raw parent-to-child prompts. Even when the user explicitly names a pane in another workspace, direct-parent delegation is unsupported: stop there.

The parent wrapper verifies that both panes belong to `$HERDR_WORKSPACE_ID` and adds the current `$HERDR_PANE_ID` with its resolved display name plus the absolute child-wrapper path to the prompt. The child wrapper returns one status and free-form body to that pane. Each delegation edge has exactly one direct parent; see [Async delegation](references/async-delegation.md) for the wrapper protocol, display names, failure handling, and worktree rules.

The wrappers validate their arguments and environment, call the existing `herdr agent prompt` command, and propagate its result. The parent wrapper additionally calls read-only `herdr pane get` once to resolve the parent display name; if that lookup fails, the prompt keeps the bare pane ID. They do not wait, retry, queue, persist state, or create Herdr resources.

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

- Keep shared work in the current workspace and worktree.
- Use an explicit Herdr worktree workspace for independent branches.
- Do not close panes, kill agents, stop the Herdr server, or manage raw Git worktrees unless explicitly requested.
