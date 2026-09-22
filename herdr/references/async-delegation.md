# Async delegation

This reference defines the small protocol used by the two Herdr helper scripts. The scripts are the authoritative source for argument counts, accepted status values, pane-ID syntax, environment checks, and process exit behavior. Decision rules for resolving a delegation target, for branching when the requested agent is absent, and for stopping live in [`herdr/SKILL.md`](../SKILL.md); this reference does not duplicate them.

## Parent to child

The parent must know its current pane ID in `$HERDR_PANE_ID`. Resolve the child pane ID before delegation as defined in [`herdr/SKILL.md`](../SKILL.md) (resolve the delegation target); this reference fixes only what the wrapper does once it is called with a resolved pane ID:

```bash
herdr/scripts/parent-delegate-async.sh <child-pane> "<prompt>"
```

The parent wrapper validates its arguments, classifies the edge from its own workspace to the child pane (see [Workspace and worktree ownership](#workspace-and-worktree-ownership)), and then sends one `herdr agent prompt` call to the child without waiting. It appends the current pane ID with its display name and an absolute path to the child helper to the prompt:

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

The child does not discover or infer a parent. It uses only the pane ID included in its delegation prompt. The parent wrapper does not accept a caller-supplied return destination. The child helper sends the return to that direct parent pane with one raw `herdr agent prompt` call.

The return path uses the same rules as the delegation path, in the reverse direction. The child helper classifies the edge from `$HERDR_WORKSPACE_ID` to the direct parent pane before its prompt call, so a return the rules do not allow writes nothing to the target pane.

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

The return is also the wake-up: it arrives as an injected prompt, and an idle parent processes it as the next turn. While the parent is executing tool calls, Pi queues that prompt as steering and delivers it only after the current assistant turn finishes those calls, so a long foreground command — such as a `sleep`-based poll — delays every return until it ends, its tool timeout fires, or a human aborts it. Await returns without blocking the pane: end the turn, or keep foreground commands short.

The wrappers expose distinct failure observations. For `parent-delegate-async.sh`, invalid arguments, a missing `HERDR_ENV=1`, a missing `herdr` executable, or a scope reject of the child pane occurs before the prompt call, so nothing is delivered to the child. For `child-return-result.sh`, invalid arguments, a missing `HERDR_ENV=1`, a missing `herdr` executable, or a scope reject of the direct parent pane occurs before its prompt call, so nothing is delivered to the direct parent. Exit 2 is a usage error, exit 1 is a validation error, and exit 3 is a scope reject with `scope-reject: <reason>` on stderr.

An observed nonzero exit from a wrapper's `herdr agent prompt` call is a transport failure. The parent helper propagates that observed nonzero exit, and delivery to the child is unconfirmed. The child helper likewise propagates an observed nonzero exit, and delivery to the direct parent is unconfirmed.

An unknown outcome is distinct from an observed nonzero exit. Do not infer either helper's exit status or delivery success/failure to its destination from an unknown outcome. The wrappers do not resend; classification and recovery decisions are governed by [`herdr/SKILL.md`](../SKILL.md). A prompt submission is not proof that the child completed.

## Workspace and worktree ownership

Agents that edit the same deliverable share the current Herdr workspace and worktree. Delegation does not require that: an edge may cross a workspace boundary when server-side state or a recorded grant allows it. Both wrappers classify the edge with `scripts/lib/scope.sh` immediately before they write, using only the two workspace IDs and live `herdr workspace list` state. Allowed edges:

| Edge | Condition |
| --- | --- |
| `same-workspace` | source and target are the same workspace |
| `worktree-team` | both workspaces report the same `worktree.repo_root` and exactly one of them is a linked worktree, so a parent checkout can reach its linked worktree and that linked worktree can return |
| `granted` | an unexpired record in the delegation-scope file covers the workspace pair or the target repository |

Two linked worktrees of one repository (siblings), two checkouts of one repository, unrelated repositories, and a workspace without worktree information stay rejected. A grant holds in both directions. The caller's own pane is always rejected, in the same workspace and across workspaces alike.

Every other outcome is a reject, including the outcomes the classifier cannot decide:

| Reason | Meaning |
| --- | --- |
| `self-pane` | the target pane is the caller's own pane |
| `workspace-list-failed` | `herdr workspace list` failed |
| `workspace-list-invalid-json` | its payload is not usable state |
| `unknown-workspace` | the source or target workspace is absent from that state |
| `repo-mismatch` | the two workspaces share no derivable repository relation |
| `sibling-worktrees` | same repository, both linked worktrees |
| `duplicate-checkout` | same repository, neither is a linked worktree |
| `grant-expired` | a covering grant record exists but has expired |
| `scope-file-invalid` | the scope file exists but cannot be parsed |
| `scope-file-unavailable` | neither `HERDR_SCOPE_FILE`, `XDG_CONFIG_HOME`, nor `HOME` resolves a path |
| `classify-failed` | the classifier produced no verdict |

A reject exits 3 with `scope-reject: <reason>` on stderr before any prompt call, so the target pane receives nothing and the reject stays distinguishable from a transport failure. An observed nonzero exit from the wrapper's own `herdr agent prompt` call is a transport failure, not a scope reject. A malformed scope file fails closed instead of falling back to the shape rules.

Grants are human records for edges the shape rules do not derive. `--by` is required, and each record keeps the id, the source workspace, the target workspace or target repository root, the task reference, the granting name, and the creation and expiry timestamps (or never, without `--ttl`):

```bash
herdr/scripts/scope-grant.sh grant --source <workspace> --target <workspace> --by <name> [--task <ref>] [--ttl <seconds>]
herdr/scripts/scope-grant.sh grant --source <workspace> --target-repo <path> --by <name> [--task <ref>] [--ttl <seconds>]
herdr/scripts/scope-grant.sh list
herdr/scripts/scope-grant.sh revoke <grant-id>
```

The file lives at `${HERDR_SCOPE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/delegation-scope.json}` and is written with mode 0600. `grant` appends one record and prints its id; `list` prints one tab-separated record per grant; `revoke` removes one record by id. A malformed file is reported and never rewritten. Grants are matched by workspace ID, and workspace IDs are server-local while the scope file is shared per user, so a grant also covers a same-ID workspace pair on another Herdr server of that user. Cross-server delegation is out of scope, so treat the file as per-user state rather than per-server state. The file is a record of human intent, not a forgeable capability — an agent process can read and write it directly — so this scope is an operational safeguard, not an enforcement boundary (see [Technical delegation boundary](technical-delegation-boundary.md)).

Do not work around a rejected edge with a raw cross-workspace `herdr agent prompt` or `herdr agent start`. That bypass is the model-compliance dependence rejected by [Technical delegation boundary](technical-delegation-boundary.md): a non-conforming model would succeed where a conforming one stops. Read-only discovery of worktree workspaces stays allowed.

The worktree lifecycle commands remain available, and they never delegate:

```bash
herdr workspace list
herdr worktree create --cwd "$PWD" --branch <branch-name>
```

Pin the source checkout with `--cwd` (or `--workspace`) on `worktree create`, `open`, and `list`. Without it the source follows the client's focused workspace rather than the caller's cwd or `$HERDR_WORKSPACE_ID`, so an unpinned call can act on another repository. When that focused workspace is itself a linked worktree, `worktree create` and `worktree open` fail with `linked_worktree_source`, while `worktree list` resolves the source to that worktree's parent repository instead.

Resolve the real workspace ID from the creation response. Remove only a linked worktree workspace, using the corresponding Herdr command:

```bash
herdr worktree list --cwd "$PWD"
herdr worktree open --cwd "$PWD" --path <worktree-path>
herdr worktree remove --workspace <linked-workspace-id>
```

The helper scripts never create, share, or remove workspaces, worktrees, tabs, or panes. A caller must explicitly establish the workspace topology before delegation; `scripts/worktree-team-start.sh` starts and prompts a team member in an existing worktree pane under the same scope rules, and [Worktree workspace teams](worktree-workspace-teams.md) covers that topology.
