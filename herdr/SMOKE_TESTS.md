# Herdr Smoke Tests

## Prerequisites

```bash
command -v jq >/dev/null
```

## Mock Smoke Tests (no Herdr required)

Uses a fake `herdr` CLI (`herdr/tests/fake_herdr.sh`) for fast, offline testing of all actions.

```bash
cd /path/to/global-agent-skills
bash herdr/tests/smoke.sh
```

## Live Smoke Tests (requires Herdr)

Requires a running Herdr environment with `HERDR_ENV=1` and an active agent pane.

```bash
cd /path/to/global-agent-skills
HERDR_ENV=1 bash herdr/tests/live-smoke.sh
```

⚠️ **Caution**: The live test creates real Herdr panes and agents. All resources are cleaned up automatically via `team.stop`.

## Test Coverage

### Mock smoke tests

| Category | Checks |
|----------|--------|
| Catalog | `actions.list` returns action array, `actions.describe` returns definition |
| Validation | Unknown action, unknown fields, missing input, type mismatch, invalid JSON |
| Envelope | All required fields present (`schema_version`, `status`, `action`, `actor`, `target`, `data`) |
| Team lifecycle | `team.start` creates team, `team.get` returns manifest, `team.list` returns array, `team.stop` cleans up |
| Member operations | `member.prompt` sends prompt, `member.wait` returns status, `member.read` returns output, `member.close` closes pane |
| Idempotency | Duplicate `request_id` returns `already_applied`, close on closed returns `already_applied` |
| Grant rejection | Write action with `read` grant fails with `GRANT_INSUFFICIENT` |
| Error handling | `team.get` on nonexistent team returns `NOT_FOUND` |
| Config | Default config fallback when no config files exist |

### Live smoke tests

| Category | Checks |
|----------|--------|
| Preflight | `herdr pane current` succeeds |
| Team lifecycle | `team.start` creates real panes, `team.stop` closes them |
| Member operations | Prompt, wait, read on real agents |
| Idempotency | Verified on live `team.start` and `team.stop` |
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

Test manifests are stored at `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams/`. All smoke tests clean up after themselves. To manually clean:

```bash
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams"
```
