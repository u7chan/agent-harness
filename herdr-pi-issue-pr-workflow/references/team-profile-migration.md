# Team profile migration

Manual procedure for moving the previous per-repository team records to the
named profiles of [Team profiles](../SKILL.md#team-profiles). No migration code
exists: the helper takes a profile name, not a record key, and it never reads
the old layout.

## Before you start

The old layout stored one record per repository:

```text
${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow/
  teams/<key>.json
```

The new layout stores named profiles and an optional `active`:

```text
${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow/
  profiles/default.json
  profiles/fallback.json
  active                      # optional; one profile name
```

## Procedure

1. Back up the whole user asset before touching it. The backup is the only
   rollback source for the records, because restoring a skill revision does not
   restore user assets:

   ```bash
   ASSET="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-issue-pr-workflow"
   cp -a "$ASSET" "$ASSET.bak-$(date +%Y%m%d%H%M%S)"
   ```

2. Create `profiles/` and copy each record into it under the profile name you
   want. The mapping is a user decision: the records were keyed by repository,
   the profiles are keyed by composition. One machine's example is
   `u7chan__agent-harness.json` → `profiles/default.json` and
   `u7chan__monorepo.json` → `profiles/fallback.json`.

3. Remove the `version` key from each copied file. The new reader ignores
   unknown keys, so a leftover `version` is harmless, but the profile format no
   longer carries one.

4. Set mode `0600` on every file you created by hand, because it did not go
   through the helper's atomic `0600` write:

   ```bash
   chmod 600 "$ASSET"/profiles/*.json
   ```

5. Check that each profile resolves with the new helper. Only `result=ok` is
   usable, and every role of the profile must resolve:

   ```bash
   herdr-pi-issue-pr-workflow/scripts/team-record.sh resolve --profile default
   herdr-pi-issue-pr-workflow/scripts/team-record.sh resolve --profile fallback
   ```

6. Delete `teams/` only after every profile you kept resolves:

   ```bash
   rm -r "$ASSET"/teams
   ```

7. `active` is optional: without it, runs use `default`. Write it only when
   `default` is not the profile you want a run to start from:

   ```bash
   herdr-pi-issue-pr-workflow/scripts/team-record.sh use fallback
   ```

   `use` validates every role and writes `active` atomically with mode `0600`.

## Choosing the profiles

- `default` is a convention, not a required name: any profile name works, and
  `active` selects the one runs start from.
- Whether `default` carries a `ui-tester` is a user decision. The profile keeps
  whatever the copied record held; a run whose participation decision excludes
  the role omits it from that run without rewriting the profile, and a run that
  includes it needs the role in the profile.

## Rollback

Rolling the skill back with [_docs/skill-distribution.md](../../_docs/skill-distribution.md)
restores the skill revision only; it does not restore user assets. Restoring
the old records is a separate step: put the backup from step 1 back, so
`teams/` exists again before the rolled-back skill runs. `profiles/` and
`active` are inert to the old version, so they may stay, or be removed when the
asset should hold one layout only.
