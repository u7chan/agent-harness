# Kickoff task template

Format of the task text the parent hands to the orchestrator in an
orchestrator-first worktree team. The team table, the approval rules, and the
procedure remain authoritative in [pi-issue-pr-workflow/SKILL.md](../SKILL.md);
this template fixes the shape of the task text only and does not restate or
change them.

The worktree environment block and the rules for taking its IDs from Herdr
JSON responses are defined once in
[Worktree workspace teams — Orchestrator-first](../../herdr/references/worktree-workspace-teams.md#orchestrator-first).
Use that section as the source; the copy below is only the field list a task
text must carry.

## Identifiers

```text
role: orchestrator
provider: <provider>
model: <model>
thinking: <level>
```

`role` names the agent receiving this task text. Fill provider, model, and
thinking from the approved team specification; the
[Kickoff gate](../SKILL.md#kickoff-gate) remains the authority for the team
table and approval rules. The parent passes the same three values to
`worktree-team-start.sh`.

## Worktree environment block

```text
workspace: <linked workspace ID>
pane: <root pane ID>
checkout: <worktree checkout path>
branch: <work branch>
base ref: <base ref>
base commit: <base commit>
```

Resolve every value exactly as the Herdr section defines; do not guess IDs.

## Target

```text
issue: <Issue URL or owner/repo#number>
pr: <Draft PR URL or number; none yet at kickoff>
scope: <Issue scope the orchestrator must not exceed>
```

## Workflow procedure

Run [pi-issue-pr-workflow](../SKILL.md) from
[Start the team](../SKILL.md#start-the-team) through
[Completion](../SKILL.md#completion): start the approved team, hand `impl` the
kickoff task, and follow the Delegation contract, Implementation, Initial
review, Review fixes, and Review loop sections. The skill is the procedure
authority.

## Verification policy

Follow the Issue's and the repository's required verification and the
[Delegation contract](../SKILL.md#delegation-contract) completion rule: a role
returns `completed` only after every required check has passed, and otherwise
returns `blocked` with the command and its result.

## Return target

Return `completed` or `blocked` to the direct parent pane that delegated this
task. The appended delegation instruction names that pane and the return
helper to use ([Async delegation](../../herdr/SKILL.md#async-delegation)).
