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

⚠️ **Caution**: The live test creates real Herdr panes and agents. Its EXIT cleanup
collects team IDs and exact pane IDs from both manifests and the before/after pane
diff. Temporary state is deleted only after every created pane is confirmed closed.
If cleanup is failed or unknown, the state directory is retained for retry and the
test fails. An externally supplied `HERDR_TEMP_DIR` is only a parent; it is never
deleted.

## Test Coverage

### Mock smoke tests

| Category | Checks |
|----------|--------|
| Catalog | `actions.list` returns action array, `actions.describe` returns definition |
| Validation | Unknown action/fields, missing input, invalid JSON, strict config types/schema/control characters, unsafe IDs, fractional timeout |
| Envelope | Required fields and exactly one JSON document on every tested success/failure/unknown path |
| Team lifecycle | Start/get/list/stop, full start deadline, ready retry, rollback, unknown pane persistence, cross-workspace request IDs |
| Member operations | Prompt state machine, wait/read real-envelope classification, failed/unknown close retries, partial stop retries |
| Agent naming | Per-member `kind` used for agent start, agent names use `<kind>-<role>-<short-team-id>`, pane display names set |
| Deferred activation | First prompt to deferred member includes role prompt + kickoff context, second prompt does not repeat them |
| Idempotency | True parallel start/prompt (`&`, PID, `wait`), one external send, in-flight crash window, close target state |
| Grant rejection | Write action with `read` grant fails with `GRANT_INSUFFICIENT` |
| Error handling | `team.get` on nonexistent team returns `NOT_FOUND` |
| Config | Strict raw schema and types, canonical paths/symlink boundary, immutable prompt snapshots, lock release on all errors |
| Safety | External temp sentinel preservation, owned temp cleanup, unowned cleanup rejection, exact lock timing |

### Live smoke tests

| Category | Checks |
|----------|--------|
| Preflight | `herdr pane current` returns a valid pane with `pane_id` |
| Catalog | `actions.list`, `actions.describe` |
| Team lifecycle | `team.start` creates tracked panes and cleanup removes exact created pane IDs |
| Member operations | Deferred prompt, wait, and read on real agents |
| Cleanup | Manifest recovery when start output is unavailable, before/after pane diff, retained state on failed/unknown cleanup |

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

Both mock and live smoke tests use dedicated temporary `XDG_STATE_HOME`
directories. Mock state is removed on exit. Live state is removed only after pane
cleanup is confirmed; otherwise the retained path is printed for manual recovery.
To check for leftover temp dirs:

```bash
ls -la /tmp/herdr-*-state-*
```
