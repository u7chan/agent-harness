---
name: herdr
description: Start and prompt coding agents in adjacent Herdr panes. Use when asked to delegate work to another agent (review, implement, check) via Herdr. Supports team orchestration with impl→review→pr-fix loop.
---

# Herdr

Use `herdr.sh` as the single dispatcher for all Herdr team operations.

```bash
herdr/scripts/herdr.sh <action-name> [json-input-file]
```

## Action Index

| Intent | Action | Permission |
|--------|--------|------------|
| List all available actions | `actions.list` | read |
| Describe an action's schema | `actions.describe` | read |
| List active teams | `team.list` | read |
| Start a new team | `team.start` | write |
| Get team manifest | `team.get` | read |
| Stop team and close panes | `team.stop` | sensitive-write |
| Send prompt to a member | `member.prompt` | write |
| Wait for member to finish | `member.wait` | read |
| Read member output | `member.read` | read |
| Close a member's pane | `member.close` | sensitive-write |

## Permission

- `read` — No side effects. Read-only access.
- `write` — Creates or modifies Herdr panes and agents. Requires confirmed intent from the user.
- `sensitive-write` — Destructive operations (close panes, stop teams). Requires explicit user confirmation.

## Team Orchestration

### Quick start

```bash
# Start a team with default config (impl + review + pr-fix, same agent kind as current)
echo '{"request_id":"run-001","grant":"write"}' | bash herdr/scripts/herdr.sh team.start

# Start with explicit config and kickoff context
echo '{"request_id":"run-002","config_path":".herdr/team.json","kickoff_context":{"issue":"43","base":"main","work_branch":"feat/my-feature"},"grant":"write"}' | bash herdr/scripts/herdr.sh team.start

# Prompt a member
echo '{"request_id":"msg-001","team_id":"opencode-1712345678-abcd","role":"impl","text":"Implement issue #43","grant":"write"}' | bash herdr/scripts/herdr.sh member.prompt

# Wait for a member
echo '{"team_id":"opencode-1712345678-abcd","role":"impl"}' | bash herdr/scripts/herdr.sh member.wait

# Read member output
echo '{"team_id":"opencode-1712345678-abcd","role":"impl","lines":200}' | bash herdr/scripts/herdr.sh member.read

# Close a member
echo '{"team_id":"opencode-1712345678-abcd","role":"impl","grant":"sensitive-write"}' | bash herdr/scripts/herdr.sh member.close

# Stop full team
echo '{"team_id":"opencode-1712345678-abcd","grant":"sensitive-write"}' | bash herdr/scripts/herdr.sh team.stop
```

### Config

Config is resolved in order:
1. Explicit `config_path` in the request
2. Nearest `.herdr/team.json` from cwd up to git root
3. `${XDG_CONFIG_HOME:-$HOME/.config}/herdr/team.json`
4. Skill-bundled default (`herdr/team.json`)

Config files are not merged. The first match wins.

Example `.herdr/team.json`:

```json
{
  "schema_version": 2,
  "layout": {
    "max_cols": 3
  },
  "members": [
    {"role": "impl", "kind": "opencode", "activation": "immediate"},
    {"role": "review", "kind": "codex", "activation": "deferred"},
    {"role": "pr-fix", "kind": "opencode", "activation": "deferred"}
  ]
}
```

`schema_version: 2` and `layout.max_cols` are required. `max_cols` is an integer from 1 to 3; unknown fields, the v1 schema, and stack layout settings are rejected.

When kind is omitted, the origin agent kind is inherited. When activation is omitted, `impl` defaults to `immediate` and all others to `deferred`.

### Agent naming

Agents are named `<kind>-<role>-<short-team-id>`. Pane display names are `<role> [<kind>]`.

### Rollback on failure

If `team.start` fails after a confirmed write, confirmed created panes are closed in reverse order. Set `keep_on_failure: true` to preserve them for debugging. A layout with an unknown outcome is retained and is never automatically closed or retried.

### Safe-stop on team.start

`team.start` の応答statusに応じて、オーケストレーターは以下の通り動作する:

| status | 動作 |
|--------|------|
| `"ok"` | 通常フロー継続。`data.start_prompt_status` が `"unknown"` の場合、impl が kickoff を受け取っていない可能性があるため、最初の `member.prompt` で改めて指示を送る。 |
| `"already_applied"` | `team.get` で既存teamの状態を確認し、起動済みで継続可能な場合のみ続行 |
| `"failed"` | 実装を開始しない。エラー情報をユーザーに報告する。rollback結果を尊重する。 |
| `"unknown_outcome"` | 実装を開始しない。自動再実行しない。後続のwrite操作に進まない。read-only操作のみ許可。ユーザーの指示を待つ。 |

`"failed"` または `"unknown_outcome"` の場合:
- オーケストレーターが親エージェントとして直接実装にフォールバックしてはならない
- `team.stop` / `member.close` を自動実行してはならない（sensitive-write grant を自己判断で付与しない）
- 未確認の失敗原因を断定してはならない
- 以下の情報をユーザーに報告する: `team_id`、発生phase、対象role、各memberのstatus、error詳細

### Idempotency

- `team.start` and `member.prompt` require a `request_id`. Duplicate `request_id` returns `already_applied`.
- Close operations (`member.close`, `team.stop`) are target-state idempotent — closing an already-closed resource returns `already_applied`.
- Prompt delivery records `in_flight`, `succeeded`, `failed`, or `unknown` before and after the external call. `in_flight`/`unknown` are never resent automatically; an explicit failure remains retryable.

