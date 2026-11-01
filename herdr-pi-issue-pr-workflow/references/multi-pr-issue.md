# Multi-PR Issues

[Kickoff gate](../SKILL.md#kickoff-gate) と [Completion](../SKILL.md#completion) にある対象 PR とクローズキーワードのルールの形。このファイルは、実行が何を書き残すかを定める。ルール自体は `SKILL.md` にある。

## Split example

Issue は複数の PR を計画できる。一般的な分割では、最初の PR を自己完結させ、2 つ目をその上に積む。

| PR | Scope | Base branch | Work branch | Closing keyword |
|---|---|---|---|---|
| ① infrastructure | model、API、マイグレーション | リポジトリの base ブランチ | `feat/issue-<n>-model` | なし |
| ② UI | ①の上の画面とフロー | ①の work ブランチ | `feat/issue-<n>-ui` | 計画とリポジトリ規約が許可する位置にだけ付ける |

② は stacked である。base ブランチはリポジトリの base ではなく ① の work ブランチで、② は ① の PR が存在してから開始する。例では両方の PR が非クローズ参照を使うため、① がマージされても ② が着地する前に Issue を閉じることはない。

各実行は自身のキックオフと報告を書き、Issue は 1 回の実行ではなく一連の実行で完了する。後続の実行は前回のロールペインを維持し、自身のタスクのために compact できる。その手順は [Sequential runs](sequential-runs.md) にある。

## Per-run completion report

実行は Issue ではなく自身の PR について報告する。

| Field | Value for the run |
|---|---|
| PR | その実行の Draft PR |
| Head | 最新の検証済み Review スキルレビュー（初回レビューまたはスコープ付き再チェック）が対象としたコミット |
| Verification | その head で成功したチェック |
| Issue state | Issue は最後の PR まで開いたままでよい |
| Close keyword | その実行の位置に対して下した判断 |

## Target PR notation

| Plan | Proposal and report value |
|---|---|
| 1 つの PR で、複数 PR の計画を記述しない | `対象 PR: single` |
| 2 つのうち最初 | `対象 PR: 1/2` |
| 2 つのうち 2 つ目 | `対象 PR: 2/2` |

キックオフの提案、委譲本文、完了報告は同じ値を使う。

## Reference spellings

上の例で使う非クローズの表記。

```text
Related to #<issue>
Refs #<issue>
feat(<scope>): <subject> (#<issue>)
```

クローズの表記。

```text
close #<issue>        closes #<issue>
fix #<issue>          fixes #<issue>
resolve #<issue>      resolves #<issue>
```

リポジトリ自身の規約がどちらの一覧よりも優先する。
