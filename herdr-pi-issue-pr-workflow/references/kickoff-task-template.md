# Kickoff task template

起動元（starter）が orchestrator に渡すタスク文面の形式。チーム表、承認ルール、手順の正本は [herdr-pi-issue-pr-workflow/SKILL.md](../SKILL.md) にある。このテンプレートはタスク文面の形だけを定め、それらを再定義・変更しない。

worktree 環境ブロックと、その ID を Herdr の JSON 応答から取得するルールは [Worktree workspace teams — Orchestrator-first](../../herdr/references/worktree-workspace-teams.md#orchestrator-first) に一度だけ定義されている。その節を正本とし、以下のコピーはタスク文面が持つべきフィールド一覧にすぎない。

## Identifiers

```text
role: orchestrator
```

`role` はこのタスク文面を受け取るエージェントの名前であり、プロファイルのロール名ではない。ハーネス別の仕様（Pi の provider/model/thinking、Claude の model/effort/permission_mode）はタスク文面に書かない。`worktree-team-start.sh` が `--role orchestrator` でプロファイルから解決し、委譲本文の末尾（返却指示の前）へ `launch:` 行として追記する。タスクファイルにも委譲本文にも `launch:` 行を手で書かない。

## Launch check

起動後、orchestrator は自分のハーネスに合った手段で実効 spec を `launch:` 行と照合する。

`launch:` 行は `harness=<pi|claude>` と、接頭辞付きの `spec=<harness>:<...>` を出す。`spec` は正本の文字列であり、`harness` はその接頭辞と一致しなければならない。`launch:` 行の形式と意味の正本は [Worktree workspace teams — Orchestrator-first](../../herdr/references/worktree-workspace-teams.md#orchestrator-first) である。本文に `launch:` 行が複数ある場合は最後の行を正本とする。

- Pi の orchestrator は bash ツールで次を実行し、結果を `spec` の値とそのまま照合する。接頭辞を落として比較してはいけない。自身の起動判定の正本は `PI_*` 環境変数（`$PI_PROVIDER` など）であり、footer（`herdr agent read <pane-id> --source visible`）は起動元による補助確認である。footer だけで一致とみなさない。`effective:` 行も `launch:` 行と照合する。

  ```bash
  printf 'pi:%s/%s/%s\n' "$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL"
  ```

- Claude の orchestrator は `$PI_*` を使わない。起動元が `worktree-team-start.sh` 経由で転記した `launch:` と、共有ランチャーが stderr に出した `effective:` の行を使う。`effective:` 行の `requested=` が `spec` と一致し、`effort` が statusline の `.effort.level` と一致することを確認する。`spec_source=profile` のときだけ、`model`（statusline の `.model.id`）が保存済みの canonical 完全 ID と一致することも確認する。明示 alias を一度限りで使った起動では canonical な `model` を今回の実効仕様として報告し、保存済み spec と比較しない。行がタスク文面に無い、値が取得できない、または照合できない場合は停止する。

実行結果が `spec` と一致しない、または行が曖昧な場合は、作業を始めずに停止して起動元へ報告する。

`profile` が `-` でなければ、その値をこの実行のキックオフゲートの既定プロファイルとして使う。ユーザーが今回の実行で明示した指定を優先し、`launch: profile=-` ならゲートは `active` / `default` を使う。

再利用ペインの footer と `probe:` のルールは [Sequential runs](sequential-runs.md) のまま維持する。

## Worktree environment block

```text
workspace: <linked workspace ID>
pane: <root pane ID>
checkout: <worktree checkout path>
branch: <work branch>
base ref: <base ref>
base commit: <base commit>
```

すべての値は Herdr の節の定義どおりに解決する。ID を推測しない。

## Target

```text
issue: <Issue URL or owner/repo#number>
pr: <Draft PR URL or number; none yet at kickoff>
scope: <Issue scope the orchestrator must not exceed>
```

## Workflow procedure

[herdr-pi-issue-pr-workflow](../SKILL.md) の手順の正本に従う。入口は starter の経路で決まる。

- **経路 1**（starter がキックオフゲートを実行済み）: [Start the team](../SKILL.md#start-the-team) から開始してよい。ただし起動前に、承認済みまたは再利用したチーム（`impl` / `review` / `pr-fix` と参加する `ui-tester`）を確認できることを確かめる。確認できない場合は経路 2 として扱う。
- **経路 2**（starter がキックオフゲートを実行していない）: launch check の後、[Preflight](../SKILL.md#preflight) と [Kickoff gate](../SKILL.md#kickoff-gate) を先に実行する。チームを解決し、再利用するか提案して承認を得るまで `Start the team` へ進まない。承認済みチームがあると仮定しない。

チーム確定後は `Start the team` から [Completion](../SKILL.md#completion) まで進み、`impl` にキックオフタスクを渡し、Delegation contract、Implementation、Initial review、Review fixes、Review loop の各節に従う。`launch: profile=<name>` は経路 2 のゲートで使う既定プロファイルであり、ユーザーが今回の実行で明示した指定を優先する。

## Verification policy

Issue とリポジトリが要求する検証と、[Delegation contract](../SKILL.md#delegation-contract) の完了ルールに従う。ロールは、必須チェックがすべて成功した後にだけ `completed` を返し、それ以外はコマンドと結果を添えて `blocked` を返す。

## Return target

このタスクを委譲した直接の親ペインへ `completed` または `blocked` を返す。追加される委譲指示が、そのペインと使用する返却ヘルパーを示す（[Async delegation](../../herdr/SKILL.md#async-delegation)）。
