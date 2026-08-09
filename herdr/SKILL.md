---
name: herdr
description: Delegate work to coding agents in sibling Herdr panes. Use only when the user explicitly mentions Herdr or asks to use Herdr to delegate, inspect, prompt, or coordinate another agent. Requires HERDR_ENV=1.
---

# Herdr

Use the `herdr` CLI directly to delegate work to coding agents in the current workspace and tab.

## Preflight

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
command -v herdr >/dev/null || exit 1
```

If either check fails, explain that Herdr is unavailable and stop.

## Inspect workspace panes

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID" | jq -r '.result.panes[] | [.pane_id, .tab_id, (.label // "-"), (.agent // "-")] | @tsv'
```

Columns: `pane_id`, `tab_id`, `label`, `agent`

## Delegate to a new agent

### 1. Create a sibling pane

Honor a direction requested by the user. Otherwise inspect the current layout:

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split right when there is enough width; otherwise split down.

```bash
herdr pane split \
  --current \
  --direction right \
  --cwd "$PWD" \
  --no-focus
```

Read the new pane ID from `.result.pane.pane_id`. Do not guess it.

### 2. Start or rename the agent

Inspect the new pane:

```bash
herdr pane get <pane-id>
```

- If a recognized agent is already running, assign it a unique name:

```bash
herdr agent rename <pane-id> <name>
```

- If the pane contains an available shell, start the requested agent:

```bash
herdr agent start <name> --kind <kind> --pane <pane-id>
```

- If an unrecognized agent or another foreground process occupies the pane, do not overwrite it. Inspect the pane or create another pane.

Use the kind requested by the user. When unspecified:

| Task | Default kind |
|---|---|
| Implementation | `opencode` |
| Review or verification | `codex` |

Name agents by responsibility, independently of `kind`. Use `<role>[-<scope>]`, adding a short suffix when the name is already in use.

Examples:

```text
impl
review
verify-api
```

### 3. Send the task

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

Keep delegation fire-and-forget. Do not pass `--wait` or block while the delegate works. Return control to the user immediately, then retrieve results after the delegate becomes idle via `herdr agent get` / `herdr agent read` on a later turn.

If the delegate must read the herdr skill or perform herdr operations, say so explicitly in the prompt. The skill is not auto-loaded.

### 4. Read the result

```bash
herdr agent get <name-or-pane-id>
herdr agent read <name-or-pane-id> \
  --source recent-unwrapped \
  --lines 200
```

Treat `blocked` as requiring input. Treat `unknown` as unclassified, not completed.

The result is the delegate's final answer. The delegate performs no additional return operation.

If prompt, get, or read fails, inspect `agent get` and `agent read` before retrying. Do not blindly resend a prompt that may already have been delivered.

## Send to an existing agent

```bash
herdr agent prompt <name-or-pane-id> "<prompt>"
```

Follow the asynchronous behavior in [Send the task](#3-send-the-task). On a later turn, once the delegate becomes idle, read the result:

```bash
herdr agent read <name-or-pane-id> \
  --source recent-unwrapped \
  --lines 200
```

## Create a worktree workspace

Resolve real workspace IDs first; `w1` style IDs are session-local and never reused:

```bash
herdr workspace list
```

Create a Git worktree and open it as a new workspace:

```bash
herdr worktree create --cwd "$PWD" --branch <branch-name>
```

- Prefer `--cwd` over `--workspace ID`; a guessed ID fails with `workspace_not_found`.
- The checkout is created under the configured worktree directory and the branch is created from `HEAD` when it does not exist locally.
- Focus stays unchanged by default; use `--focus` to switch to the new workspace.
- Read new IDs from `.result.workspace.workspace_id`, `.result.tab.tab_id`, and `.result.root_pane.pane_id`. Do not guess them.

## Remove a worktree workspace

Confirm the target workspace is a linked worktree, not the base checkout:

```bash
herdr worktree list --cwd "$PWD" | jq -r '.result.worktrees[] | [.branch, .open_workspace_id, .is_linked_worktree] | @tsv'
```

Remove the checkout:

```bash
herdr worktree remove --workspace <workspace-id>
```

- Only pass a workspace whose `is_linked_worktree` is `true`. Passing the base workspace fails with `not_linked_worktree`.
- The linked workspace closes automatically when its checkout is removed.
- `worktree remove` deletes the checkout only; the branch is never deleted.
- A dirty checkout (modified or untracked files) fails with `dirty_worktree_requires_force`; add `--force` only when discarding those files is acceptable.

## Delegation contract（子エージェント向け契約）

このセクションは、Herdr から委譲された子エージェントとして実行される場合の契約を定義する。

### Skill loading（スキルロード条件）

- Herdr スキルは自動ロードされない。子エージェントは、親の委譲プロンプトで Herdr スキルの読み込みが明示された場合のみ `herdr/SKILL.md` を読む。
- 親は、子に Herdr 操作をさせる場合（例: さらに別のエージェントへ委譲する場合）は、委譲プロンプトに「herdr スキルを読み、それに従え」と明示する。
- 指示がない場合、子は Herdr の存在を前提とせず、通常のタスクとして作業し、通常の最終回答で完了する。

### Completion report（完了報告）

- 子の最終回答は、親が `herdr agent read` で取得する結果そのものである。追加の返却操作は不要。
- 最終回答には次の最小項目を含める:
  - 状態: `completed` または `blocked`
  - 要約: 実施内容と結論
  - 変更ファイル: 変更・作成したファイルの一覧
  - 検証: 実行した検証とその結果
  - 未解決事項またはブロッカー: 親の入力・判断が必要な点
- `blocked` の場合は、何が不足していて親に何を期待するかを明記する。

### Async flow（非同期フロー）

- 親は委譲後ブロックしない（`--wait` を使わない）。子は完了を親へ能動的に通知する仕組みを持たないため、親は子が idle になった後、`herdr agent get` / `herdr agent read` で結果を取得する。
- 子は同期の完了待ちを前提にした動作をしない。

## Rules

- Use Herdr only when explicitly requested.
- Keep delegation in the current workspace, tab, and working directory unless the user requests otherwise.
- Use `--no-focus` for background work.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on UI focus.
- Parse IDs and state from JSON responses. Do not infer them from pane order.
- Do not create a workspace, tab, or worktree unless explicitly requested.
- Do not close panes, kill agents, or stop the Herdr server unless explicitly requested.
- When command syntax is unclear, inspect the installed CLI with `herdr agent` or `herdr pane`. Do not run bare `herdr`, because it may launch or attach the TUI.
