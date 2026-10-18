# Operator team roles

A standing composition for a workspace that takes requests over a long period:
one pane is the single entry point, and a small fixed team beside it takes the
read-only investigation, the records and prose, and the delivery gates. The
roles outlive any single task, unlike a per-task team in a worktree workspace
([Worktree workspace teams](worktree-workspace-teams.md)).

The composition is a user-owned asset, not part of this skill: the user decides
whether to run it and owns the workspace, the labels, the role documents, and
the scripts. This reference fixes the shape those pieces have, so the team can
be rebuilt ([Session restore](session-restore.md)) and its reports stay
readable. The generalized shape of the files is in
[the operator team example](../examples/operator-team/README.md): values are
placeholders and the scripts show the split of responsibility, not a supported
harness.

## Roles

| Role | Owns | Does not |
|---|---|---|
| Orchestrator (`司令塔`) | the single request window; the delegation depth of each request (investigation only, an Issue, a pull request with review, a merge — default: a pull request with review); one completion or block report per run; the merge decision; the records and their cleanup | investigating, implementing, reviewing, or testing directly |
| Advisor (`参謀`) | immediate read-only work: lookups, greps, GitHub reads, Herdr state checks, and drafts of commands, comments, and kickoff text | writing files by default, judgement calls, creating panes, merging |
| Scribe (`書記`) | the records: the state note, the history log, the feedback list, and the inbox; drafts of Issues, pull requests, and comments; summaries; the size and link check | decisions, GitHub writes, implementation, deleting without being asked |
| Controller (`管制`) | the run watch; the five-point gate; the merge on a pass; the cleanup after it (worktree, branch, grant) | implementing, reviewing, filing Issues, editing the records |

The role name is stable and is also a trigger the user may speak (`参謀`); the
pane label adds the display name the user chose for that pane. One role is one
pane, and a role the orchestrator does not watch never shares the orchestrator's
tab.

The delegation depth is a decision, so a request is either explicit about it or
gets one question back before anything starts. The orchestrator never takes
over the work of a role it delegated to; the only exception is a small immediate
check that no delegation can answer in time, such as one `grep`, one `gh` state
read, or one size check.

## Five-point merge gate

The controller runs the same five checks on the latest head before every merge:

1. the pull request can be marked ready: no conflict and a mergeable state;
2. a review of that head with no Blocker, meaning the review's commit equals the
   head and no Blocker remains;
3. CI success for that head;
4. no unresolved review thread;
5. when the run had a `ui-tester`, the evidence comment names that head.

All five pass: the controller adds the Issue number to the title, marks the pull
request ready, merges it as a squash, closes the Issue only when the agreed
decision says this pull request closes it, and cleans up. Anything else — a
failed check, a check that cannot be verified, or a stale head — is not a merge:
the controller returns the observed state and lets the orchestrator decide
whether to send the work back, stop it, or report it. The gate is a check, not a
judgement call, so an unverifiable check never passes by reasoning.

The closing keyword is not a sixth check. Whether a pull request closes its
Issue is the decision its kickoff agreed
([Kickoff gate](../../pi-issue-pr-workflow/SKILL.md#kickoff-gate)): a closing
keyword only for the last pull request of a plan, a non-closing reference
otherwise. The controller confirms that the body follows that decision instead
of requiring the keyword, because a missing keyword would fail a correct
intermediate pull request, and one added to pass the gate would close an Issue
the plan has not finished.

## One label file

Every literal — the workspace label, one label per role, the tab labels, and the
optional plugin id and entrypoint — lives in one file, and every script and role
document reads it from there ([the label file](../examples/operator-team/panes.conf)).
A label has the form `<role> (<name>)`: the role part is stable and the name part
is the user's display name for that pane. One pane carries each label, and the
label is what a restore looks for ([Session restore](session-restore.md)).

A label is display state: it narrows a restore to the pane the composition
expects, and it never authenticates a caller or selects a delegation target
([Technical delegation boundary](technical-delegation-boundary.md)).

## Role documents

One document per role, kept beside the label file. The pane receives its
document when it starts and after a restore, so the document states the role's
boundary — what it owns, what it never does, and how it returns — and nothing
about a current task: a task belongs to a delegation, not to a role document.

## Companion scripts

| Script | Responsibility |
|---|---|
| [`restore-session.sh`](../examples/operator-team/bin/restore-session.sh) | rebuild the panes, agents, and role documents from the labels ([Session restore](session-restore.md)) |
| `sync.sh` | fast-forward the standing checkouts to the remote `main`; a checkout with local changes is skipped and the others continue |
| `size-check.sh` | report the records that outgrew their line or entry limit and the relative links that no longer resolve; it only reports |
| `runs.sh` | print the live workspaces by display name with their pane and agent state, for reports |

The scripts share three rules: every literal comes from the label file, a write
is reported as done only when the command's response confirms it, and a failure
names the role and the step it occurred in.

## Reporting

Every role return and every user-facing report has the same shape:

- Conclusion first: the answer in the first one or two lines, then headings with
  bullet lists for the detail. A role return stays within a few lines and drops
  the narrative its reader cannot act on.
- One screen: the report stays readable without scrolling, so detail moves behind
  a path or a link instead of growing the message.
- A question for a human is appended to a durable list — for example
  `PENDING.md`, with an id, the question, and its state — instead of being left
  in the conversation, and it stays in the list after it is answered so the same
  question is not asked twice. Confirming it in chat alone loses it: the next
  reader of the list never sees it.
- The report opens with the count of items waiting on a decision, so what the
  user owes is visible before the detail.
- No report carries a secret or environment-specific network information: tokens
  and keys never appear, and a path is written relative to its root.

The orchestrator's report is the composition's only user-facing message; the
other roles return to the orchestrator. The controller is the one role whose
return repeats observed values — the reviewed commit, the CI conclusion, the
unresolved thread count, and the merged commit — so the orchestrator can report
them without reading GitHub again.
