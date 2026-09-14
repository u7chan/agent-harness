# Worktree workspace teams

Interim procedure for running a team self-contained in a Herdr worktree
workspace while Herdr has no authorized delegation scope. Normal delegation is
same-workspace only ([`async-delegation.md`](async-delegation.md)), so a team
inside a worktree workspace is started and driven by the user, not by a
delegating agent. This procedure keeps that boundary intact instead of
bypassing it, and adds no runtime, state file, or queue.

## When to use it

The user asks for a task-per-worktree topology whose team runs self-contained:
one Herdr worktree workspace per task, its own branch, and its own roles that
finish the task without prompts from the parent workspace.

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

## Team startup

Startup is a user action. A delegating agent must not write into the worktree
workspace: `herdr agent start` and `herdr agent prompt` are write-capable
operations, and normal delegation has no cross-workspace exception. When the
user asks for this topology, hand the user the commands below and let the user
run them.

Start each role in a pane of the linked workspace. `herdr agent start` rejects
a multi-line AGENT_ARG, so the agent flags go in the start call and the task
body goes in a separate prompt call:

```bash
herdr agent start <name> --kind pi --pane <pane-id> -- --provider <provider> --model <model> --thinking <level>
herdr agent prompt <target> "$(cat <task-file>)"
```

Measured on herdr 0.9.0, a multi-line AGENT_ARG fails before anything starts:

```text
{"error":{"code":"invalid_agent_argument","message":"agent arguments cannot be encoded safely for the target shell"},"id":"cli:agent:start"}
```

The two-step form is canonical. Upstream declined file or stdin input for
`herdr agent prompt` (herdrdev/herdr#3367, closed as not planned on
2026-08-29), so the body must arrive as one shell argument; expanding it at
the prompt call from a task file keeps quoting simple. Do not put the task body
in the start arguments, and do not split it into several prompt calls.

After the user has started the team, its internal delegation is ordinary
same-workspace delegation: the wrappers work between panes of the worktree
workspace. Only the edge to the parent workspace is missing, and it stays
missing by design.

## Self-containment contract

Once started, the team does not depend on parent prompts. Report progress, a
waiting decision, and completion with one fixed template, posted as a comment
on the task's pull request, or on the issue while no pull request exists:

```text
status: progress | decision-wait | completed
role: <role or agent name>
body: <what changed, or the question, in one to three lines>
```

A `decision-wait` report is a question for the parent or the user; the answer
arrives as a reply on the same comment thread, and the team continues when it
reads that reply. The parent collects results by reading the pull request or
issue through the `gh` skill, never by prompting across workspaces. The team
owns its own progress; the parent does not send follow-up prompts, and the
team does not wait on one.

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

Removing by path is an upstream dependency: herdr 0.9.0 accepts only
`--workspace` on `herdr worktree remove`, and `--path` fails with
`unknown option: --path`. See the upstream dependency section of
[Technical delegation boundary](technical-delegation-boundary.md).

## Prohibitions

- Do not bypass the boundary with a raw cross-workspace `herdr agent prompt`
  or `herdr agent start`. That is exactly the model-compliance dependence the
  boundary document rejects: a non-conforming model would succeed where a
  conforming one stops.
- Do not start or prompt a team in a worktree workspace on your own
  initiative, and do not answer a `decision-wait` by targeting the workspace
  directly.
- Do not close or remove the workspace while its team is working.
- Read-only discovery stays allowed: `herdr workspace list`,
  `herdr worktree list --cwd "$PWD"`, and
  `herdr pane list --workspace <linked-workspace-id>`.
