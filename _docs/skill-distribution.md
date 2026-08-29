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
3. Any agent can confirm the installed revision with one command, from any workspace.
4. Rollback is the same operation as rollout, targeting a previously verified revision.
5. Development checkouts and worktrees are never on a skill scan path.

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

4. Run the smoke test.

### Revision confirmation

All workspaces share one clone, so one command confirms the revision every agent loads:

```bash
git -C ~/.pi/agent/git/github.com/u7chan/agent-harness rev-parse HEAD
pi list
```

An agent asked to confirm its skill revision runs the first command and compares the output against the expected SHA.

### Rollback

```bash
pi install git:github.com/u7chan/agent-harness@<previous-verified-sha>
git -C ~/.pi/agent/git/github.com/u7chan/agent-harness rev-parse HEAD
```

Because the install is account-global, running the confirmation from any workspace verifies the state for all of them.

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

The skill list is read from `package.json` so the test cannot drift from the manifest. As an end-to-end check, start a session in an unrelated workspace and confirm its skill listing contains the expected skills.

## Compatibility and migration

1. Merge the change that adds the manifest. Nothing is installed yet.
2. `pi install git:github.com/u7chan/agent-harness@<merged-sha>` and run the smoke test.
3. Remove the symlink: `unlink ~/.agents/skills/agent-harness`. Until this step, the symlink shadows the package, because global locations are scanned before packages.
4. Other harnesses that read `~/.agents/skills` can link the pinned clone read-only instead, for example `ln -s ~/.pi/agent/git/github.com/u7chan/agent-harness ~/.claude/skills/agent-harness`; they then follow the same pin without a second distribution path.

## Non-goals

- Moving #130's delegation resolution rules into this boundary.
- Per-workspace or per-agent revision pinning as a supported mode.
- Changes to the content or behavior of individual skills.
