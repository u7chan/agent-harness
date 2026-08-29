# Skill Distribution Boundary

How skills in this repository reach running agents, and how unmerged changes are kept out of the operational set.

## Problem

Installing the repository by symlinking a working checkout into `~/.agents/skills/` makes every agent in every workspace read the checkout's working tree. Branch switches and uncommitted edits become visible immediately, so agents in different workspaces can end up with different revisions of the same skill, and unmerged changes can be mistaken for the operational set.

## Verified facts

Measured on the reference machine (pi 0.84.4):

- `~/.agents/skills/agent-harness` resolves to the shared checkout `/home/u7dev/workspace/agent-harness`, which is a regular branch checkout, not a bare tree.
- Pi loads skills from global `~/.pi/agent/skills/` and `~/.agents/skills/`, project `.pi/skills/` and `.agents/skills/`, packages, the settings `skills` array, and `--skill` paths. Names and descriptions are captured once at session startup; full `SKILL.md`, references, and scripts are read on demand.
- Visibility experiment (uncommitted edit): a file written into the checkout was readable through `~/.agents/skills/agent-harness/...` immediately and disappeared when deleted.
- Visibility experiment (branch position): with a linked worktree exposed through a symlink, an uncommitted edit and a commit on a side branch were both readable through the link; the readable content always followed the checkout's current working tree, not any fixed revision.
- Sessions launched inside Herdr worktrees (`~/.herdr/worktrees/agent-harness/*`) have no project skill location, so they resolve every skill through the global symlink, that is, through the shared checkout.
- No skill file in this repository references the `~/.agents/skills` path; only `README.md` documented the symlink install.
- Pi settings declare npm packages only, no git packages, and no `skills` array. `~/.claude/skills` is symlinked to `~/.agents/skills`.

Consequence: at startup listing time and at every on-demand read, the served content is "whatever the checkout holds right now". No gate exists between editing and distribution.

## Consistency unit

The unit of revision consistency is the **install**: one pinned revision shared by all agents, panes, and workspaces of a user account. Per-agent or per-pane revisions are reserved for testing and exist only as session-scoped explicit loads, never as global state.

Invariants:

1. The operational skill set is immutable per revision. It is never edited in place; it changes only by installing a different pinned revision.
2. Only a commit reachable from `origin/main` may be installed as the operational set (rollout gate).
3. Any agent can confirm the installed revision with one command, from any workspace, and after a reload its loaded skill set matches that revision.
4. Rollback is the same operation as rollout, targeting a previously verified revision.
5. Development checkouts and worktrees are never on a skill scan path.

Guarantee scope: a session's skill listing is captured at session startup or `/reload`; `SKILL.md` bodies, references, and scripts are read from the clone on demand. An install changes the clone for every reader immediately. Install-unit consistency therefore holds for sessions started or reloaded after the serving path last changed: after an install in steady state, and after the symlink removal during migration. A session that stays alive across an install mixes its pre-install listing with post-install file content until it reloads; the rollout and rollback procedures close this window by requiring a reload, and installs are applied between tasks.

## Design

Use pi's package mechanism with a pinned git source instead of the symlink.

- `package.json` in this repository declares `pi.skills` with the top-level skill directories; this list is the authoritative definition of the skill set.
- Install and pin: `pi install git:github.com/u7chan/agent-harness@<commit-sha>`.
- Pi clones the repository to `~/.pi/agent/git/github.com/u7chan/agent-harness` and loads the declared skills from the clone.
- Pin full commit SHAs. `pi update` does not move pinned refs; it reconciles the clone to the configured ref (reset and clean), so the clone always matches the configured revision.
- Development happens in the checkout or in linked worktrees. Neither is a scan path after migration, so unmerged changes stay invisible to other workspaces.

Rejected alternatives:

