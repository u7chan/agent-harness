# Kickoff task template

orchestrator-first の worktree チームで、親が orchestrator に渡すタスク文面の形式。チーム表、承認ルール、手順の正本は [herdr-pi-issue-pr-workflow/SKILL.md](../SKILL.md) にある。このテンプレートはタスク文面の形だけを定め、それらを再定義・変更しない。

worktree 環境ブロックと、その ID を Herdr の JSON 応答から取得するルールは [Worktree workspace teams — Orchestrator-first](../../herdr/references/worktree-workspace-teams.md#orchestrator-first) に一度だけ定義されている。その節を正本とし、以下のコピーはタスク文面が持つべきフィールド一覧にすぎない。

## Identifiers

```text
role: orchestrator
provider: <provider>
model: <model>
thinking: <level>
```

`role` はこのタスク文面を受け取るエージェントの名前である。provider、model、thinking は承認済みのチーム仕様から埋める。チーム表と承認ルールの正本は [Kickoff gate](../SKILL.md#kickoff-gate) にある。親は同じ 3 つの値を `worktree-team-start.sh` にも渡す。

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

[herdr-pi-issue-pr-workflow](../SKILL.md) を [Start the team](../SKILL.md#start-the-team) から [Completion](../SKILL.md#completion) まで実行する。承認済みチームを起動し、`impl` にキックオフタスクを渡し、Delegation contract、Implementation、Initial review、Review fixes、Review loop の各節に従う。手順の正本はスキルである。

## Verification policy

Issue とリポジトリが要求する検証と、[Delegation contract](../SKILL.md#delegation-contract) の完了ルールに従う。ロールは、必須チェックがすべて成功した後にだけ `completed` を返し、それ以外はコマンドと結果を添えて `blocked` を返す。

## Return target

このタスクを委譲した直接の親ペインへ `completed` または `blocked` を返す。追加される委譲指示が、そのペインと使用する返却ヘルパーを示す（[Async delegation](../../herdr/SKILL.md#async-delegation)）。
