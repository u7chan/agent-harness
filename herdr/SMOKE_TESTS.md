# Herdr Smoke Tests

## 前提

```bash
command -v jq >/dev/null
```

## Mock smoke tests（Herdr不要）

StatefulなBSP simulatorで、planner・Grid適用・snapshot検証・復旧・safe-stopを検証します。状態は一時 `XDG_STATE_HOME` に保存されます。

```bash
cd /path/to/global-agent-skills
bash herdr/tests/smoke.sh
```

主な検証内容:

- `schema_version: 2`、必須 `layout.max_cols`、未知fieldの拒否
- 1〜7メンバー、`max_cols: 1..3`、最低幅・最低高、divider込みの計画
- 同じ入力からbyte-equivalentな計画JSONが生成されること
- 明示的なpane IDによるGrid splitと、全split後のAgent起動
- split前後のpane集合・矩形・target維持・response pane IDの検証
- response欠落から一意に復旧できるケース
- 0件・複数件・別pane変更・snapshot失敗時の `unknown_outcome`
- 既知失敗時の作成済みpane逆順rollback、未知結果時の自動close禁止

## Live smoke tests（実Herdrが必要）

Herdr `0.7.5` 以上の実行環境で、次を確認します。

- `HERDR_ENV=1`
- `HERDR_PANE_ID`、`HERDR_TAB_ID`、`HERDR_WORKSPACE_ID` が設定済み
- `herdr pane layout --pane`、`herdr pane list --workspace`、明示target付き `pane split` が利用可能

実ペインとAgentを作成するため、実行前に内容を確認してください。

```bash
cd /path/to/global-agent-skills
HERDR_ENV=1 bash herdr/tests/live-smoke.sh
```

Live testは一時状態を使い、manifestに記録されたpaneだけを終了処理します。unknown状態やcleanup失敗時は状態を残して手動確認を促します。

## トラブルシュート

### `jq: command not found`

Debian/Ubuntuなら `sudo apt-get install jq`、macOSなら `brew install jq` で導入します。

### `HERDR_CAPABILITY_MISSING`

`herdr --version` が0.7.5以上であることと、次のhelpに必要なoptionがあることを確認します。

```bash
herdr --version
herdr pane layout --help
herdr pane split --help
herdr agent start --help
```

### `LAYOUT_NOT_FEASIBLE`

現在paneの幅・高さが、orchestrator最低48列、member最低60列×列数、member最低12行×行数を満たしていません。Grid splitは実行されないため、pane状態を変更せずに再試行できます。

### `unknown_outcome`

CLI応答またはread-only snapshotからsplit結果を一意に確定できません。自動retry・自動closeは行わず、manifestの `layout.steps` と `layout.cleanup_complete` を確認してから明示的に復旧してください。
