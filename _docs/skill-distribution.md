# Skill Distribution Boundary

How skills in this repository reach running agents, and how unmerged changes are kept out of the operational set.

## Problem

Installing the repository by symlinking a working checkout into `~/.agents/skills/` makes every agent in every workspace read the checkout's working tree. Branch switches and uncommitted edits become visible immediately, so agents in different workspaces can end up with different revisions of the same skill, and unmerged changes can be mistaken for the operational set.

## Notation

Code blocks in this document contain no machine-specific paths: per the rule in [AGENTS.md](../AGENTS.md), the checkout and distribution locations of the machine where a procedure runs appear as placeholders. Substitute the values of your own environment:

- `<checkout>` — a local checkout or linked worktree of this repository used for development. Steps that need only the repository's files or history (the merge checks, the `pi --skill` example under Development) run from it.
- `<dist-root>` — the account-scoped distribution root, resolved from `AGENT_HARNESS_HOME` and defaulting to `${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness`. It holds the bare fetch mirror (`git/`), one immutable tree per revision (`releases/<sha>/`), the `current` symlink, and the rollout record. It must be an absolute path.
- `<repo-url>` — the fetch source, resolved from `AGENT_HARNESS_REPO_URL` and defaulting to `https://github.com/u7chan/agent-harness.git`.
- `<release-sha>` (also written `<merged-sha>`, `<previous-sha>`, and `<installed-or-rolled-back-sha>` where a step installs or verifies one specific revision) — a lowercase full 40-character commit SHA. The update command accepts only full SHAs so that a record line never depends on a local abbreviation rule.
- `<rollout-record>` — `<dist-root>/rollout.jsonl`, the account-scoped record defined under [Rollout record](#rollout-record).
- `<link-dir>` — one harness skill directory that holds the per-skill links, such as `~/.agents/skills`. `--link-dir` may be repeated; without it the command uses `~/.agents/skills`.
- `<dist-command>` — `scripts/skill-distribution/dist.sh` in this repository, run from `<checkout>`.

Per-user skill directories of the harnesses (`~/.pi/agent/skills`, `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills`, project `.pi/skills`, `.agents/skills`) are conventions with the same meaning on every machine using those harnesses and are written literally. Absolute paths of an individual machine's checkouts and distribution roots never appear.

## Verified facts

The first block is the measurement of the superseded symlink install: it records that machine's state at measurement time (pi 0.84.4, Linux), and the Design section has since replaced both that install and the pi package install that followed it. The measured behaviors are kept, not the machine-specific path values.

- `~/.agents/skills/agent-harness` resolved to the shared checkout of this repository — a regular branch checkout, not a bare tree.
- Pi loads skills from global `~/.pi/agent/skills/` and `~/.agents/skills/`, project `.pi/skills/` and `.agents/skills/`, packages, the settings `skills` array, and `--skill` paths. Names and descriptions are captured once at session startup; full `SKILL.md`, references, and scripts are read on demand.
- Visibility experiment (uncommitted edit): a file written into the checkout was readable through `~/.agents/skills/agent-harness/...` immediately and disappeared when deleted.
- Visibility experiment (branch position): with a linked worktree exposed through a symlink, an uncommitted edit and a commit on a side branch were both readable through the link; the readable content always followed the checkout's current working tree, not any fixed revision.
- Sessions launched inside linked Herdr worktrees of this repository (the reference setup runs one worktree per task) have no project skill location, so they resolve every skill through the global path. The Herdr-side procedure for that topology is in [herdr/references/worktree-workspace-teams.md](../herdr/references/worktree-workspace-teams.md).
- No skill file in this repository references `~/.agents/skills` or any checkout path.
- Pi settings declared npm packages only — no git packages and no `skills` array. `~/.claude/skills` was symlinked to `~/.agents/skills`.

Consequence: at startup listing time and at every on-demand read, the served content is "whatever the checkout holds right now". No gate exists between editing and distribution.

Measured on 2026-11-18 while designing the current layout ([#285](https://github.com/u7chan/agent-harness/issues/285)); both spikes ran on WSL with Claude Code 2.1.327 and Pi v1.5.2:

- Claude Code discovers skills exactly one directory below a scan path. A skill at `~/.agents/skills/<skill>/SKILL.md` is found; one at `~/.agents/skills/<group>/<skill>/SKILL.md` is not, so a directory-level link to the distribution root is not a distribution mechanism for that harness.
- Pi reads two levels, so it finds both shapes. Its skill loader resolves real paths and silently skips a second file with the same name; two per-skill links that resolve to the same file therefore raise no collision warning, while two different targets with the same skill name do.
- `../` inside a linked skill directory resolves in the target tree: `~/.agents/skills/herdr/../_docs/` and `~/.agents/skills/herdr/../scripts/` reached the clone's own copies, and a link to an unlinked sibling skill (`herdr` referencing `herdr-pi-issue-pr-workflow`) still resolved.
- Per-skill links preserve the executable bit of scripts and the relative references of `SKILL.md`, so a release tree can carry `_docs/` and `scripts/` beside the skills at one revision.
- Codex CLI discovery is unverified. The harness table under [Compatibility and migration](#compatibility-and-migration) marks it as such instead of claiming it.

## Consistency unit

The unit of revision consistency is the **install**: one pinned revision shared by all agents, panes, and workspaces of a user account. Per-agent or per-pane revisions are reserved for testing and exist only as session-scoped explicit loads, never as global state.

Invariants:

1. The operational skill set is immutable per revision. A release tree is never edited in place; it changes only by installing a different pinned revision.
2. Only a commit reachable from `origin/main` may be installed as the operational set (rollout gate).
3. Any agent can confirm the installed revision with one command, from any workspace, and after a reload its loaded skill set matches that revision.
4. Rollback is the same operation as rollout, targeting a previously verified revision, and it works without network access while that release is still on disk.
5. Development checkouts and worktrees are never on a skill scan path, and no release tree holds a git working copy.
6. The served revision is the same for every harness on the machine: they read one set of links into one release, not per-harness copies.

Guarantee scope: a session's skill listing is captured at session startup or `/reload`; `SKILL.md` bodies, references, and scripts are read from the release tree on demand. A switch changes what every later read resolves to, so a session that stays alive across a switch mixes its pre-switch listing with post-switch file content until it reloads. The rollout and rollback procedures close this window by requiring a reload, and installs are applied between tasks.

## Design

Distribution is git plus a symlink switch. It no longer uses the pi package mechanism, and no step calls pi, claude, codex, or another harness CLI.

Layout of `<dist-root>`:

```text
<dist-root>/
  git/                    bare mirror of <repo-url>; the only fetch cache
  releases/<sha>/         immutable tree exported with `git archive`
  current -> releases/<sha>
  rollout.jsonl           append-only rollout record
```

- **Releases instead of a single pinned clone.** A working clone would have to change with `git fetch` plus a checkout or reset, and readers would see a partially updated tree in that window. A release is built and verified in a staging directory inside `<dist-root>`, published with one `rename(2)`, and the `current` symlink is replaced with one `rename(2)` as well, so a reader resolves either the old tree or the new one. Retention is trivial: the measured tree was 4 MB and 196 files, a rollback source stays available offline, and pruning is manual.
- **Bare mirror, no working tree.** `releases/` never contains `.git`, and uncommitted work in a development checkout cannot reach the serving path because nothing reads a working tree. Rollback reuses an exported release without network access; a revision that is not on disk is fetched and passes the gate first.
- **Neutral manifest.** `skills.json` at the repository root is the authoritative definition of the skill set: `{"schema_version": 1, "skills": [...]}`, sorted and unique. `package.json#pi.skills` is a derived mirror kept for the legacy pi package path; `scripts/check-skill-manifest.sh` compares the two in both directions, requires a `SKILL.md` for every listed skill, and fails on any `SKILL.md` that is not exactly one directory below the root. The one-level rule is enforced because Claude Code cannot see a nested skill while the other harnesses can.
- **One update command, owned by this repository.** `scripts/skill-distribution/dist.sh` implements rollout, rollback, status, and verification, and it ships in the release tree together with every skill, so `_docs/` and `scripts/` references inside a skill resolve at the served revision. Workstation repositories call it; they do not reimplement the fetch, gate, staging, switch, or link logic.
- **The gate lives in the command.** Every rollout and rollback checks `git merge-base --is-ancestor <sha> origin/main` against the mirror's `origin/main` ref before publishing, so a SHA that is not on `main` never becomes the served revision. A rollback checks against the last fetched `origin/main`, which is why the gate can still run offline.
- **Links, not copies.** For each skill in the release manifest, the command creates `<link-dir>/<skill>` pointing at `<dist-root>/current/<skill>`. The link target does not change across releases, so a switch needs no link work, and only the harness directories that exist are touched. At least one link directory must exist for `update` and `verify`; the command never creates the parent directory, so a machine with no harness skill directory is prepared with `--no-link` and linked later. The command owns the links it created (its targets are under `<dist-root>`) and removes links for skills that the release no longer serves. A real directory in a link position is never replaced, and a foreign symlink is refused unless `--replace-links` is given for a migration.
- **Link ownership.** `~/.agents/skills` and the other harness directories are owned by each workstation's configuration; this repository creates and removes only the per-skill links inside them. It never creates the parent directory and never removes it. `~/.claude/skills` may be a symlink to `~/.agents/skills`; the two paths are then the same directory and the command treats them as such.

Rejected alternatives:

- Local-path pi package install (`pi install /path/to/checkout`): pi loads local paths without copying and keeps identity by resolved absolute path, so the working tree remains the served content and the leak stays.
- The pinned pi git package that this design replaces: it made the pi CLI the distribution mechanism, so a machine without pi could not update the skills, two machines could not run the same update step, and one update path had to call `pi install` while the other had none.
- A single pinned clone updated with `git fetch` and `git reset --hard`: readers observe a partially reset tree, rollback needs network access when the old revision is not local, and the checkout semantics invite in-place edits of the operational set.
- Symlinking the whole distribution root into a harness skill directory: Claude Code discovers only one level, so the harness that most needs a shared copy would see nothing.
- A per-harness manifest or per-harness release: it duplicates the skill list and breaks invariant 6.
- Re-symlinking the checkout: reintroduces the original leak.

## Procedures

### Development

Work in `<checkout>` or a linked worktree on a branch. Nothing under development may be added to a global or project skill location.

Verifying unmerged skills is session-scoped; the canonical procedure lives in [skill-testing.md](skill-testing.md) (Japanese), and this document does not duplicate it. Do not load an unmerged skill for verification with `pi --skill <checkout>/<skill>/SKILL.md`: with a pinned install in place, the same-named installed skill wins (pi keeps the first skill found) and the explicit path is skipped - observed 2026-09-02 as `✗ <path> (skipped)` - so the session can exercise the installed revision while appearing to verify the development copy. The canonical procedure reads the target files by absolute path and includes a read-path and revision check as evidence.

### Merge → rollout

This section is the single authoritative procedure for merging a PR of this repository and for rolling the merged revision out. It covers `main`: the merge method, the branch-deletion setting, and the required check names below belong to this repository, so a repository with different settings needs its own reading of the same steps.

#### Merge

An agent merges only under an explicit instruction that names the PR and asks for the merge. A general "go ahead", or an instruction inside a workflow, is not one. Where a skill or workflow forbids merging - the Herdr reviewer and orchestrator do - the prohibition wins even with an instruction: report the PR, its SHA, and this procedure, and hand the merge over.

Stop on any failure or unknown result in the following checks.

- `pr.read` reports `state: open`, `draft: false`, and `mergeable: true`, re-reading once when `mergeable` is `null`.
- `base.ref` is `main`, `base.repo` is this repository, and `head.repo` is the expected one. A PR based on another branch (an `epic` branch) is outside this procedure and is handed over.
- `git remote get-url origin` names the repository passed to gh. `--repo` fixes the gh target only; with a fork as `origin`, the later `git fetch origin main` reads the fork, and running the commands from the same checkout does not change that.
- `head.sha` is the verified SHA: the reviewed LGTM target, or the SHA named by the instruction.
- Every required check is `completed` with `success`. `pr.checks.read` carries no required flag, and one check name appears once for the push run and once for the pull request run, so match names instead of counting entries. For this repository the required names are the two jobs of [`.github/workflows/contract-tests.yml`](../.github/workflows/contract-tests.yml). Zero checks, a missing required name, a pending status, or any conclusion other than `success` stops the merge.

Run the commands below in the checkout whose `origin` you verified. Keep the pre-merge head and the subject; both are the reference for the checks after the merge.

```bash
git fetch origin main
before=$(git rev-parse origin/main)
subject="<PR title> (#N)"
gh pr merge <N> --squash --match-head-commit <verified-head-sha> --subject "$subject"
```

`--match-head-commit` fails the merge when the head moved after the verification. Do not pass `--body` or `--delete-branch`: this repository generates the squash body from the commit messages (`squash_merge_commit_message: COMMIT_MESSAGES`) and deletes the head branch on merge (`delete_branch_on_merge: true`). A failed merge is not retried; read the state with `pr.read` and report it.

The command bypasses the dispatcher by design: it takes no `grant` input, returns no common envelope, and does not map exit codes (`gh/scripts/gh.sh` enforces the grant levels for its actions). Read the exit status and re-read the state with `pr.read`; do not parse the output and do not assume the dispatcher's guarantees.

After the merge, stop unless all of the following hold.

- `pr.read` reports `state: closed` with `merged: true` - REST reports `closed` for a merged PR, unlike the `MERGED` state the gh CLI prints - and `head.sha` is the verified SHA.
- Exactly one commit in the first-parent range since the pre-merge head carries the subject passed above. The tip of `origin/main` is not the reference: later merges move it.

```bash
git fetch origin main
git log --first-parent --format='%H %s' --reverse "$before"..origin/main |
  MERGE_SUBJECT="$subject" awk '
    BEGIN { s = ENVIRON["MERGE_SUBJECT"] }
    { sha = $1; sub(/^[0-9a-f]+ /, ""); if ($0 == s) { print sha; n++ } }
    END { printf "matches=%d\n", n > "/dev/stderr"; exit (n == 1 ? 0 : 1) }'
```

Require one match and a zero exit. Do not shorten the scan with `grep -m1`, `head -1`, or `grep -q`: an early exit SIGPIPEs the producer and, under `pipefail`, turns a success into a non-zero status. Pass the subject through `ENVIRON`, because `awk -v` expands escapes and a subject such as `C:\temp` would then differ. Compare against the string passed to `--subject`, not against the current PR title.

- `git merge-base --is-ancestor <merged-sha> origin/main` succeeds.

#### Rollout

Rollout applies when the PR changes a skill, or when it changes the distribution layout, command, or manifest: in the second case the merged revision is what introduces the new procedure, so nothing else can deliver it. `AGENTS.md` makes the PR body state which case applies (`Rollout: 必要` or `Rollout: 不要`), so read that line instead of guessing from the diff. For a PR that changes neither, the merge and its checks above complete the work: do not install a revision, reload sessions, or append to the record.

Take the merged SHA as `<commit-sha>`.

1. Record the baseline. When `<rollout-record>` is absent and a revision is already served, the update command appends that revision with `"previous": null` before switching ([Initial baseline](#initial-baseline)); nothing else needs to be prepared by hand. A corrupt or unreadable record is not reset: the command stops and reports it.
2. Apply between tasks. When rolling out the shared development-profile namespace for the first time, perform [the backed-up profile migration](pi-development-migration.md) after the switch and before reloading or starting another workflow. Profile assets are not part of a release tree and do not migrate with it.
3. Run the update from `<checkout>`:

   ```bash
   scripts/skill-distribution/dist.sh update --sha <commit-sha> --pr <PR URL>
   ```

   The command fetches `origin/main` into `<dist-root>/git`, gates the requested SHA, exports and verifies the release, switches `current`, reconciles the per-skill links, verifies them, and appends `<rollout-record>`. Omitting `--sha` serves the current `origin/main` head, which is only what you want when no later merge should be skipped. On the first cutover from the pi package install, add `--replace-links` as described in [Compatibility and migration](#compatibility-and-migration).
4. Unregister the legacy pi package when it is still registered: after the switch and before the reload, run `pi list` once and, if it names `git:github.com/u7chan/agent-harness`, `pi remove git:github.com/u7chan/agent-harness`. Skipping this leaves two different real paths for the same skill names, which Pi reports as a collision. A machine without pi skips this step; nothing in the distribution path depends on pi.
5. `/reload` (or restart) every running session. A session reloaded after this step serves the new revision; one that skips it keeps its pre-switch listing until it reloads.
6. Run the [smoke test](#smoke-test) with the installed SHA, then the session-level listing check.
7. Report the served revision, the record line, the session check, and the PR. If the session listing disagrees with the verified revision, roll back with the same command and report both revisions instead of leaving the machine in a mixed state.

Rollout and rollback are the same operation on different SHAs; there is no separate "update" command to remember per harness.

#### Rollout record

The record is the state that [Revision confirmation](#revision-confirmation), [Rollback](#rollback), and the smoke test read. It lives inside `<dist-root>` so that the distribution's own directory describes the account's install, and the update command appends to it.

```bash
record="${AGENT_HARNESS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness}/rollout.jsonl"
```

The command creates the file with mode 0600 if it is absent. Append one JSON object per rollout or rollback, after the switch and link verification succeed:

```json
{"at":"<ISO8601>","sha":"<installed-or-rolled-back-sha>","previous":"<last-record-sha|null>","pr":"<PR URL|null>"}
```

- `sha` is the verified installed or rolled-back revision, and `previous` is the revision that was served before the switch (`null` on the first line, and on a baseline line). The last line therefore always describes what is installed now.
- A rollback appends the revision it restored. Never rewrite or drop a line, so A → B → A leaves A last and revision confirmation keeps working.
- `pr` is the PR URL passed with `--pr`, or `null` when the step was run without one.
- Do not append before the smoke test passes. The command appends only after the release and the links verify; a merge alone appends nothing, because the served revision has not changed yet.
- A corrupt or unreadable record is not reset. Stop and report it. Restoring an older record is a manual decision.
- Read the current revision with `tail -1 "$record" | jq -r .sha` or, preferably, with `status`, which compares it to `current` for you.

#### Initial baseline

When the record is absent and a revision is already being served, the update command records that revision before switching:

1. It reads the revision from `current`, verifies that release tree, and appends it with `"previous": null`.
2. It then switches to the new revision and appends that line with `previous` set to the baseline.

With nothing served yet, the first rollout creates the first line with `"previous": null`. Do not create the record by hand.

#### Revision confirmation

All workspaces of one account share the same `<dist-root>`, so one command confirms the served revision and its consistency:

```bash
scripts/skill-distribution/dist.sh status
```

The command prints `revision=<sha>`, `release=ok|invalid|absent`, `record=<sha|none>`, `record-match=yes|no`, and `links=ok|drift|absent`, and exits non-zero unless a valid release is served, the last record line names it, and no link has drifted. `links=absent` means no link directory exists, which is a prepared-but-unlinked state rather than drift.

```bash
readlink -f "${AGENT_HARNESS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness}/current"
```

This proves the served tree, not what a long-running session loaded: a session's listing is from its startup or last `/reload`, while its on-demand reads follow `current`. An agent confirms its skill revision as follows:

1. Run the command above at the start of a skill-dependent task.
2. If the session has not been started or reloaded since the serving path last changed to that revision (the switch), run `/reload` (or restart the session) before relying on skill content; after the reload the loaded set matches the served revision.
3. Compare the revision against the `sha` of the last line of [the rollout record](#rollout-record) (`tail -1 "<rollout-record>" | jq -r .sha`).

Rollout and rollback make step 2 the normal state by reloading every running session as part of the procedure.

#### Rollback

```bash
scripts/skill-distribution/dist.sh rollback <previous-verified-sha> --pr <PR URL>
```

The command reuses the exported release and needs no network access; it gates the SHA against the mirror's last fetched `origin/main`, switches `current`, reconciles the links, verifies, and appends the record. Apply between tasks and `/reload` (or restart) every running session, as in rollout. Because the distribution is account-global, running the confirmation from any workspace verifies the state for all of them.

A SHA that is no longer on disk is fetched and gated first, so a rollback target must still be reachable from `origin/main`; a release that was pruned and whose commit left `main` cannot be restored. A revision older than `skills.json` cannot be served either, so the first rollout of this design also defines the oldest rollback target.

#### Smoke test

After every rollout and rollback:

```bash
set -e
export AGENT_HARNESS_HOME=<dist-root>
EXPECTED=<installed-or-rolled-back-sha>
scripts/skill-distribution/dist.sh verify --expect "$EXPECTED"
test -f <link-dir>/<any-served-skill>/SKILL.md
test -f <link-dir>/<any-served-skill>/../_docs/skill-distribution.md
```

`verify` re-reads the release's own `skills.json`, checks that every listed skill has a `SKILL.md`, that `current` names the expected SHA, that the record's last line names the same SHA, and that every per-skill link in `<link-dir>` resolves. It fails when no link directory exists; `--no-link` is the explicit way to verify a release that is not linked yet. Reading the manifest from the served tree rather than from `<checkout>` keeps a rollback validated against the revision being served.

As an end-to-end check, start a session in an unrelated workspace and confirm its skill listing contains the expected skills and no collision warning; a session started or reloaded after the switch is consistent by construction. Running sessions verify themselves: after their `/reload`, each runs the confirmation command and compares against the expected SHA.

## Compatibility and migration

### Harness scan paths

| Harness | Scan paths | Depth | How it sees `<dist-root>` | Status |
| --- | --- | --- | --- | --- |
| Pi | `~/.pi/agent/skills/`, `~/.agents/skills/`, project `.pi/skills/`, `.agents/skills/`, packages, the settings `skills` array, `--skill` | 2 | per-skill link in `~/.agents/skills` | measured 2026-11-18: one listing, no collision warning |
| Claude Code | `~/.claude/skills/` | 1 | per-skill link; a link to the distribution root is not discovered | measured 2026-11-18 |
| Codex CLI | unverified | unverified | add `--link-dir <codex skill directory>` once the discovery path is measured | unverified |

`~/.claude/skills` may be a symlink to `~/.agents/skills`; both paths then name one directory, and a single set of links serves both harnesses. Directory-level links and the pi package registration are the two mechanisms this design removes.

### Cutover from the pi package install

Order matters: the legacy package and the new links must not serve the same skill names at the same time, and a reload before the links resolve would load the old set. Stop on any failed step.

1. Merge the change that introduces this procedure, and apply the [rollout gate](#rollout) to the merged SHA.
2. Run the update with `--replace-links`, because the machine's existing per-skill links point at the pi-managed clone:

   ```bash
   scripts/skill-distribution/dist.sh update --sha <merged-sha> --replace-links --pr <PR URL>
   ```

   The command verifies the new release and links before reporting success, and it refuses to replace anything that is not a symlink.
3. Remove the legacy `agent-harness` leaf link if it exists (`unlink ~/.agents/skills/agent-harness`). It points at the pi clone and would expose a second, differently-resolved copy of every skill to Pi at two levels deep — a collision even when the per-skill links are correct.
4. Unregister the legacy pi package if `pi list` names it: `pi remove git:github.com/u7chan/agent-harness`. The pi-managed clone may be left in place; nothing serves from it once the registration is gone, and removing its files is optional.
5. `/reload` (or restart) every running session.
6. Run the [smoke test](#smoke-test) with `<merged-sha>`, then check one session's skill listing for the expected names and for the absence of a collision warning.
7. The command already appended the record line for `<merged-sha>`; verify it with `status` instead of appending another line.
8. Moved assets: the old record at `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/skill-distribution/rollout.jsonl` is history under the previous layout. Keep it as a record and start the new one under `<dist-root>`; do not append to both.

Emergency rollback inside the cutover window, before the pi registration is removed: re-register the previous pinned package (`pi install git:github.com/u7chan/agent-harness@<previous-served-sha>`) and remove the per-skill links with the Uninstall snippet in the README. After step 4, the previous pi-managed revision is no longer a valid rollback target because it predates `skills.json`; the oldest target is the revision this cutover serves.

## Non-goals

- Calling pi, claude, codex, or another harness CLI from the distribution command.
- Moving #130's delegation resolution rules into this boundary.
- Per-workspace or per-agent revision pinning as a supported mode.
- A per-harness manifest, a per-harness release, or per-harness copies of the skills.
- Reimplementing the pi package features (resource filters, enable/disable, per-package management).
- Automatic pruning of old releases; retention is a manual decision.
- Changes to the content or behavior of individual skills.
