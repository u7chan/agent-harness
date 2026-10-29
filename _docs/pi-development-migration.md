# Pi Development Profile Migration

One-time manual migration of the user-owned team profiles. No automatic
migration or legacy read/write fallback is shipped.

## Timing

For operational use, run this between tasks as part of the merged revision's
[rollout](skill-distribution.md), before using the updated workflows. Install
the pinned merged revision, migrate the settings, reload all sessions, then
smoke-test both the installed revision and the profiles. Do not leave old
sessions writing the old location after the cutover.

Before merge, follow [skill testing](skill-testing.md) and copy the settings
into a temporary agent directory for session-scoped verification. Do not move
the operational asset or install an unmerged revision for a test.

## Procedure

The old root is `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow/`;
the new root is `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-development/`.
`profiles/*.json`, every role value, and the optional `active` are preserved.

1. Stop workflow writes and back up the entire old root. Check that the new
   destination does not already exist; if both roots exist, stop and inspect
   them rather than merging or overwriting either one.

   ```bash
   set -e
   AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
   OLD="$AGENT_DIR/pi-issue-pr-workflow"
   NEW="$AGENT_DIR/pi-development"
   BACKUP="$OLD.bak-$(date +%Y%m%d%H%M%S)"
   test -d "$OLD/profiles"
   test ! -L "$OLD"
   test ! -e "$NEW" && test ! -L "$NEW"
   test ! -e "$BACKUP" && test ! -L "$BACKUP"
   cp -a "$OLD" "$BACKUP"
   ```

2. Move the root once; do not rewrite the JSON or recreate `active`. The
   backup remains at its timestamped path. Ensure every profile and the
   optional `active` has mode `0600`.

   ```bash
   mv "$OLD" "$NEW"
   chmod 700 "$NEW" "$NEW/profiles"
   find "$NEW/profiles" -maxdepth 1 -type f -name '*.json' -exec chmod 600 {} +
   if test -f "$NEW/active"; then chmod 600 "$NEW/active"; fi
   ```

3. Run the new helper from `<clone>` (the pinned clone in
   [Notation](skill-distribution.md#notation)). Resolve every kept profile as a
   full team, then resolve the effective review role. Only `result=ok` passes;
   if any check fails, stop before workflow execution and inspect the model
   catalog or restore the backup. Do not replace approved model values with
   defaults to make the migration pass.

   ```bash
   for profile in "$NEW"/profiles/*.json; do
     test -f "$profile"
     name="${profile##*/}"
     scripts/pi-development/team-record.sh resolve --profile "${name%.json}"
   done
   scripts/pi-development/team-record.sh resolve
   scripts/pi-development/team-record.sh resolve --only-role review
   ```

   `active` is optional. With no `active`, the effective profile is `default`.
   Do not use `use` during migration: preserving the existing selection, not
   choosing another profile, is the goal.

4. Reload all sessions and complete the distribution smoke test. Keep the
   backup until both workflows have been verified against the new location.

## Rollback

Installing an older skill revision restores the skill revision only, not user
assets. Stop workflow writes, separately back up the current `pi-development`
root, then put the original backup back at `pi-issue-pr-workflow` without
overwriting another root. Reload every session after restoring the old pinned
revision and settings. Never run both revisions against divergent live copies.

## Older per-repository records

If the old root still has `teams/<key>.json` instead of `profiles/`, back it up
first and manually map each wanted record to a named `profiles/<name>.json`.
Names now describe compositions, not repositories; the mapping is a user
decision. A leftover `version` key is ignored and may be removed manually.
Set mode `0600`, preserve or explicitly choose the effective profile, and
validate every kept profile before deleting `teams/` or performing the root
migration above. There is no automatic mapping or migration code.
