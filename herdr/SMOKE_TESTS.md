# Herdr Smoke Tests

## Prerequisites

```bash
command -v jq >/dev/null
```

## Mock Smoke Tests (no Herdr required)

Uses a fake `herdr` CLI (`herdr/tests/fake_herdr.sh`) for fast, offline testing of all actions.
Tests run under a temporary `XDG_STATE_HOME` to avoid any interference with real manifest data.

```bash
cd /path/to/global-agent-skills
bash herdr/tests/smoke.sh
```

## Live Smoke Tests (requires Herdr)

Requires a running Herdr environment with `HERDR_ENV=1` and an active agent pane.
Tests run under a temporary `XDG_STATE_HOME` to avoid deleting or interfering with existing team manifests.

```bash
cd /path/to/global-agent-skills
HERDR_ENV=1 bash herdr/tests/live-smoke.sh
```

⚠️ **Caution**: The live test creates real Herdr panes and agents. All resources are cleaned up automatically via `team.stop`.
Manifests are stored under a temporary `XDG_STATE_HOME` and cleaned up on exit.

## Test Coverage

### Mock smoke tests

| Category | Checks |
|----------|--------|
| Catalog | `actions.list` returns action array, `actions.describe` returns definition |
| Validation | Unknown action, unknown fields, missing input, type mismatch, invalid JSON |
| Envelope | All required fields present (`schema_version`, `status`, `action`, `actor`, `target`, `data`) |
| Team lifecycle | `team.start` creates team, `team.get` returns manifest, `team.list` returns workspace-filtered array, `team.stop` verifies closes before cleanup |
| Member operations | `member.prompt` sends prompt, `member.wait` returns status, `member.read` returns output, `member.close` verifies close outcome |
| Agent naming | Per-member `kind` used for agent start, agent names use `<kind>-<role>-<short-team-id>`, pane display names set |
| Deferred activation | First prompt to deferred member includes role prompt + kickoff context, second prompt does not repeat them |
| Idempotency | Duplicate `request_id` returns `already_applied`, close on closed returns `already_applied` |
| Grant rejection | Write action with `read` grant fails with `GRANT_INSUFFICIENT` |
| Error handling | `team.get` on nonexistent team returns `NOT_FOUND` |
| Config | Default config fallback when no config files exist, member validation |

### Live smoke tests

| Category | Checks |
|----------|--------|
| Preflight | `herdr pane current` returns a valid pane with `pane_id` |
| Catalog | `actions.list`, `actions.describe` |
| Team lifecycle | `team.start` creates real panes, `team.stop` closes them, both idempotent |
| Member operations | Prompt, wait, read on real agents, defer activation, close with verification |
| Idempotency | Verified on live `team.start`, `team.stop`, and `member.close` |
| Validation | Unknown action, missing input |

## Troubleshooting

### Mock tests fail with "jq: command not found"

```bash
sudo apt-get install jq   # Debian/Ubuntu
brew install jq            # macOS
```

### Live tests skip with "HERDR_ENV is not set"

The live smoke test requires running inside a Herdr workspace. Set `HERDR_ENV=1` or run from a Herdr pane.

### Live tests fail with "Cannot determine current workspace"

Ensure `herdr pane current` returns a valid result with a `workspace_id`.

### team.start fails partway

If `team.start` fails after creating some panes, the remaining panes are automatically rolled back (unless `keep_on_failure: true` was set). Check `herdr pane list` for orphaned panes and close them manually if needed.

### Manifest cleanup

Both mock and live smoke tests use temporary `XDG_STATE_HOME` directories. No cleanup of real manifest data is needed.
The test state directories are removed automatically via `trap` on exit. To check for leftover temp dirs:

```bash
ls -la /tmp/herdr-*-state-*
```
