# Pi Development Profiles

Shared, user-owned development team settings. No skill owns this asset: a
consumer may be removed or renamed without changing the asset or its helpers.
The helpers live in `scripts/pi-development/`, outside every skill directory.
Commands below are package-root-relative; resolve them from the loaded skill's
parent directory, not from the repository being worked on.

## Storage

```text
${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/pi-development/
  profiles/<name>.json
  active                       # optional; one profile name
```

Profiles are not distributed with the skills. A name matches
`^[A-Za-z0-9._-]+$`, is neither `.` nor `..`, and is passed without `.json`.
`active` contains one name with at most one trailing newline.

The full-team format is unchanged:

```json
{
  "pr_fix_shared_with_impl": true,
  "roles": {
    "impl": {"provider": "<provider>", "model": "<model>", "thinking": "<level>"},
    "review": {"provider": "<provider>", "model": "<model>", "thinking": "<level>"},
    "pr-fix": {"provider": "<provider>", "model": "<model>", "thinking": "<level>"}
  }
}
```

`ui-tester` is optional. There is no version field. Unknown keys are ignored.
Full-team validation requires `impl`, `review`, `pr-fix`, a boolean shared flag,
and equal `impl`/`pr-fix` specs when that flag is true. Writes are atomic
(temporary file plus rename), mode `0600`, for both profiles and `active`.

Only team specifications belong here. Never persist a run's PR, phase, review
round, reviewed head, findings, or pane IDs.

## Selection and commands

Resolution order is this run's explicit profile, then `active`, then `default`.
A missing `active` means `default`. An `active` that names a missing profile
never silently falls back to `default`.

```bash
# Full team: preserve the Issue workflow's validation contract.
scripts/pi-development/team-record.sh resolve [--profile <name>] [--require-role <role>]

# Role-only, read-only consumer: validate/resolve only review.
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review

# Persistent selection: validate the full team, then change only active.
scripts/pi-development/team-record.sh use <name>
# A dash-leading name needs the end-of-options terminator: use -- -fallback.

# Explicit full-team save: validate every supplied role; leave active alone.
scripts/pi-development/team-record.sh write --profile <name> \
  --pr-fix-shared-with-impl <true|false> \
  --role impl=<provider>/<model>/<thinking> \
  --role review=<provider>/<model>/<thinking> \
  --role pr-fix=<provider>/<model>/<thinking> \
  [--role ui-tester=<provider>/<model>/<thinking>]

scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

`--only-role` accepts one known role. It projects the selected role before
shape validation and runtime resolution: missing, malformed, unavailable, or
clamped **unused** roles and the shared flag cannot block a review-only run.
The selected role still needs a complete, exact, supported spec. It cannot be
combined with `--require-role` or used with `use`/`write`. A full-team read,
save, or persistent switch still validates the whole team. A role-only read
never rewrites the profile or switches `active`.

Use `pi --list-models` for the live catalog; thinking-level validation comes
from the installed runtime's public API, never a static model table. If `pi`
on PATH is a launcher shim rather than the installed executable, expose the
real executable on PATH or pass the resolver's `--pi-root` option. Do not
interpret its catalog's thinking yes/no column as a supported-level list.
Only `result=ok` resolves a spec; never accept a clamped level silently.

A request such as `fallback で` selects `--profile fallback` for this run only.
`fallback に切り替えて` is `use fallback` and persists for both consumers.
Ordinary runs and run-local overrides never save settings. Bootstrap and
approval decisions belong to each consuming workflow, not to the helper.

## Output and failure contract

Each helper prints one key=value line and exits zero only for `result=ok`.
`resolve` includes `profile`, `source` (`explicit`, `active`, `default`),
`record`, `profiles_present`, `present`, and `result`. Success adds the resolved
roles, plus `pr_fix_shared_with_impl` for a full-team read only.

Missing reasons: `no-profiles`, `missing-selected-profile`,
`missing-active-profile`, `missing-explicit-profile`. Invalid reasons include
`bad-active`, `bad-profile-name`, `bad-json`, `bad-record`, `bad-shared`,
`bad-roles`, `missing-role`, `bad-role-spec`, and `unreadable`.
An unresolved runtime spec reports the `unresolved` role and
`unresolved_result`. A required absent role is unresolved, never silently
omitted. `--resolver <path>` allows hermetic tests without an installed Pi.

When `profiles/` cannot be read reliably (including a `.json` entry that cannot
be inspected), `profiles_present` is empty and the result is invalid, not
`no-profiles`. An unreadable `active` or profile file is invalid too, never
absent. Callers must not bootstrap on an invalid or unknown result.

An old `pi-issue-pr-workflow/` asset with no profiles at the new location is
`invalid reason=migration-required`, with an unknown `profiles_present` on
resolve. Reads never fall back to it, and writes/switches stop too. Follow
[the migration procedure](pi-development-migration.md) before continuing; an
empty new directory does not waive the guard. Once migrated, only the new
location is authoritative.
