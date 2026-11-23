# Development Profiles

Shared, user-owned development team settings for Pi and Claude. No skill owns
this asset: a consumer may be removed or renamed without changing the asset or
its helpers. The helpers live in `scripts/pi-development/`, outside every skill
directory. Commands below are package-root-relative; resolve them from the
loaded skill's parent directory, not from the repository being worked on.

## Name

`pi-development` names the user asset and the helper directory that owns it. It
does not name the Pi harness, and it does not name a skill: the profiles hold Pi
and Claude roles side by side, both workflow skills are harness-neutral, and the
helpers cover both harnesses. The asset name predates that boundary. It stays
because a rename would move every user's `profiles/*.json` and `active` again
([migration](pi-development-migration.md)).

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

The profile format holds the full team plus the optional orchestrator:

```json
{
  "pr_fix_shared_with_impl": false,
  "roles": {
    "impl": {"provider": "<provider>", "model": "<model>", "thinking": "<level>"},
    "review": {"harness": "claude", "model": "<model>", "effort": "<level>", "permission_mode": "<mode>"},
    "pr-fix": {"harness": "claude", "model": "<model>", "effort": "<level>", "permission_mode": "<mode>"},
    "orchestrator": {"provider": "<provider>", "model": "<model>", "thinking": "<level>"}
  }
}
```

`ui-tester` and `orchestrator` are optional. There is no version field. Unknown
keys are ignored. Full-team validation requires `impl`, `review`, `pr-fix`, a
boolean shared flag, and equal `impl`/`pr-fix` specifications when that flag is
true: every field is compared, so the harness and the Claude permission mode
are part of the equality. The example sets the flag to `false` because `impl`
and `pr-fix` use different harnesses; with `true`, `write` and `resolve` answer
`result=invalid reason=bad-shared` unless every field matches. Writes are atomic
(temporary file plus rename), mode
`0600`, for both profiles and `active`.

`harness` is optional and defaults to `pi`, so a profile written before the
harness existed is valid as it stands. The harness decides which fields a role
must and must not carry:

| `harness` | Required | Refused |
| --- | --- | --- |
| `pi` (default) | `provider`, `model`, `thinking` | `effort`, `permission_mode` |
| `claude` | `model`, `effort`, `permission_mode` | `provider`, `thinking` |

A Claude `effort` is one of `low`, `medium`, `high`, `xhigh`, `max`; `off` and
`minimal` are refused because the CLI ignores them with a warning instead of
applying them. A Claude `permission_mode` is one of `acceptEdits`, `auto`,
`manual`, `dontAsk`, `plan`; `bypassPermissions` is refused. A profile stores
the canonical full Claude model ID, never an alias: an alias is a one-off
explicit mode, and a stored alias stops the run when the launched model
reported by `effective:` does not match. `write` records `harness: "claude"`
for a Claude role and keeps the default harness implicit, so a Pi role keeps
its existing three-field shape.

