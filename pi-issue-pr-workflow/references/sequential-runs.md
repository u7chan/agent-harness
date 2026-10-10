# Sequential Runs

A multi-PR Issue is completed by sequential runs
([Kickoff gate](../SKILL.md#kickoff-gate)), and a later run can keep the
previous run's role panes instead of building a new team. This file fixes when
and how; [Start the team](../SKILL.md#start-the-team) and
[Completion](../SKILL.md#completion) keep the pane rules.

The decision uses the current conversation only: the panes are the ones this
orchestrator started for the previous run, and nothing about them is written to
disk. A pane is never reused because of its label, its agent name, or an entry
in the approved team record.

## Scope

Reuse applies to a run that follows a completed run of the same Issue in the
same Herdr workspace and worktree. A run whose predecessor stopped before
[Completion](../SKILL.md#completion) builds every pane as
[Start the team](../SKILL.md#start-the-team) describes, and the stopped run's
panes stay open for inspection. A run with no memory of the previous run's
panes, such as a new orchestrator session, has no reuse candidates either.

## Reuse conditions

A joining role reuses its previous pane only when every condition holds:

| Condition | Check |
| --- | --- |
| Same workspace and worktree | The pane is in the current Herdr workspace and worktree, as the previous run's delegation was. |
| The pane is this orchestrator's role pane | The pane is the one this orchestrator started for that role during the previous run and named in this conversation. A pane that only matches by label or agent name is a different pane. |
| The pane is idle | `herdr agent get <pane-id>` reports `agent_status: idle`. |
| The effective specification matches | A `herdr agent read <pane-id> --source visible` footer shows this run's settled provider, model, and thinking for the role. Startup argv and the approved team record are not evidence of the running values. |

When a condition fails or cannot be checked, the role needs a new pane, and the
old pane stays open. There is no probing of a pane this conversation cannot
name, no repair of a mismatched running agent, and no fallback to a recorded
team.

## Compact a reused pane

A reused pane still holds the previous run's conversation, so compact it before
this run's first task reaches it:

1. Send the command to the pane as a TUI command:

   ```bash
   herdr agent prompt <pane-id> "/compact"
   ```

   This is not a delegation: no result return is expected, so the Herdr skill's
   parent wrapper and its return transport do not apply and the raw
   `herdr agent prompt` call is the transport. The pane is in the same
   workspace, which the reuse conditions already require.

2. Judge completion on the screen. While the compaction runs, the visible
   snapshot shows `Compacting context... (escape to cancel)`, and
   `herdr agent get` still reports `agent_status: idle`; the status is never a
   completion signal. The pane is ready when a fresh read has that line gone.

3. Send the next task only after that read. Never send a task, a return, or any
   other command while the indicator is on screen. Re-read the snapshot in
   short bounded steps; do not hold the orchestrator pane with long
   `sleep`-based polling
   ([Async delegation](../../herdr/SKILL.md#async-delegation)).

A compaction that does not finish, or that leaves an error, fails the reuse:
the pane receives no task for this run and a new pane is built for the role
instead. The pane stays open either way.

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

A role that had no pane in the previous run has nothing to reuse, and the
planner cannot move an existing pane into a planned cell
([pane layout](../../herdr/references/pane-layout.md#exceptions-to-the-skills-pane-rules)):

- one new role: split it from the orchestrator pane with the Herdr skill's
  single-pane rules
  ([When the requested agent is absent](../../herdr/SKILL.md#when-the-requested-agent-is-absent));
- two or more new roles:
  `herdr/scripts/pane-layout.sh apply --count <new panes>` with the new panes
  only, never the whole team, because the planner's minimum count is 2 and it
  does not cover the single-pane case.

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
