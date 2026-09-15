# Worktree workspace teams

Procedure for running a team inside a Herdr worktree workspace. The parent
workspace normally starts and coordinates that team itself: the
`worktree-team` edge (parent checkout to its linked worktree, and back) is
derived from `herdr workspace list` state and is allowed by the delegation
scope rules. Starting the team by hand remains the fallback for the cases the
rules do not cover and for users who want to drive the team directly.

The scope rules are operational safeguards, not a permission boundary
([`async-delegation.md`](async-delegation.md#workspace-and-worktree-ownership),
[Technical delegation boundary](technical-delegation-boundary.md)).

## When to use it

The user asks for a task-per-worktree topology with one Herdr worktree
workspace per task, its own branch, and its own roles.

Do not propose this topology for ordinary work on an independent branch.
Shared work stays in the current workspace and worktree
([`herdr/SKILL.md`](../SKILL.md)).

## Topology creation

Create the worktree workspace from the repository's parent workspace when the
user explicitly requests it:

```bash
herdr worktree create --cwd "$PWD" --branch <branch> [--no-focus]
```

`--cwd` pins the source checkout; without it the call follows the client's
focused workspace (see [Workspace and worktree ownership](async-delegation.md#workspace-and-worktree-ownership)).
Read the linked workspace ID and its root pane from the creation response:

```text
result.workspace.workspace_id        linked workspace ID
result.worktree.open_workspace_id    the same linked workspace ID
result.root_pane.pane_id             root pane, at an interactive shell
```

Do not guess these IDs from display order, labels, or a later `worktree list`.

## Starting and coordinating the team

The parent may start and prompt the team when the edge from the parent
workspace to the worktree workspace is allowed:

- `worktree-team` — the parent workspace and the worktree workspace report the
  same `worktree.repo_root` and exactly one of them is a linked worktree. This
  is the normal case, because `herdr worktree create` links the new workspace
  to the checkout it was pinned to. It covers both the delegation into the
  worktree and the return to the parent.
- `granted` — for a pair the shape rules do not derive, a human records the
  edge first. `--target-repo` covers every workspace of that repository, so it
  does not have to be repeated per worktree:

```bash
herdr/scripts/scope-grant.sh grant --source <parent-workspace> --target-repo <repo-root> --by <name> --task <issue-or-pr> [--ttl <seconds>]
```

Sibling worktrees of one repository, a second checkout of the repository, and
cross-server targets stay rejected. A rejected edge exits 3 with
`scope-reject: <reason>` and writes nothing; report it instead of retrying
around it.

Prepare one pane per role and one task file per role before starting anything.
The worktree root pane comes from the creation response, so split it for every
additional role and read the new pane ID from the split response:

```bash
herdr pane split --pane <root-pane-id> --direction right --cwd <worktree-path> --no-focus
```

Write the task body to a file first and confirm it is non-empty. `herdr agent
prompt` rejects empty text with `empty_agent_prompt`, and
`$(cat <task-file>)` on a missing file expands to exactly that empty string:

```bash
cat > <task-file> <<'TASK'
Goal: <what this role must deliver>
Acceptance: <how the result is verified>
Reporting: return the final status and body to the direct parent pane; comment on the pull request or issue when one exists
TASK
test -s <task-file>
```

Start the team member and delegate the task body in one command, from the
parent workspace:

```bash
herdr/scripts/worktree-team-start.sh <pane-id> <role> --provider <provider> --model <model> --thinking <level> <task-file>
```

The script classifies the edge before anything else, then runs the sequence
that a manual start used to spell out: `herdr agent start <role> --kind pi
--pane <pane-id> --timeout 60000 -- --provider <provider> --model <model>
--thinking <level>`, a bounded wait of up to 60 seconds for the agent to
become interactive, `herdr pane rename <pane-id> <role>`, and finally the task
body through `parent-delegate-async.sh`, which appends the direct-parent
return instruction. A failed start, readiness wait, or rename stops the
command before the prompt, and the scope reject exits 3. A failed prompt is a
transport failure: the agent stays started and renamed in its pane, so
inspect that pane (`herdr agent get`, `herdr agent read`) instead of starting
a second agent next to it. The agent flags are
single-line tokens passed as discrete arguments: `herdr agent start` rejects a
multi-line AGENT_ARG before anything starts:

```text
{"error":{"code":"invalid_agent_argument","message":"agent arguments cannot be encoded safely for the target shell"},"id":"cli:agent:start"}
```

Upstream declined file or stdin input for `herdr agent prompt`
(herdrdev/herdr#3367, closed as not planned on 2026-08-29), so the body must
arrive as one shell argument; the script expands it from the task file at the
prompt call and keeps the agent flags in the separate start call.

### Fallback: user-started teams

When the edge is not allowed, when the user prefers to drive the team, or when
the parent must not write into the worktree workspace, hand the user the
commands above and let the user run them. The user then also owns progress:
the parent collects results from the pull request or issue through the `gh`
skill instead of receiving wrapper returns.

For a self-contained team whose members do not return to the parent, report
progress, a waiting decision, and completion with one fixed template, posted
as a comment on the task's pull request, or on the issue while no pull request
exists:

```text
status: progress | decision-wait | completed
role: <role or agent name>
body: <what changed, or the question, in one to three lines>
```

A `decision-wait` report is a question for the parent or the user; the answer
arrives as a reply on the same comment thread, and the team continues when it
reads that reply. The parent does not send follow-up prompts to a fallback
team. Do not mix the two modes in one team: either the parent starts and
coordinates the team through the wrappers, or the user starts it and it
reports through GitHub comments.

Within the worktree workspace, the team's internal delegation is ordinary
same-workspace delegation and the wrappers work between its panes.

## Cleanup

Remove the worktree workspace by its live workspace ID:

```bash
herdr worktree remove --workspace <linked-workspace-id>
```

If the workspace was closed, `herdr worktree list --cwd "$PWD"` omits
`open_workspace_id` for it, and removal by the old workspace ID fails with
`workspace_not_found`. Reopen the worktree first, then remove it with the
workspace ID from the open response, which is a new ID:

```bash
herdr worktree open --cwd "$PWD" --path <worktree-path>
herdr worktree remove --workspace <reopened-workspace-id>
```

The linked workspace is not the only workspace involved. When the repository
has no open workspace yet, `herdr worktree create` (and `worktree open`) also
opens one for the source checkout: a single shell pane at the checkout path.
The creation response names only the linked workspace, and `worktree remove`
does not close the source workspace. If the source workspace was opened for
this task and the user no longer needs it, close it after the linked workspace
has been removed:

```bash
herdr workspace list
herdr workspace close <source-workspace-id>
```

Identify it in `herdr workspace list` as the entry whose
`worktree.is_linked_worktree` is `false` and whose `worktree.checkout_path` is
the source checkout. If the repository already had an open workspace, `create`
reuses it, so there is nothing to close and an existing workspace in the same
repository is not this task's to close. Closing the source workspace while a
linked worktree workspace is still open fails with
`workspace_group_close_required`; `herdr workspace close
<source-workspace-id> --group` closes the source and its linked worktree
workspaces together but leaves their Git worktree checkouts on disk, so use
the two-step order above.

Removing by path is an upstream dependency: herdr 0.9.0 accepts only
`--workspace` on `herdr worktree remove`, and `--path` fails with
`unknown option: --path`. See the upstream dependency section of
[Technical delegation boundary](technical-delegation-boundary.md).

## Prohibitions

- Do not bypass a rejected edge with a raw cross-workspace
  `herdr agent prompt` or `herdr agent start`. That is exactly the
  model-compliance dependence the boundary document rejects: a non-conforming
  model would succeed where a conforming one stops.
- Do not hand a user-started fallback team's work back to the wrapper path by
  targeting its workspace directly, and do not prompt a fallback team from the
  parent.
- Do not close or remove the workspace while its team is working.
- Read-only discovery stays allowed: `herdr workspace list`,
  `herdr worktree list --cwd "$PWD"`, and
  `herdr pane list --workspace <linked-workspace-id>`.