- Local-path package install (`pi install /path/to/checkout`): pi loads local paths without copying and keeps identity by resolved absolute path, so the working tree remains the served content and the leak stays.
- Symlink to an exported snapshot directory: requires a custom export and repoint runtime; the package mechanism already provides pinned clones and reconcile semantics.
- Project-level install (`.pi/settings.json` per workspace): revisions would vary per workspace and break invariant 3 (single source of truth).
- Re-symlinking the checkout: reintroduces the original leak.

## Procedures

### Development

Work in the checkout or a linked worktree on a branch. To exercise unmerged skills locally, load them explicitly for that session only:

```bash
pi --skill /path/to/checkout/gh/SKILL.md
```

Nothing under development may be added to a global or project skill location.

### Merge → rollout

1. Merge the PR to `main`.
2. Choose the merged SHA and apply the rollout gate:

```bash
git fetch origin main
git merge-base --is-ancestor <sha> origin/main && echo gate-ok
```

3. Install the pinned revision:

```bash
pi install git:github.com/u7chan/agent-harness@<sha>
```

4. Apply between tasks: `/reload` (or restart) every running session. A session reloaded after this step serves the new revision; one that skips it keeps its pre-install listing until it reloads.
5. Run the smoke test.

### Revision confirmation

All workspaces share one clone, so one command confirms the installed revision:

```bash
git -C ~/.pi/agent/git/github.com/u7chan/agent-harness rev-parse HEAD
pi list
```

This proves the clone's revision, not what a long-running session loaded: a session's listing is from its startup or last `/reload`, while its on-demand reads follow the clone. An agent confirms its skill revision as follows:

1. Run the command above at the start of a skill-dependent task.
2. If the session has not been started or reloaded since the serving path last changed to that revision (the install; during migration, the symlink removal), run `/reload` (or restart the session) before relying on skill content; after the reload the loaded set matches the installed revision.
3. Compare the revision against the expected SHA from the rollout record.

Rollout and rollback make step 2 the normal state by reloading every running session as part of the procedure.

### Rollback

```bash
pi install git:github.com/u7chan/agent-harness@<previous-verified-sha>
git -C ~/.pi/agent/git/github.com/u7chan/agent-harness rev-parse HEAD
```

Apply between tasks and `/reload` (or restart) every running session, as in rollout. Because the install is account-global, running the confirmation from any workspace verifies the state for all of them.

### Smoke test

After every rollout and rollback:

```bash
set -e
CLONE=~/.pi/agent/git/github.com/u7chan/agent-harness
EXPECTED=<installed-or-rolled-back-sha>
test "$(git -C "$CLONE" rev-parse HEAD)" = "$EXPECTED"
jq -r '.pi.skills[]' <path-to-checkout>/package.json | while read -r s; do
  test -f "$CLONE/$s/SKILL.md"
done
pi list | grep -q "git:github.com/u7chan/agent-harness"
echo smoke-ok
```

The skill list is read from `package.json` so the test cannot drift from the manifest. As an end-to-end check, start a session in an unrelated workspace and confirm its skill listing contains the expected skills; a session started or reloaded after the serving path last changed is consistent by construction. Running sessions verify themselves: after their `/reload`, each runs the confirmation command and compares against the expected SHA.

## Compatibility and migration

Order matters: the symlink shadows the package, so it must be removed before any session reloads.

1. Merge the change that adds the manifest. Nothing is installed yet.
2. `pi install git:github.com/u7chan/agent-harness@<merged-sha>`. The clone is ready but not yet serving: while the symlink exists, global locations shadow the package.
3. Remove the symlink: `unlink ~/.agents/skills/agent-harness`.
4. `/reload` (or restart) every running session. A reload before this step would re-read the old symlink path, not the package.
5. Run the smoke test.
6. Other harnesses that read `~/.agents/skills` can link the pinned clone read-only instead, for example `ln -s ~/.pi/agent/git/github.com/u7chan/agent-harness ~/.claude/skills/agent-harness`; they then follow the same pin without a second distribution path.

## Non-goals

- Moving #130's delegation resolution rules into this boundary.
- Per-workspace or per-agent revision pinning as a supported mode.
- Changes to the content or behavior of individual skills.
