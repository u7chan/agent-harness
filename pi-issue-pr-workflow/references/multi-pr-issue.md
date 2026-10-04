# Multi-PR Issues

Shapes for the target-PR and close-keyword rules in
[Kickoff gate](../SKILL.md#kickoff-gate) and
[Completion](../SKILL.md#completion). This file fixes what a run writes down;
the rules stay in `SKILL.md`.

## Split example

An Issue can plan more than one PR. A common split keeps the first PR
self-contained and stacks the second on it:

| PR | Scope | Base branch | Work branch | Closing keyword |
|---|---|---|---|---|
| ① infrastructure | model, API, migrations | the repository's base branch | `feat/issue-<n>-model` | none |
| ② UI | screens and flows on top of ① | ①'s work branch | `feat/issue-<n>-ui` | only on the position the plan and the repository conventions allow |

② is stacked: its base branch is ①'s work branch, not the repository's base
branch, and ② starts only after ①'s PR exists. In the example both PRs keep a
non-closing reference, so ①'s merge cannot close the Issue before ② lands.

Each run writes its own kickoff and report; the Issue is completed by the
sequence of runs, not by one run.

## Per-run completion report

A run reports on its own PR, not on the Issue:

| Field | Value for the run |
|---|---|
| PR | the run's Draft PR |
| Head | the commit covered by the latest verified Review-skill review (initial review or scoped recheck) |
| Verification | the checks that passed on that head |
| Issue state | the Issue may stay open until the last PR |
| Close keyword | the decision made for this run's position |

## Target PR notation

| Plan | Proposal and report value |
|---|---|
| one PR, no multi-PR plan described | `対象 PR: single` |
| first of two | `対象 PR: 1/2` |
| second of two | `対象 PR: 2/2` |

The kickoff proposal, the delegation body, and the completion report use the
same value.

## Reference spellings

Non-closing spelling, as used by the example above:

```text
Related to #<issue>
Refs #<issue>
feat(<scope>): <subject> (#<issue>)
```

Closing spellings:

```text
close #<issue>        closes #<issue>
fix #<issue>          fixes #<issue>
resolve #<issue>      resolves #<issue>
```

The repository's own conventions win over both lists.
