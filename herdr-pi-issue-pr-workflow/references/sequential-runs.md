# Sequential Runs

A multi-PR Issue is completed by sequential runs
([Kickoff gate](../SKILL.md#kickoff-gate)), and a later run can keep the
previous run's role panes instead of building a new team. This file fixes when
and how; [Start the team](../SKILL.md#start-the-team) and
[Completion](../SKILL.md#completion) keep the pane rules.

The decision uses the current conversation only: the panes are the ones this
orchestrator started for the roles in an earlier run of the same Issue, and
nothing about them is written to disk. A pane is never reused because of its
label, its agent name, or an entry in the approved team record.

## Scope

Reuse applies to a run that follows a completed run of the same Issue in the
same Herdr workspace and worktree. A run whose predecessor stopped before
[Completion](../SKILL.md#completion) builds every pane as
[Start the team](../SKILL.md#start-the-team) describes, and the stopped run's
panes stay open for inspection. A run with no memory of those panes, such as a
new orchestrator session, has no reuse candidates either.

## Reuse conditions

A joining role reuses its previous pane only when every condition holds:

| Condition | Check |
| --- | --- |
| Same workspace and worktree | The pane is in the current Herdr workspace and worktree, as the previous run's delegation was. |
| The pane is this orchestrator's role pane | The pane is one this orchestrator started for that role in an earlier run of this Issue and named in this conversation. A pane that only matches by label or agent name is a different pane. |
| The pane is idle | `herdr agent get <pane-id>` reports `agent_status: idle`. |
| The effective specification matches | A `herdr agent read <pane-id> --source visible` footer shows this run's settled provider, model, and thinking for the role. Startup argv and the approved team record are not evidence of the running values. |

When a condition fails or cannot be checked, the role needs a new pane, and the
old pane stays open. There is no probing of a pane this conversation cannot
name, no repair of a mismatched running agent, and no fallback to a recorded
team.

## Compact a reused pane

A reused pane carries the conversation of its earlier runs, so compact it
before this run's first task reaches it:

1. Send the command to the pane as a TUI command:

   ```bash
   herdr agent prompt <pane-id> "/compact"
   ```

   This is not a delegation: no result return is expected, so the Herdr skill's
   parent wrapper and its return transport do not apply and the raw
   `herdr agent prompt` call is the transport. The pane is in the same
   workspace, which the reuse conditions already require.

2. Judge the outcome from the pane's output, never with `herdr agent get`. The
   command ends by adding one result line to the pane: on success
   `Compacted from <N> tokens`, on failure `Compaction failed: <reason>`.
   `herdr agent get` reports `agent_status: idle` throughout the compaction,
   so the status is never a completion signal. A result line the pane already
   showed before the command is not its outcome: a reused pane can still show
   an earlier compaction's line.

3. Base the judgment on a read taken before the command: re-read the pane in
   short bounded steps until it shows a result line that read did not have, and
   send the next task only then. Never send a task, a return, or any other
   command while the compaction is running, and do not hold the orchestrator
   pane with long `sleep`-based polling
   ([Async delegation](../../herdr/SKILL.md#async-delegation)).

The transient indicator line `Compacting context... (escape to cancel)` shows
while the compaction runs, but never judge the outcome by searching the pane
for it: the pane's own transcript can contain the same phrase for unrelated
reasons. The result line the command adds is the authority.

A compaction that fails, reported by a `Compaction failed: <reason>` line,
fails the reuse: the pane receives no task for this run and a new pane is
built for the role instead. The pane stays open either way.

## Carry the facts in the task text

Compaction is not a handoff: it shrinks the pane's own conversation and carries
nothing this run decided. Every fact the task depends on goes into the task
body, whether or not the pane was compacted:

- this run's target PR position, work branch, and base branch state;
- the accepted premises, non-goals, and decisions the previous run's contract
  carried;
- the differences from the previous run, such as a changed composition or a new
  verification requirement.

The [Delegation contract](../SKILL.md#delegation-contract) rule stands: a shared
worktree and a reused pane never imply shared context.

## Panes for a new role

A joining role without a reusable pane has nothing to reuse, and the planner
cannot move an existing pane into a planned cell
([pane layout](../../herdr/references/pane-layout.md#exceptions-to-the-skills-pane-rules)):

- no new role (every joining role is reused): create no pane, and do not call
  the planner, which rejects `--count 0` because its minimum count is 2;
- one new role: split it from the orchestrator pane with the Herdr skill's
  single-pane rules
  ([When the requested agent is absent](../../herdr/SKILL.md#when-the-requested-agent-is-absent));
- two or more new roles:
  `herdr/scripts/pane-layout.sh apply --count <new panes>` with the new panes
  only, never the whole team.

Reused panes keep the name and label they already carry; only new panes are
named and labelled. A role that leaves the team, such as `pr-fix` moving back to
`impl` or a run without a `ui-tester`, does not lose its pane: a pane that
received a delegation stays open, and only a `ui-tester` pane this run created
and never delegated to is closed at [Completion](../SKILL.md#completion).

## Relationship to the approved team record

The [approved team record](../SKILL.md#approved-team-record) and pane reuse are
separate decisions. The record settles the team specification, so a kickoff can
skip the approval wait; pane reuse settles which panes this run runs that team
in, from the conditions above. A record says nothing about panes and never makes
one a reuse candidate, and a reuse candidate never skips an approval the record
did not settle. Both apply in the same run: the record skips the approval, then
[Start the team](../SKILL.md#start-the-team) checks the panes.
