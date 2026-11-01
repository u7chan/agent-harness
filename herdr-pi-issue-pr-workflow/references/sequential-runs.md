# Sequential Runs

複数 PR の Issue は連続した実行で完了し（[Kickoff gate](../SKILL.md#kickoff-gate)）、後続の実行は新しいチームを組む代わりに前回のロールペインを維持できる。このファイルは、いつ、どのように行うかを定める。[Start the team](../SKILL.md#start-the-team) と [Completion](../SKILL.md#completion) がペインのルールを保持する。

判断には現在の会話だけを使う。ペインは、同じ Issue の以前の実行でこの orchestrator がそのロールのために起動したものであり、それらについてディスクに書き出されるものはない。ラベル、エージェント名、チームプロファイルの名前を理由にペインを再利用することはない。

## Scope

再利用は、同じ Herdr ワークスペースと worktree で、同じ Issue の完了済み実行に続く実行に適用する。前回の実行が [Completion](../SKILL.md#completion) より前に停止した場合、今回の実行は [Start the team](../SKILL.md#start-the-team) のとおりに全ペインを構築し、停止した実行のペインは確認用に開いたままにする。新しい orchestrator セッションのように、それらのペインの記憶がない実行にも再利用候補はない。

## Reuse conditions

参加するロールが前回のペインを再利用するのは、次の条件がすべて成立する場合だけである。

| Condition | Check |
| --- | --- |
| Same workspace and worktree | ペインが、前回の実行の委譲時と同じ現在の Herdr ワークスペースと worktree にある。 |
| The pane is this orchestrator's role pane | ペインが、以前の同じ Issue の実行でこの orchestrator がそのロールのために起動し、この会話で名前を挙げたものである。ラベルやエージェント名だけが一致するペインは別のペインである。 |
| The pane is idle | `herdr agent get <pane-id>` が `agent_status: idle` を返す。 |
| The effective specification matches | `herdr agent read <pane-id> --source visible` のフッターに、今回の実行で確定したそのロールの provider、model、thinking が表示される。起動 argv とチームプロファイルは、実行中の値の証拠ではない。 |

条件が成立しない、または確認できない場合、そのロールには新しいペインが必要で、古いペインは開いたままにする。この会話で名前を挙げられないペインを探索したり、一致しない実行中エージェントを修復したり、保存済みチームへフォールバックしたりしない。

## Compact a reused pane

再利用するペインは以前の実行の会話を保持しているため、今回の最初のタスクが届く前に compact する。

1. ペインへ TUI コマンドとして送る。

   ```bash
   herdr agent prompt <pane-id> "/compact"
   ```

   これは委譲ではない。結果返却は期待しないため、Herdr スキルの親ラッパーとその返却トランスポートは適用されず、生の `herdr agent prompt` 呼び出しがトランスポートとなる。ペインは同じワークスペースにあり、それは再利用条件がすでに要求している。

2. 結果はペインの出力から判定し、`herdr agent get` では判定しない。コマンドは最後に結果行を 1 行追加する。成功なら `Compacted from <N> tokens`、失敗なら `Compaction failed: <reason>` である。`herdr agent get` は compaction の間ずっと `agent_status: idle` を報告するため、status は完了の信号にならない。コマンド前にすでに表示されていた結果行は、そのコマンドの結果ではない。再利用するペインには、以前の compaction の行が残っていることがある。

3. コマンド前に取った読み取りを基準にする。その読み取りになかった結果行が表示されるまで、短い有界ステップでペインを読み直し、その後にだけ次のタスクを送る。compaction の実行中は、タスク、返却、その他のコマンドを送らない。また、長い `sleep` ベースのポーリングで orchestrator ペインを占有しない（[Async delegation](../../herdr/SKILL.md#async-delegation)）。

一時的なインジケータ行 `Compacting context... (escape to cancel)` は compaction の実行中に表示されるが、ペインを検索して結果を判定してはならない。ペイン自身のトランスクリプトに、無関係な理由で同じフレーズが含まれることがある。コマンドが追加する結果行が正本である。

`Compaction failed: <reason>` 行で報告される compaction の失敗は、再利用の失敗である。そのペインは今回のタスクを受け取らず、代わりにそのロール用の新しいペインを構築する。どちらの場合もペインは開いたままにする。

## Carry the facts in the task text

compaction はハンドオフではない。ペイン自身の会話を縮めるだけで、今回の実行が決めたことは何も引き継がない。タスクが依存する事実はすべてタスク本文に入れる。ペインが compact されたかどうかは関係ない。

- 今回の対象 PR の位置、work ブランチ、base ブランチの状態。
- 前回の実行の契約が引き継いだ、受け入れ済みの前提、非目標、確定事項。
- 前回の実行との差分。変更された編成や新しい検証要件など。

[Delegation contract](../SKILL.md#delegation-contract) のルールはそのままである。worktree の共有とペインの再利用は、コンテキストの共有を意味しない。

## Panes for a new role

再利用できるペインがない参加ロールには再利用するものがなく、プランナーは既存ペインを計画したセルへ移動できない（[pane layout](../../herdr/references/pane-layout.md#exceptions-to-the-skills-pane-rules)）。

- 新しいロールがない（参加ロールがすべて再利用）: ペインを作らず、プランナーも呼ばない。プランナーは最小数が 2 のため `--count 0` を拒否する。
- 新しいロールが 1 つ: Herdr スキルの単一ペイン規則で orchestrator ペインから分割する（[When the requested agent is absent](../../herdr/SKILL.md#when-the-requested-agent-is-absent)）。
- 新しいロールが 2 つ以上: `herdr/scripts/pane-layout.sh apply --count <new panes>` に新しいペイン数だけを渡し、チーム総数は渡さない。

再利用するペインは既存の名前とラベルを維持し、新しいペインだけに名前とラベルを付ける。`pr-fix` が `impl` に戻る場合や `ui-tester` のない実行など、チームから外れるロールもペインを失わない。委譲を受けたペインは開いたままにし、今回の実行が作成して一度も委譲していない `ui-tester` ペインだけを [Completion](../SKILL.md#completion) で閉じる。

## Relationship to the team profiles

[team profiles](../SKILL.md#team-profiles) とペインの再利用は別の判断である。プロファイルはチーム仕様を確定するため、キックオフは承認待ちを省略できる。ペインの再利用は、上記の条件から今回の実行がそのチームをどのペインで動かすかを確定する。プロファイルはペインについて何も言わず、ペインを再利用候補にすることもない。再利用候補は、プロファイルが確定しなかった承認を省略することもない。同じ実行で両方が適用される。プロファイルが承認を省略し、その後 [Start the team](../SKILL.md#start-the-team) がペインを確認する。
