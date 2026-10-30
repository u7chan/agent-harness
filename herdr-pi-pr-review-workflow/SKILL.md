---
name: herdr-pi-pr-review-workflow
description: Run a Draft PR review/fix loop with a Pi reviewer in Herdr, through verified LGTM and Ready. No Issue required.
---

# PR Review Workflow

The current agent handles user feedback, development, fixes, and coordination; only an independent Pi reviewer runs in another pane.
No Issue is required. Settle the feedback, initial implementation, branch, and Draft PR before starting this skill.
For a one-shot review, use [review](../review/SKILL.md) instead; do not silently start a fix loop or mark the PR ready.

## Boundaries

- Follow [Herdr](../herdr/SKILL.md) for panes, Pi startup, delegation, and asynchronous result delivery.
- Use the [GH](../gh/SKILL.md) dispatcher for every GitHub read and write.
- [Review](../review/SKILL.md), especially its [recheck procedure](../review/references/recheck.md), owns review criteria, rechecks, LGTM verification, and Resolve policy. Do not duplicate those rules here.
- Keep the current agent's provider, model, and thinking unchanged. Do not start another coordinator, `impl`, `pr-fix`, or `ui-tester`.
- The reviewer must not implement, commit, or push. Use only `COMMENT` reviews; never `APPROVE`, merge, or close an Issue.
- Track rounds, heads, unresolved findings, and pane IDs only in the current conversation. Do not persist run state or add a workflow runtime.

## Preflight

Before any side effect, check the following. Stop on failure, an unknown result, or an ambiguous target; do not guess.

1. Pass Herdr's Preflight and Caller pinning checks, fixing the current workspace and pane. Require `pi` too.
2. Identify one PR and pin its repository, base, head, and state with `pr.read`. Require an open, unmerged Draft PR, not an Issue reference.
3. Read the repository instructions and Git state. Confirm the checkout, work branch, and pushed HEAD match the PR head, with no unexpected working-tree changes. Never push directly to a protected base.
4. Extract the change's purpose, completion criteria, preserved contracts, and operational/compatibility requirements from the PR body and agreed request. Include conditions from verbal feedback in the delegation. Do not let the reviewer invent important missing decisions.
5. Pass every required test, check, formatter, and linter on the current head. Failed, skipped, or unavailable required verification means `blocked`; stop. Reuse existing evidence only after checking its head and scope.

## Reviewer Setup

[Pi Development Profiles](../_docs/pi-development.md) owns storage, selection, I/O, and errors. Resolve the following scripts from this skill's parent directory, the package root.

```bash
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review
```

Validate and resolve only `review`; unused roles and `pr_fix_shared_with_impl` must not gate startup.
Reuse a `result=ok` specification and report its profile, provider, model, and thinking.
Run-local explicit values override the profile without automatically rewriting it.

When composing explicit overrides, use exact IDs from `pi --list-models` and revalidate the complete specification:

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

Start only on `result=ok`. If a profile is missing, invalid, or unresolved, stop for repair or missing input unless a complete explicit specification validates. Never silently fall back to runtime defaults or another model.
On `reason=migration-required`, stop for [migration](../_docs/pi-development-migration.md), even with an explicit specification.
Do not bootstrap or automatically save/change profiles or `active`.

Follow Herdr's single-pane procedure: prefer an empty interactive shell in the current workspace; otherwise split explicitly from the current pane. Do not create a workspace or worktree.

```bash
herdr agent start pr-review --kind pi --pane <pane-id> -- \
  --provider <provider> --model <model> --thinking <thinking>
herdr pane rename <pane-id> pr-review
```

Read IDs from JSON responses and confirm the label. Verify interactive readiness and the effective provider, model, and thinking against the settled specification using the screen and runtime state. Startup arguments alone are not evidence. Stop before delegation on an unknown value or mismatch.
Use the same reviewer for every round of this run.

## Review and Fixes

Delegate through Herdr's `scripts/parent-delegate-async.sh` and return through `scripts/child-return-result.sh`. End the turn after delegation; do not block the parent with `--wait` or long sleep-based polling.
Include the absolute repository path, instructions, PR, base/work branches, head, round, purpose, completion criteria, operational/compatibility requirements, verification, read-only responsibilities, and expected report.

1. **Round 1**: Explicitly request the Review skill's PR mode. Require a posted, verified GitHub review and a `completed` or `blocked` report with review ID/URL, reviewed head, finding counts, Blockers, and verified LGTM status. Prompt delivery or an unverified LGTM claim is not completion.
2. **Fixes**: When Blockers remain, the current agent reads the posted feedback and fixes it without expanding scope. Pass all required verification, commit, push, and reply to relevant comments as repository instructions require. Do not resolve threads merely because a fix was pushed. Never advance on an unknown push result or failed verification.
3. **Round 2 / Round 3**: After a confirmed fix push, explicitly request the same reviewer's [recheck procedure](../review/references/recheck.md): both reclassification of prior unresolved findings and the latest-head review within that reference's scope. Classification replies alone cannot establish LGTM. Carry forward operational/compatibility requirements.
4. Explicitly designate workflow-context auto-resolve in the recheck delegation. Follow the canonical recheck procedure for eligibility, reply confirmation, targets, and lightweight checks. On handoff, require the verified target set `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` and treat that set as authoritative; do not reconstruct targets from a fresh read. After each Resolve, confirm `resolved=true` through `review-threads.read`.

Allow at most three rounds, including the initial review. A verified LGTM for the current head with no Blocker advances to completion immediately. If a Blocker remains after Round 3, stop with the PR still Draft and report the remaining condition and evidence; do not add a round.
Also stop on `blocked`, important uncertainty, a head change, or an unconfirmed write. Nit / Consider / FYI findings and separate Issue candidates alone do not block LGTM accepted by the Review skill.

## Completion and Ready

A request to run this review/fix/Ready workflow includes `pr.ready` after the conditions below, without another approval wait. A one-shot review request does not authorize Ready.

1. All required verification has passed on the current PR head, and the push is confirmed.
2. A posted, verified Review-skill LGTM covers the latest head, with no Blocker.
3. Every Resolve target from the latest recheck has been processed and confirmed by re-read. Leave other conversations open and report them; LGTM itself does not authorize resolving all threads.
4. **Immediately before Ready**, use `pr.read` to confirm open, unmerged, Draft state and a head matching the verification and LGTM. Stop on a mismatch, failure, or unknown result.
5. Call the GH dispatcher's `pr.ready` with the target and explicit `grant: "sensitive-write"`.
6. **Immediately after Ready**, use `pr.read` again. Complete only after confirming open, unmerged, `draft=false`, and the same head. Do not count `failed`, `unknown_outcome`, or a changed head as success, and never retry automatically.

Report the PR, profile or explicit-spec origin, reviewer specification/pane, latest head, verification, round count, LGTM, Resolve results, remaining optional findings/conversations, and Ready status. Keep the reviewer pane open.
For a PR that changes skills, also prompt the post-merge [rollout](../_docs/skill-distribution.md).
