---
name: pi-issue-pr-workflow
description: Orchestrate a GitHub Issue from implementation through final review of a Draft PR using role-specific Pi agents in Herdr panes. Use when the user asks to run this Pi-only Issue-to-PR workflow, including kickoff team selection, implementation, review, and review fixes. Requires Herdr.
---

# Pi Issue PR Workflow

Coordinate the workflow; do not implement or fix the Issue in the orchestrator pane.

## Boundaries

Load and follow the existing skills instead of duplicating their behavior:

- [Herdr](../herdr/SKILL.md) for panes, Pi agent startup, asynchronous delegation, and result delivery.
- [GH](../gh/SKILL.md) for every GitHub read and write.
- [Review](../review/SKILL.md) for full PR reviews, rechecks, and the conversation-resolution policy.

Those skills are authoritative for their safety and operation rules. Keep all agents in the current Herdr workspace and worktree. Do not add a workflow runtime, persistent state, or a static provider/model catalog.

## Preflight

Before any workflow side effect:

1. Require an unambiguous GitHub Issue reference. If it is absent, ask for it.
2. Run the Herdr preflight and require `HERDR_WORKSPACE_ID` in addition to the Herdr skill's checks.
3. Require `pi` and obtain the live model catalog with `pi --list-models`.
4. Read the Issue and its conversation comments through the GH skill.
5. Read the target repository's instructions and inspect its Git and worktree state.

Stop on an ambiguous repository, unexpected worktree changes, or unavailable required tooling. Do not guess a target, discard changes, or create a replacement workspace.

## Team specification

The logical roles are `impl`, `review`, and `pr-fix`. Every physical agent is Pi. A complete physical agent specification contains all of:

- the exact provider ID;
- the exact model ID under that provider in `pi --list-models`;
- one thinking level supported by that exact model: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.

`pr-fix` may be assigned to the `impl` agent instead of a distinct agent. The `review` role must always use a distinct agent and must not edit the implementation.

Use `pi --list-models` to validate every explicit provider/model pair, but do not treat its thinking yes/no column as level validation. Resolve the model through Pi's installed runtime metadata and use its `thinkingLevelMap` semantics, which are the same model-specific supported-level and clamping logic used by Pi, to verify that the requested thinking level is supported and remains unchanged as the effective level. Do not silently choose a Pi default, accept a clamped level, maintain aliases, or infer an unavailable ID. Treat a partial, invalid, ambiguous, unsupported, or clamped specification as unresolved.

## Kickoff gate

If any role assignment or agent specification is unresolved, inspect the Issue and relevant repository context, then propose the complete team before continuing. Preserve every valid value the user supplied.

Use a table containing:

| Role | Assignee | Provider | Model | Thinking | Selection reason |
|---|---|---|---|---|---|

Choose task-adaptively: right-size model capability and thinking for each role, and reserve stronger reasoning for complexity that requires it. State uncertainty and tradeoffs; do not invent pricing, quota, latency, or capability claims.

Assign `pr-fix` to `impl` by default. Propose a distinct fixer only when there is a concrete handoff benefit, such as different required expertise, likely context pressure, or changes spanning independently understandable areas. Explain that reason in the proposal.

Wait for explicit approval of the complete proposal. Before approval, do not create or switch branches, create panes, start agents, or perform GitHub writes. If all assignments were already complete and valid, summarize the resolved team and proceed without an additional approval round.

## Start the team

After the team is settled:

1. Determine the base branch from the current repository context and its instructions.
2. Create the dedicated work branch required by those instructions. Use an existing work branch only when the user explicitly selected it. Do not push directly to a protected base branch.
3. Follow the Herdr skill to inspect the current workspace and obtain one shell pane for each physical agent.
4. Start every selected agent with the validated values:

   ```bash
   herdr agent start <name> --kind pi --pane <pane-id> -- \
     --provider <provider> --model <model> --thinking <thinking>
   ```

5. Apply responsibility-based agent names and pane labels.
6. Inspect each started Pi pane's runtime status and verify that its effective provider, model, and thinking level exactly match the approved specification before sending work. If any value differs or cannot be verified, stop.

Start both agents for a shared `impl`/`pr-fix` team, or all three agents when `pr-fix` is separate. If any startup result is failed or unknown, do not start implementation and do not automatically close the panes that were created. Report the observed state.

Only `impl` receives a task at kickoff. Leave `review` and a separate `pr-fix` idle until their phases.