`orchestrator` is not a team member: the team table, the approval, and the
reuse line never include it. It is stored in a profile because the same
canonical specification (the harness and that harness's fields) is what a
worktree team start resolves for the orchestrator.

Only team and orchestrator launch specifications belong here. Never persist a
run's PR, phase, review round, reviewed head, findings, or pane IDs.

## Role specifications

One canonical string names a role specification:

| Harness | Canonical form | Example |
| --- | --- | --- |
| Pi | `pi:<provider>/<model>/<thinking>` | `pi:opencode-go/deepseek-v4.1-flash/max` |
| Claude | `claude:<model>/<effort>/<permission_mode>` | `claude:claude-haiku-5-5/high/auto` |

Only a leading `pi:` or `claude:` is a harness prefix. Anything else is a
legacy Pi specification read from start to end, so a model ID that contains
`:` does not turn into a harness. A Pi value splits at the first `/`
(provider) and the last `/` (thinking); a Claude value splits at the last `/`
(permission mode) and the second-to-last `/` (effort). Both allow `/` in the
model ID. An empty segment, an unknown harness, a missing field for the named
harness, and a value outside the effort/permission vocabularies are rejected.

Commands accept both the prefixed and the legacy unprefixed form; every output
is prefixed. `--role`, the profile file, `resolve`, `launch:`, the reuse line,
and the team table all use the same string, and the permission mode is part of
the Claude string everywhere.

## Selection and commands

Resolution order is this run's explicit profile, then `active`, then `default`.
A missing `active` means `default`. An `active` that names a missing profile
never silently falls back to `default`.

```bash
# Full team: preserve the Issue workflow's validation contract.
scripts/pi-development/team-record.sh resolve [--profile <name>] [--require-role <role>]

# Role-only, read-only consumer: validate/resolve only review.
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review

# The same projection for an orchestrator launch spec.
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role orchestrator

# Persistent selection: validate the full team, then change only active.
scripts/pi-development/team-record.sh use <name>
# A dash-leading name needs the end-of-options terminator: use -- -fallback.

# Explicit full-team save: validate every supplied role; leave active alone.
# `write` replaces the whole profile, so pass every role you want to keep.
scripts/pi-development/team-record.sh write --profile <name> \
  --pr-fix-shared-with-impl <true|false> \
  --role impl=pi:<provider>/<model>/<thinking> \
  --role review=claude:<model>/<effort>/<permission_mode> \
  --role pr-fix=<harness>:<...> \
  [--role ui-tester=<harness>:<...>] \
  [--role orchestrator=<harness>:<...>]

# pi (default): exact match against the installed catalog.
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>

# claude: shape and enumeration only; the model is confirmed after launch.
scripts/pi-development/resolve-model-spec.sh --harness claude \
  --model <model> --effort <level> [--permission-mode <mode>]

# Authentication preflight: login state and config directory only.
scripts/pi-development/claude-auth-status.sh
```

**Claude permission mode.** A Claude request may omit `--permission-mode`. The
resolver then fills `CLAUDE_DEFAULT_PERMISSION_MODE` (`auto`), which is defined
only in `scripts/pi-development/lib/model-spec.mjs`; that module refuses to load
if the default is not in `CLAUDE_PERMISSION_MODES`. A caller that starts from a
profile applies a permission mode in this order:

1. the mode the user states,
2. the `permission_mode` of the same-harness resolved profile the run is based
   on,
3. `CLAUDE_DEFAULT_PERMISSION_MODE`.

Only step 3 fills an omitted value, and only when the harness is Claude and the
model and effort are present and valid. A missing or invalid model or effort
still stops the run. An
explicit empty `--permission-mode ""` is a usage error, not an omission. Naming
a harness other than the profile's replaces the profile base instead of mixing
fields, so a Pi profile never supplies a Claude value. Stored profiles still
require all three fields, and the launcher still requires a complete `--spec`:
the default exists at the resolver only.

A save that omits `orchestrator` removes a stored one, because `write` is a
full replacement. Pass `--role orchestrator=...` to keep it, and never drop a
stored role you did not mean to change.

`--only-role` accepts one known role. It projects the selected role before
shape validation and runtime resolution: missing, malformed, unavailable, or
clamped **unused** roles and the shared flag cannot block the run. The selected
role still needs a complete specification that the resolver answers with
`result=ok` (exactly for Pi, after launch for Claude). It cannot be combined
with `--require-role` or used with `use`/`write`. A full-team read, save, or
persistent switch still validates the whole team. A role-only read never
rewrites the profile or switches `active`.

A full-team `resolve` and `use` resolve the team roles (`impl`, `review`,
`pr-fix`, `ui-tester`) at runtime only. A stored `orchestrator` is
shape-validated and reported as a stored value, never resolved by those
commands: a retired or unauthenticated orchestrator model must not block the
team. The orchestrator spec is resolved when it is started
(`resolve --only-role orchestrator`). `--require-role <role>` also resolves the
required role, so `--require-role orchestrator` checks and resolves the stored
orchestrator on top of the team roles. `write` resolves every role it is given.

**Pi.** Use `pi --list-models` to inspect the live catalog; thinking-level
validation comes from the installed runtime's public API, never a static model
table. If `pi` on PATH is a launcher shim rather than the installed executable,
expose the real executable on PATH or pass the resolver's `--pi-root` option. Do
not interpret its catalog's thinking yes/no column as a supported-level list.
A Pi request must match an installed model exactly, and only `result=ok` with
`verification=exact` resolves it; never accept a clamped level silently.

**Claude.** A Claude request is checked by model shape and by the effort and
permission-mode vocabularies and answers `result=ok` with
`verification=postlaunch`: the model exists only after launch, so the resolver
keeps no alias table and reports no effective value. The launcher confirms the
canonical model and effort from the launched session, and the spec is settled
only when its `effective:` line matches. A request may omit `--permission-mode`;
the resolver fills the shared default, and the order under [Selection and
commands](#selection-and-commands) decides the value. An explicit empty value is
a usage error, never an omission. A canonical full model ID comes from
exactly three routes: a full ID the user states, a previous `effective:` line
for the same harness and model, or the canonical ID reported by an explicit
alias launch. Never infer one from the `claude --help` alias list.

`--harness` selects what the resolver verifies and defaults to `pi`. A record
that is not `result=ok` is unresolved for either harness.

`claude-auth-status.sh` runs `claude auth status`, which needs no network, and
prints only the login state and the config directory. It never prints the
account email, the organization, or the rest of the status document, and it
writes no file. It parses the status document with `node`, so `node` must be on
PATH; without it the helper answers `result=error reason=node-missing` and
exits 1.

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
hash, stored roles, and unknown keys, the harness vocabularies the editor
renders from, and the master with `status` (`ok`, `missing`, `invalid`),
`stale`, `stale_reason`, and its candidates. A stored role reports its
`harness` (`pi` when the key is absent) and only that harness's fields, so a
mixed team reads as one profile. The editor shows an optional-role toggle for
`ui-tester` and `orchestrator`: a profile without the role starts with the
toggle off, and a save that leaves it off omits the role (a full replacement
removes it).

`PUT /api/profile` takes `profile`, `expected_hash`,
`pr_fix_shared_with_impl`, and `roles`; it answers 200 with the write record,
400 for an invalid request, 404 for an unknown profile, 409 when the hash moved
(the file is untouched), 422 when `write` rejects the team, and 502 when the
helper cannot run. Omitting `ui-tester` or `orchestrator` removes it. A role in
the request carries `harness` and the fields of that harness only:
`provider`/`model`/`thinking` for `pi`, and
`model`/`effort`/`permission_mode` for `claude`. A field from the other
harness, an unknown harness, an incomplete or out-of-vocabulary
specification, and a Claude model that is not a canonical ID are all 400, so
nothing is silently dropped. The server renders each
`--role <role>=<harness>:<...>` from the same reader and formatter as the CLI
(`readRoleSpec` and `formatRoleSpec`) instead of concatenating a spec string
itself. `POST /api/models/refresh` runs the refresh helper, answers 200 with its
record, 500 when it fails, and 409 while a refresh is already running.

`GET /api/state` does not run `resolve`: a resolve boots the pi runtime and
costs seconds per profile, while the file view needs nothing it can add. The
authoritative record for a profile is the one `PUT` returns from `write`.

The editor chooses the harness per role. A Pi role keeps the model master and
the thinking levels; a Claude role takes the canonical full model ID as text,
plus the effort and permission-mode choices from the same vocabulary module the
resolver uses. A saved Claude model must already be canonical (for example
`claude-haiku-5-5`): an alias such as `haiku`, a provider-prefixed form, and an
unsupported level are refused with 400, because a profile start compares the
stored model with the launched `effective:` model and an alias cannot match it.
The CLI still accepts an alias for a one-off explicit launch; only the editor's
save path is strict. Switching a role's harness replaces its fields and clears
the values that belonged to the other harness. Existing Pi profiles load without
an edit and save in their existing three-field shape, and a mixed team saves and
reloads as one profile. A shared `pr-fix` copies the whole role, including the
harness and the Claude permission mode, so the equality `write` checks holds.

`ui-tester` is Pi-only in the workflow, so a save that selects Claude for it is
refused with 400 (`roles.ui-tester must use pi`). The editor keeps the harness
selector visible for every role and enforces the rule on save instead of
changing the layout.

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

Run the editor from `<dist-root>/current`, the release tree that already serves
the skills, so the service and the skills share one revision. Never edit that
tree: its revision changes only through the rollout procedure in
[skill-distribution.md](skill-distribution.md).

```ini
[Unit]
Description=Development profile model editor
After=network.target

[Service]
Type=simple
Environment=PATH=<node-bin-dir>:<pi-bin-dir>:/usr/local/bin:/usr/bin:/bin
Environment=PI_CODING_AGENT_DIR=%h/.pi/agent
ExecStart=<node> <dist-root>/current/scripts/pi-development/web/server.mjs
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
# After a rollout or rollback of <dist-root>:
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
roles, plus `pr_fix_shared_with_impl` for a full-team read only. A full-team
read and `use` report a stored `orchestrator=` as a shape-validated value from
the file, not a runtime resolution, while the team roles in the same line are
resolved. Every role value is the canonical string, so `impl=pi:...` and
`review=claude:<model>/<effort>/<permission_mode>` are unambiguous about the
harness and the permission mode. `--only-role <role>` reports the canonical
value for the selected role and resolves only that role. Invalid and unresolved
records repeat the stored role values in the same form, including
`orchestrator=` when the file has one; `use` reports the stored `orchestrator=`
the same way.

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

## Launch and effective lines

This section is the single authoritative definition of both lines. The start
scripts, workflow skills, and references state which step reads a line; they do
not define its fields again.

A start script prints one `launch:` line before it starts an agent and appends
the same line to the delegated body. The canonical line names the harness
explicitly:

```text
launch: profile=<name|-> role=<role|-> harness=<pi|claude> spec=<harness>:<...> spec_source=<profile|explicit> origin=<explicit|active|default>
```

Two invariants decide whether a line is usable:

- `harness` must equal the prefix of `spec`. A mismatch stops the start instead
  of launching an agent whose specification cannot be verified.
- When a body holds several `launch:` lines, the last one is authoritative.

The shared launcher `herdr/scripts/start-agent.sh` prints the line and starts
the agent; `herdr/scripts/worktree-team-start.sh` appends the lines the launcher
reported. An accepted input without a prefix is read as Pi and printed in the
canonical `pi:` form, so every printed value is prefixed.

The effective values are reported once after launch:

```text
effective: harness=<pi|claude> provider=<provider|-> model=<canonical model> effort=<level|-> thinking=<level|-> permission_requested=<mode|-> requested=<spec>
```

The shared launcher prints this line for both harnesses. Pi writes its session
record on the first turn, so the launcher sends one minimal startup probe when
the record is absent and then reads the first `model_change` (`provider` /
`modelId`) and `thinking_level_change` (`thinkingLevel`) entries of the record
Herdr reports as `agent_session` with `kind=path`. The path lookup, the probe,
and the read share one deadline; an absent, unreadable, or incomplete initial
entry, or a value that differs from `spec`, stops the launch. `$PI_*` is not
used. The probe stays in the session and the delegated task follows it. For
Claude, the launcher reads the launched session's statusline, and
`permission_requested` is the value passed in argv, not a value read back
(Claude does not expose the merged permission mode). `requested=` must equal the
`spec` of the `launch:` line, and a stored canonical model ID must match
`model`. When a body holds several `effective:` lines, the last one is
authoritative.
