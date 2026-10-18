# Session restore

Rebuild a standing composition ([Operator team roles](operator-team-roles.md))
whose panes died, fell back to a plain shell, or were lost when Herdr was
restarted. The procedure is idempotent: it finds what is already there by label
and creates only the missing tabs, panes, agents, and role documents.

Restore reattaches panes a human owns. It is not a delegation and not a route
around the edge rules: it runs inside a pane of the composition's own workspace
(`HERDR_ENV=1`), it never creates a workspace or a worktree, and it never
prompts across a workspace boundary ([Worktree workspaces](../SKILL.md#worktree-workspaces)).

Pane, tab, and workspace IDs come from Herdr JSON responses as everywhere in
this skill ([Caller pinning](../SKILL.md#caller-pinning)). A label only narrows
the search to the pane this composition expects, and the response confirms it;
a label never authenticates a caller and never selects a delegation target
([Technical delegation boundary](technical-delegation-boundary.md)).

## Inputs

- the label file: the workspace label, one label per role, the tab labels, and
  the optional plugin id and entrypoint ([One label file](operator-team-roles.md#one-label-file));
- one role document per role ([Role documents](operator-team-roles.md#role-documents));
- the standing checkout the role panes work in, and the directory that holds the
  role documents and the records.

## Steps

1. Resolve the workspace by its label in `herdr workspace list` and keep the
   workspace ID. No match, or more than one, stops the restore with a question:
   restore never creates a workspace.
2. Read the live state of that workspace once, with
   `herdr pane list --workspace <workspace-id>` and
   `herdr tab list --workspace <workspace-id>`. Both are read-only and stay
   available under the edge rules.
3. Take the roles in the order the composition states, the request pane first,
   and resolve exactly one pane for each:
   - a pane whose label is the role's label is reused;
   - otherwise a tab whose label is the role's tab label and whose pane carries
     no label supplies that pane;
   - a pane in that tab carrying a different label stops the step: the label is
     the composition's, so a restore asks the user instead of overwriting it;
   - otherwise create the tab with
     `herdr tab create --workspace <workspace-id> --cwd <checkout> --label <tab-label> --no-focus`
     and read `result.root_pane.pane_id`.
   The composition holds one pane per role, so a second pane with one role's
   label stops the step as well: it is someone else's pane.
4. Start the agent only when the pane is a plain interactive shell:

   ```bash
   herdr agent start <name> --kind pi --pane <pane-id> --timeout <timeout-ms> \
     -- --provider <provider> --model <model> --thinking <level>
   ```

   A pane that already runs this agent kind is skipped, not restarted. A pane
   running another agent kind is handed back to the user, never taken over.
   Wait for readiness before prompting, for example with
   `herdr agent wait <pane-id> --until idle --until done --until blocked --timeout <timeout-ms>`.
5. Set the label and read it back: `herdr pane rename <pane-id> <role-label>`,
   then `herdr pane get <pane-id>` ([Pane operations](../SKILL.md#pane-operations)).
6. Send the role document with
   `herdr agent prompt <pane-id> "<role document body>"`, expanded from the
   file into one argument and refused when the file is empty. This is a
   bootstrap, not a task: it expects no return, so it does not use the async
   delegation wrapper ([Async delegation](async-delegation.md)), whose result
   transport and edge classification exist for task delegation. Two rules keep
   the step idempotent: never prompt the pane the restore itself runs in — that
   pane re-reads its own document — and never re-send a document to a pane that
   already received it unless the user asks for a re-send.
7. Restore the optional plugin pane last, beside the request pane:

   ```bash
   herdr plugin pane open --plugin <plugin-id> --entrypoint <entrypoint> \
     --placement split --target-pane <orchestrator-pane-id> --direction right
   ```

   Reuse the pane whose label is the panel label when it is already there, and
   read the opened pane from `result.pane.pane_id`; a response without it is
   confirmed by comparing `herdr pane list` before and after. A plugin that is
   not linked or not built is skipped with one warning and the rest of the
   restore stays successful; `herdr plugin list` distinguishes the two. Open the
   panel only after the request pane exists, because the split needs it as its
   target.

A run of the procedure is a success when every step above either completed or
was skipped by one of its stated rules. A skipped plugin pane, a reused pane,
and a start that found the agent already running are not failures.

## Dry run and diagnostics

- A dry run prints the write commands instead of running them, so the resolved
  workspace, panes, tabs, and arguments can be checked first.
- A failure names the role and the step, for example `ERROR: [scribe] 4/7 ...`,
  so the first broken pane is visible in one line.
- A start that fails while the pane already reports the agent is a warning, not
  a failure: the pane is usable and the remaining steps continue.
- Check the state after a stop with `herdr workspace list`,
  `herdr pane list --workspace <workspace-id>`, `herdr pane get <pane-id>`,
  `herdr tab list --workspace <workspace-id>`, and
  `herdr agent get <pane-id>`. A role document that did not arrive is visible in
  `herdr agent read <pane-id> --source visible --lines 30`.

## What is not part of the procedure

- Creating or closing a workspace or a worktree, and stopping the Herdr server:
  each one needs an explicit user request ([Rules](../SKILL.md#rules)).
- Prompting across a workspace boundary: a team in another workspace keeps to
  the worktree and grant edges ([Worktree workspace teams](worktree-workspace-teams.md)).
- Taking over a pane that runs another agent kind, and renaming a pane that
  already carries another label.

## Alignment with a per-task team

The same steps rebuild a team inside a worktree workspace when the user starts
that team directly: the workspace already exists, its root pane comes from the
`herdr worktree create` or `herdr worktree open` response, and the additional
role panes are split from it ([Topology creation](worktree-workspace-teams.md#topology-creation)).
What differs is the payload: a per-task team receives task text that carries the
worktree environment block, not a standing role document
([Orchestrator-first](worktree-workspace-teams.md#orchestrator-first)). When the
user drives the team, the panes are prepared the same way and the user runs the
commands ([Fallback: user-started teams](worktree-workspace-teams.md#fallback-user-started-teams)).
A closed worktree workspace is reopened before it is restored or removed
([Cleanup](worktree-workspace-teams.md#cleanup)).
