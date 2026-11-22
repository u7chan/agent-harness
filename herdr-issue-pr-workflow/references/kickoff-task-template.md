# Kickoff task template

起動元（starter）が orchestrator に渡すタスク文面の形式。チーム表、承認ルール、手順の正本は [herdr-issue-pr-workflow/SKILL.md](../SKILL.md) にある。このテンプレートはタスク文面の形だけを定め、それらを再定義・変更しない。

worktree 環境ブロックと、その ID を Herdr の JSON 応答から取得するルールは [Worktree workspace teams — Orchestrator-first](../../herdr/references/worktree-workspace-teams.md#orchestrator-first) に一度だけ定義されている。その節を正本とし、以下のコピーはタスク文面が持つべきフィールド一覧にすぎない。

## Identifiers

```text
role: orchestrator
```

`role` はこのタスク文面を受け取るエージェントの名前であり、プロファイルのロール名ではない。ハーネス別の仕様（Pi の provider/model/thinking、Claude の model/effort/permission_mode）はタスク文面に書かない。`worktree-team-start.sh` が `--role orchestrator` でプロファイルから解決し、委譲本文の末尾（返却指示の前）へ `launch:` 行として追記する。タスクファイルにも委譲本文にも `launch:` 行を手で書かない。

## Launch check

起動後、orchestrator は起動元が `worktree-team-start.sh` 経由で転記した `launch:` と `effective:` の行を使い、実効 spec を照合する。Pi / Claude とも `$PI_*` を printf せず、自分で `effective:` 行を組み立てない。

`launch:` 行と `effective:` 行の形式、`harness` と `spec` の接頭辞一致、本文に複数ある場合の扱いは [Launch and effective lines](../../_docs/pi-development.md#launch-and-effective-lines) を正本とする。`spec` は正本の文字列であり、`harness` がその接頭辞と一致しない行は使わない。

- `effective:` 行の `requested=` が `launch:` 行の `spec` と一致することを確認する。`spec` の `provider` / `thinking`（Pi）と `effort`（Claude）が `effective:` の値と一致することも確認する。`spec_source=profile` のときだけ、`model` が保存済みの canonical 完全 ID と一致することを確認する。明示 alias を一度限りで使った起動（`spec_source=explicit`）では、canonical な `model` を今回の実効仕様として報告し、`spec` の model token との等値照合を要求しない。接頭辞を落として比較してはいけない。
- 行がタスク文面に無い、値が取得できない、または照合できない場合は、作業を始めずに停止して起動元へ報告する。footer（`herdr agent read <pane-id> --source visible`）は補助に留め、footer だけで一致とみなさない。

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

[herdr-issue-pr-workflow](../SKILL.md) の手順の正本に従う。入口は starter の経路で決まる。

- **経路 1**（starter がキックオフゲートを実行済み）: [Start the team](../SKILL.md#start-the-team) から開始してよい。ただし起動前に、承認済みまたは再利用したチーム（`impl` / `review` / `pr-fix` と参加する `ui-tester`）を確認できることを確かめる。確認できない場合は経路 2 として扱う。
- **経路 2**（starter がキックオフゲートを実行していない）: launch check の後、[Preflight](../SKILL.md#preflight) と [Kickoff gate](../SKILL.md#kickoff-gate) を先に実行する。チームを解決し、再利用するか提案して承認を得るまで `Start the team` へ進まない。承認済みチームがあると仮定しない。

チーム確定後は `Start the team` から [Completion](../SKILL.md#completion) まで進み、`impl` にキックオフタスクを渡し、Delegation contract、Implementation、Initial review、Review fixes、Review loop の各節に従う。`launch: profile=<name>` は経路 2 のゲートで使う既定プロファイルであり、ユーザーが今回の実行で明示した指定を優先する。

## Verification policy

Issue とリポジトリが要求する検証と、[Delegation contract](../SKILL.md#delegation-contract) の完了ルールに従う。ロールは、必須チェックがすべて成功した後にだけ `completed` を返し、それ以外はコマンドと結果を添えて `blocked` を返す。

## Return target

このタスクを委譲した直接の親ペインへ `completed` または `blocked` を返す。追加される委譲指示が、そのペインと使用する返却ヘルパーを示す（[Async delegation](../../herdr/SKILL.md#async-delegation)）。
