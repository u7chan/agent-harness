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
  models.json                  # optional; model master for the local editor
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

Use `pi --list-models` to inspect the live catalog; thinking-level validation
comes from the installed runtime's public API, never a static model table. If `pi`
on PATH is a launcher shim rather than the installed executable, expose the
real executable on PATH or pass the resolver's `--pi-root` option. Do not
interpret its catalog's thinking yes/no column as a supported-level list.
Only `result=ok` resolves a spec; never accept a clamped level silently.

A request such as `fallback で` selects `--profile fallback` for this run only.
`fallback に切り替えて` is `use fallback` and persists for both consumers.
Ordinary runs and run-local overrides never save settings. Bootstrap and
approval decisions belong to each consuming workflow, not to the helper.

## Local editor and model master

A local web editor edits these profiles from a browser on the same machine. It
is a thin wrapper over the helpers above: reads call `resolve`, saves call
`write`, and the server never writes a profile itself. The server holds no
state; the JSON files are the only state. It has no UI automated test, and its
interface uses no external resource and no build step.

```bash
# Serve the editor. It binds 127.0.0.1 only.
scripts/pi-development/web/server.mjs [--port <port>]
# Refresh the model master from the installed pi catalog.
scripts/pi-development/refresh-models.sh [--pi-root <pi-package>] [--out <file>]
```

`GET /` serves the document. `GET /api/state` returns every profile with its
hash, stored roles, and unknown keys, plus the master with
`status` (`ok`, `missing`, `invalid`), `stale`, `stale_reason`, and its
candidates. `PUT /api/profile` takes `profile`, `expected_hash`,
`pr_fix_shared_with_impl`, and `roles`; it answers 200 with the write record,
400 for an invalid request, 404 for an unknown profile, 409 when the hash moved
(the file is untouched), 422 when `write` rejects the team, and 502 when the
helper cannot run. Omitting `ui-tester` removes it. `POST /api/models/refresh`
runs the refresh helper, answers 200 with its record, 500 when it fails, and
409 while a refresh is already running.

`GET /api/state` does not run `resolve`: a resolve boots the pi runtime and
costs seconds per profile, while the file view needs nothing it can add. The
authoritative record for a profile is the one `PUT` returns from `write`.

The hash guard detects a change up to the moment it is compared. A `write` from
another process between the comparison and the rename wins; the CLI contract
gains no expected-hash argument, so the editor does not promise more than that.

`Host` must be `localhost:<port>` or `127.0.0.1:<port>`. A browser `Origin` is
parsed rather than compared with `Host`: it must be `http`, name
`localhost`/`127.0.0.1`, and carry the listening port. An absent `Origin` is a
non-browser client and is allowed. Any other value is 403.

The master is a cache, not an authority: a save is always validated against the
live catalog, so a stale master can only hide a candidate. It is written
atomically with mode `0600`, and a failed or empty refresh leaves the previous
file in place. Required keys are `generated_at`, `pi_version`,
`providers[].id`, `providers[].models[].id`, and
`providers[].models[].supported_thinking`; `context_window`, `max_tokens`,
`images`, and `thinking_level_map` are optional.

```json
{
  "generated_at": "<ISO 8601 UTC>",
  "pi_version": "<pi --version>",
  "providers": [
    {"id": "<provider>", "models": [
      {"id": "<model>", "supported_thinking": ["high", "max"],
       "context_window": 256384, "max_tokens": 128000, "images": true,
       "thinking_level_map": {"off": null, "minimal": "low"}}
    ]}
  ]
}
```

A master is stale when `pi_version` differs from the running `pi --version` or
`generated_at` is more than 30 days old. The editor shows a badge and offers a
refresh button; it never refreshes on its own. Refreshing is a manual step, for
example after `pi update` or a login change, because the candidate list depends
on the authenticated providers.

### Run as a service

Run the editor from the pinned `<clone>` that already serves the skills, so the
service and the skills share one revision. Never `checkout` or `pull` that
clone: its revision changes only through the rollout procedure in
[skill-distribution.md](skill-distribution.md).

```ini
[Unit]
Description=Development profile model editor
After=network.target

[Service]
Type=simple
Environment=PATH=<node-bin-dir>:<pi-bin-dir>:/usr/local/bin:/usr/bin:/bin
Environment=PI_CODING_AGENT_DIR=%h/.pi/agent
ExecStart=<node> <clone>/scripts/pi-development/web/server.mjs
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

`PATH` must contain `node` and `pi`: the editor runs `team-record.sh`, which
resolves both from `PATH`. Install and update the service, then restart it
after every rollout and rollback; the service keeps running the installed
revision until it restarts.

```bash
systemctl --user daemon-reload
systemctl --user enable --now <unit>
# After a rollout or rollback of <clone>:
systemctl --user restart <unit>
```

On WSL, the unit starts with the distribution, not with Windows. Start the
distribution at logon (for example a logon task running
`wsl.exe -d <distro> -- true`) and keep `Restart=always` as the recovery path;
check `systemctl --user status <unit>` after a failure.

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