### Workspace binding

Team manifests are bound to the `workspace_id` that created them. Operations from a different workspace are rejected with `WORKSPACE_MISMATCH`.

### Timeouts

- `team.start`: default 30s, max 300s; one deadline covers capability checks, layout snapshots, pane split/get, and agent start/rename. Kickoff prompt has a dedicated minimum 10s timeout, decoupled from the overall deadline.
- `member.prompt`: default 30s, max 300s
- `member.wait`: default 60s, max 60s (returns `waiting` on timeout, not an error)

### Manifest storage

Manifests are stored at `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams/<team-id>.json`. They hold only Herdr infrastructure state (pane IDs, agent names, activation status) — not PR workflow state.

## Orchestrator Workflow

The orchestrator prompt for the agent that drives the team is maintained in
`prompts/orchestrator.md`. Load that file and replace its `#{issue}` placeholder
before starting orchestration. Agent kind and pane configuration are resolved by
`team.start`, not hardcoded in the prompt.

## Role Prompts

Standard role prompts are bundled in `herdr/prompts/`:

- `prompts/orchestrator.md` — Team orchestration workflow
- `prompts/impl.md` — Issue implementation role
- `prompts/review.md` — Code review role
- `prompts/pr-fix.md` — PR fix role

Each role returns a structured JSON report in its final response.

## Grid Layout

`team.start` reads the current pane identity from `HERDR_PANE_ID`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID`. It plans the entire Grid before issuing a split. The orchestrator remains on the left at a preferred 25% width (with a 48-column minimum); members occupy the right side with at most three columns, 60 columns per member, and 12 rows per member.

The planner is deterministic and has no Herdr, manifest, time, or random dependencies. It assigns logical refs such as `orch`, `member-root`, `row-0`, and `member-0` before applying them to real pane IDs. Every split uses an explicit `--pane`, `--direction`, `--ratio`, `--cwd`, and `--no-focus`.

Before and after each split, `pane list` and `pane layout --pane` snapshots are normalized and compared. The response pane ID must match the one new pane, the target pane must be retained, all unrelated pane rectangles must remain unchanged, and measured rectangles must be within one cell of the plan. A missing or malformed response is recovered only when read-only snapshots prove exactly one matching new pane; otherwise `team.start` returns `unknown_outcome` and stops.

## Low-Level Operations

### Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

### Delegate to a new agent

#### 1. Inspect the current pane

```bash
test "${HERDR_ENV:-}" = 1
pane_id="$HERDR_PANE_ID"
workspace_id="$HERDR_WORKSPACE_ID"
herdr pane layout --pane "$pane_id"
herdr pane list --workspace "$workspace_id"
```

`team.start` uses these read-only commands to build and validate the Grid plan. It does not infer the target from focus.

Before applying any split, the CLI surface is checked with `herdr --version`, `herdr pane layout --help`, `herdr pane split --help`, and `herdr agent start --help`. Herdr `0.7.5` or later is required. Missing commands or options return `HERDR_CAPABILITY_MISSING` before a split is attempted.

#### 2. Apply a planned split

```bash
herdr pane split --pane "$target_pane_id" \
  --direction right \
  --ratio 0.5 \
  --cwd "$PWD" \
  --no-focus
# read .result.pane.pane_id as the newly created pane
```

#### 3. Agent detection

```bash
herdr pane get <pane-id>
# read .result.pane.agent_status
```

- `agent_status != unknown` → agent is already auto-detected. Assign a name:

```bash
herdr agent rename <pane-id> <name>
```

- `agent_status == unknown` → start manually:

```bash
herdr agent start <name> --kind <kind> --pane <pane-id>
```

Kind: `codex`, `opencode`, `claude`, etc. See `herdr agent start --help` for supported kinds.

#### 4. Send prompt

```bash
herdr agent prompt <target> "<text>" --wait --timeout 30000
```

Target = agent name or pane ID. Prefer agent name when known.

#### 5. Wait

```bash
herdr agent wait <target> --timeout 1800000
```

#### 6. Read output

```bash
herdr agent read <target> --source recent-unwrapped --lines 200
```

### Error recovery

- **name conflict** on `agent start` → check existing agents with `herdr agent list`. If an agent is already registered on the same pane via auto-detection, use `agent rename` instead. If the desired name is already taken by an agent on a different pane, choose a different name.
- **pane not found** on `pane get` → the pane may not have finished initializing. Wait a moment and retry.

### Send to an existing agent

```bash
herdr agent list
herdr agent prompt <name-or-pane-id> "<text>" --wait --timeout 30000
herdr agent wait <name-or-pane-id> --timeout 1800000
herdr agent read <name-or-pane-id> --source recent-unwrapped --lines 200
```

## Rules

- Use `--no-focus` for background work. Do not switch focus unless asked.
- Parse IDs from JSON responses. Do not guess pane or agent IDs.
- Do not close panes or kill agents unless explicitly requested.
- All delegation happens within the current workspace via `pane split`. Do not create a separate workspace for delegation.
- All actions return a common JSON envelope with `schema_version`, `status`, `action`, `actor`, `target`, `data`, and optional `error`.
- Automatically inherit origin agent kind when not specified in config.
