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
  "schema_version": 1,
  "members": [
    {"role": "impl", "kind": "opencode", "activation": "immediate"},
    {"role": "review", "kind": "codex", "activation": "deferred"},
    {"role": "pr-fix", "kind": "opencode", "activation": "deferred"}
  ]
}
```

When kind is omitted, the origin agent kind is inherited. When activation is omitted, `impl` defaults to `immediate` and all others to `deferred`.

### Agent naming

Agents are named `<kind>-<role>-<short-team-id>`. Pane display names are `<role> [<kind>]`.

### Rollback on failure

If `team.start` fails partway through, created panes are automatically closed. Set `keep_on_failure: true` to preserve them for debugging.

### Idempotency

- `team.start` and `member.prompt` require a `request_id`. Duplicate `request_id` returns `already_applied`.
- Close operations (`member.close`, `team.stop`) are target-state idempotent — closing an already-closed resource returns `already_applied`.
- Prompt delivery with unknown outcome returns `unknown_outcome` and does not retry.

### Workspace binding

Team manifests are bound to the `workspace_id` that created them. Operations from a different workspace are rejected with `WORKSPACE_MISMATCH`.

### Timeouts

- `member.prompt`: default 30s, max 300s
- `member.wait`: default 60s, max 60s (returns `waiting` on timeout, not an error)

### Manifest storage

Manifests are stored at `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-skill/teams/<team-id>.json`. They hold only Herdr infrastructure state (pane IDs, agent names, activation status) — not PR workflow state.

## Orchestrator Workflow

The orchestrator prompt below is for the agent that drives the team. Agent kind and pane configuration are resolved by `team.start`, not hardcoded.

```
# Goal

Issue #{issue} を実装する。

あなたはオーケストレーターであり、自身は原則実装を行わない。プロジェクトマネージャーとして、進行管理、状態管理、各メンバーへの作業指示、完了判定を担当する。

実装は `impl` または `pr-fix` に委譲する。ただしレビュー終盤に残ったtypo、コメント修正、import整理、formatter、lintなど、リスクの低い単純修正だけは自身で行ってよい。

## Kickoff

1. Issue、リポジトリの指示、base branchを確認する。
2. リポジトリ規約に従った作業branchを作成する。
3. Issue、base branch、work branchをKickoff Contextとして `team.start` を実行する。
4. `team.start` が返した `team_id` とroleを以後の操作に使用する。pane IDやagent名を推測しない。
5. `impl` の完了を待つ。`review` と `pr-fix` は必要になるまでdeferredのままにする。

実装前に空commitを作成したり、差分のないDraft PRを作成したりしない。

## Implementation

1. `impl` からPR番号と構造化レポートを受け取る。
2. PRが作成済みで、pushと検証が完了していることを確認する。
3. `member.close` で `impl` を終了する。
4. PR番号と現在HEADを渡して `review` をactivateする。

## Review and fix loop

レビュー指摘がある場合:

1. thread ID、指摘内容、現在HEADを `pr-fix` へ渡す。
2. 修正、検証、push、各指摘への返信が完了するまで待つ。
3. 新しいHEADを渡して `review` へ再レビューを依頼する。
4. reviewerが修正を確認し、該当threadをResolveするまで待つ。

このループは最大3回までとする。3回で収束しない場合は完了扱いにせず、reviewとpr-fixを保持したまま阻害要因をユーザーへ報告する。

## Completion

以下をすべて確認する:

- 実装と必要なローカル検証が完了している
- PRの現在HEADに対応するLGTMコメントがある
- Review ConversationがすべてResolve済みである
- required checksが存在する場合、現在HEADですべて成功している
- reviewerの構造化レポートに追加修正なしと記録されている

条件を満たしたらPRをReady for reviewへ変更し、mergeは行わない。最後に `team.stop` で残存メンバーを終了し、PR URL、最終HEAD、LGTMコメント、checks、検証結果を報告する。
```

## Role Prompts

Standard role prompts are bundled in `herdr/prompts/`:

- `prompts/impl.md` — Issue implementation role
- `prompts/review.md` — Code review role
- `prompts/pr-fix.md` — PR fix role

Each role returns a structured JSON report in its final response.

## Low-Level Operations

### Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

### Delegate to a new agent

#### 1. Split pane

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
# read .result.pane.pane_id
```

Use `down` when the caller pane is already narrow.

#### 2. Agent detection

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

#### 3. Send prompt

```bash
herdr agent prompt <target> "<text>" --wait --timeout 30000
```

Target = agent name or pane ID. Prefer agent name when known.

#### 4. Wait

```bash
herdr agent wait <target> --timeout 1800000
```

#### 5. Read output

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