## Delegation contract

Use the Herdr skill's asynchronous parent-to-child wrapper for each task. Include the role, Issue, base and work branches, current PR when available, repository instructions, phase-specific scope, and expected report. Never assume that agents share conversation context merely because they share a worktree.

Each role must return `completed` or `blocked` through the direct-parent result helper. Its report must identify the work performed, verification, relevant commit or PR, and any unresolved condition. A submitted prompt is not proof of completion; inspect agent state and output before advancing.

`completed` requires every verification mandated by the Issue and repository instructions to have run and succeeded. A failed, skipped, or unavailable required check must return `blocked` with its command and result; never advance merely because verification finished.

Track the Issue, team assignments and pane IDs, base and work branches, current phase, PR, reviewed head, review round, and unresolved Blockers only in the current conversation. Do not write workflow state to disk.

### Implementation

Ask `impl` to:

1. read the Issue and comments;
2. implement only the Issue scope and follow repository instructions;
3. run and pass every required test, check, formatter, and linter;
4. commit and push the work branch;
5. use the GH skill to create a Draft PR with the required repository-specific description;
6. return the commit, verification results, and PR number and URL.

Do not advance without successful required verification, a confirmed push, and a Draft PR. If required verification fails or cannot run, require `blocked` and stop before treating the implementation as complete. Do not treat an unknown Git or GitHub result as success or blindly repeat it.

### Initial review

Give the PR URL or number to `review` and explicitly ask it to use the Review skill in PR mode. The reviewer posts its result to GitHub and returns the review round, head commit, finding counts, and whether a Blocker remains.

The reviewer never implements a fix, approves the PR, or merges it. Nit, Consider, and FYI findings do not block this workflow when the Review skill reports LGTM.

### Review fixes

When a Blocker remains, send the PR and exact posted feedback to the assigned `pr-fix` agent. If `impl` owns `pr-fix`, reuse the same agent and pane.

Ask the fixer to:

1. read the current PR feedback through the GH skill;
2. address the reported Blockers without expanding scope;
3. rerun and pass every required verification for the updated head;
4. commit and push the fix;
5. reply to the relevant review comments when required by repository instructions;
6. return the commit, verification, replies, and unresolved feedback.

The fixer must return `blocked` when required verification fails or cannot run. It must not resolve review conversations.

### Review loop

After a confirmed fix push, ask the same `review` agent explicitly to recheck all prior unresolved findings and, in that same task, perform a full review of the latest head using the Review skill's recheck procedure. Do not request only normal PR mode or make the recheck optional: the delegation must require both reclassification of the prior root comments and review of the full current diff and affected code for regressions. Recheck replies alone are never sufficient to establish LGTM.

Count the initial full review as Round 1 and allow at most three full review rounds in total.

- If the latest full review of the current head posts LGTM with no Blocker, complete the workflow.
- If a Blocker remains before Round 3, repeat fix then full review.
- If a Blocker remains after Round 3, stop and report the remaining failure condition and evidence.
- If any agent returns `blocked`, stop the phase and request the needed decision or input.

Do not introduce a separate retry, queue, or state machine around Herdr or GitHub operations.

## Completion

Complete only when all of the following are confirmed:

- the Issue implementation is pushed to the PR head;
- every required verification has succeeded on the current PR head;
- the PR exists and remains Draft;
- the current PR head matches the commit covered by the latest full Review-skill LGTM review (including a recheck's full latest-head review), with no Blocker;
- no required review fix remains unaddressed.

Conversation resolution is explicit instruction only. A thread may be resolved only when the user explicitly instructed to resolve that thread: the orchestrator (or, when delegated, the reviewer) posts a closing comment on the thread and then resolves it with `review-threads.resolve`. A verified LGTM does not auto-resolve any thread, and the orchestrator must not resolve threads outside an explicit instruction. `Partial`, `Unresolved`, `Unknown`, other authors' threads, and user-decision discussions remain open. Do not automatically mark the PR ready, close panes, merge the PR, or close the Issue.

Report the Issue, base and work branches, Draft PR, latest commit, verification, review round count, unresolved optional feedback or conversations, and every created pane's role and observed state. When the PR's changed files include any skill, the report must also prompt the post-merge rollout: after merging, run the rollout procedure in [_docs/skill-distribution.md](../_docs/skill-distribution.md). Leave the panes available for inspection unless the user explicitly requests cleanup.
