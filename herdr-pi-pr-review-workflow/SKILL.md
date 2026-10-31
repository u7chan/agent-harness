---
name: herdr-pi-pr-review-workflow
description: Herdr上の独立したPiレビュアーとDraft PRのレビュー・修正を繰り返し、検証済みのLGTMとReadyまで進める。Issueは不要。
---

# PR Review Workflow

現在のエージェントがユーザーからのフィードバック対応、実装、修正、調整を担当し、別ペインでは独立したPiレビュアーだけを実行する。
Issueは必須ではない。このスキルの開始前に、フィードバック内容、初回実装、ブランチ、Draft PRを確定させる。
単発レビューには代わりに[review](../review/SKILL.md)を使う。修正ループを黙って開始したり、PRをReadyにしたりしない。

## Boundaries

- ペイン、Piの起動、委譲、非同期の結果返却は[Herdr](../herdr/SKILL.md)に従う。
- GitHubの読み書きはすべて[GH](../gh/SKILL.md)のディスパッチャーを使う。
- レビュー基準、再チェック、LGTM検証、Resolveの方針は[Review](../review/SKILL.md)、特に[再チェック手順](../review/references/recheck.md)を正本とする。ここではルールを重複定義しない。
- 現在のエージェントのprovider、model、thinkingは変更しない。別のcoordinator、`impl`、`pr-fix`、`ui-tester`を起動しない。
- レビュアーは実装・コミット・pushを行わない。レビューイベントは`COMMENT`だけを使い、`APPROVE`、マージ、Issueのクローズは行わない。
- ラウンド数、head、未解決の指摘、ペインIDは現在の会話内だけで管理する。実行状態を永続化したり、ワークフローランタイムを追加したりしない。

## Preflight

副作用のある操作に入る前に、次のすべてを確認する。失敗、不明な結果、曖昧な対象は推測せず停止する。

1. HerdrのPreflightとCaller pinningを満たし、現在のワークスペースとペインを固定する。`pi`も必須とする。
2. PRを1件特定し、`pr.read`でrepository、base、head、stateを固定する。対象はopenかつ未マージのDraft PRでなければならず、Issue参照では代用できない。
3. リポジトリの指示とGit状態を読む。チェックアウト、作業ブランチ、push済みHEADがPRのheadに一致し、想定外の作業ツリー変更がないことを確認する。保護されたbaseへ直接pushしない。
4. PR本文と合意済みの依頼から、変更目的、完了条件、維持すべき契約、運用・互換性要件を抽出する。口頭のフィードバック条件も委譲文に含める。重要な未決事項をレビュアーに創作させない。
5. 現在のheadで必須のテスト、チェック、フォーマッター、リンターをすべて成功させる。必須検証の失敗・スキップ・実行不能は`blocked`として停止する。既存の検証結果を再利用するのは、headと検証範囲を確認できた場合だけとする。

## Reviewer Setup

プロファイルの保存、選択、入出力、エラーは[Pi Development Profiles](../_docs/pi-development.md)を正本とする。次のスクリプトはこのスキルの親ディレクトリ（パッケージルート）から解決する。

```bash
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review
```

`review`ロールだけを検証・解決する。使用しないロールや`pr_fix_shared_with_impl`によって起動を妨げてはならない。
`result=ok`の仕様を再利用し、そのprofile、provider、model、thinkingを報告する。
今回の実行で明示指定された値は、プロファイルを自動的に書き換えることなく優先する。

明示的な上書きを組み立てる場合は`pi --list-models`の正確なIDを使い、仕様全体を再検証する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

`result=ok`の場合のみ起動する。プロファイルが存在しない、不正、未解決の場合は、有効な完全明示指定がない限り、修復または必要な入力を求めて停止する。ランタイムのデフォルトや別モデルへ黙って切り替えない。
`reason=migration-required`なら、明示指定があっても[移行手順](../_docs/pi-development-migration.md)のために停止する。
プロファイルや`active`を自動作成・保存・変更しない。

Herdrの単一ペイン手順に従う。現在のワークスペースにある空の対話シェルを優先し、なければ現在のペインから明示的に分割する。ワークスペースやworktreeは作成しない。

```bash
herdr agent start pr-review --kind pi --pane <pane-id> -- \
  --provider <provider> --model <model> --thinking <thinking>
herdr pane rename <pane-id> pr-review
```

JSON応答からIDを読み取り、ラベルを確認する。画面とランタイム状態で対話可能なこと、実効provider・model・thinkingが確定した仕様に一致することを検証する。起動引数だけでは証拠にならない。不明または不一致の場合は委譲前に停止する。
この実行の全ラウンドで同じレビュアーを使う。

## Review and Fixes

Herdrの`scripts/parent-delegate-async.sh`で委譲し、`scripts/child-return-result.sh`で結果を返す。委譲後はターンを終了し、`--wait`や長時間の`sleep`ポーリングで親をブロックしない。
委譲文には、リポジトリの絶対パス、指示、PR、base/workブランチ、head、ラウンド、目的、完了条件、運用・互換性要件、検証結果、読み取り専用の責務、期待する報告を含める。

1. **Round 1**：ReviewスキルのPRモードを明示的に依頼する。GitHubへのレビュー投稿とその検証を必須とし、`completed`または`blocked`の報告にレビューID/URL、レビュー対象head、指摘件数、Blocker、検証済みLGTM状態を含めさせる。プロンプトの送信や未検証のLGTM申告だけでは完了としない。
2. **Fixes**：Blockerが残る場合、現在のエージェントが投稿済みフィードバックを読み、スコープを拡大せず修正する。必須検証をすべて通し、コミット、pushを行い、リポジトリの指示に従って該当コメントに返信する。修正をpushしたという理由だけでスレッドをResolveしない。push結果が不明、または検証失敗の場合は先に進まない。
3. **Round 2 / Round 3**：修正pushの確認後、同じレビュアーに[再チェック手順](../review/references/recheck.md)を明示的に依頼する。以前の未解決指摘の再分類と、同手順で定める範囲における最新headのレビューの両方を実施させる。分類返信だけではLGTMとしない。運用・互換性要件を引き継ぐ。
4. 再チェック委譲時にworkflowコンテキストのauto-resolveを明示的に指定する。対象判定、返信確認、対象、軽量チェックは正本の再チェック手順に従う。引き継ぎ時には検証済み対象の組`(thread_id, root_comment_id, reviewer_login, classification_reply_id)`を要求し、その組を正本とする。新たな読み取り結果から対象を再構築しない。各Resolve後に`review-threads.read`で`resolved=true`を確認する。

初回を含め、レビューは最大3ラウンドとする。最新headでBlockerのない検証済みLGTMが得られたら直ちに完了処理へ進む。Round 3後もBlockerがあればDraftのまま停止し、残存条件と証拠を報告する。ラウンドを追加しない。
`blocked`、重大な不確実性、headの変更、未確認の書き込みでも停止する。Nit / Consider / FYIや別Issue候補だけでは、Reviewスキルが認めたLGTMを妨げない。

## Completion and Ready

このレビュー・修正・Readyワークフローの実行依頼には、次の条件を満たした後の`pr.ready`も含まれ、追加の承認待ちは不要。単発レビューの依頼ではReadyを許可しない。

1. 現在のPR headで必須検証がすべて成功し、pushが確認されている。
2. 最新headに対して投稿・検証済みのReviewスキルのLGTMがあり、Blockerがない。
3. 最新の再チェックで得たResolve対象をすべて処理し、再読込で確認している。それ以外の会話は開いたまま報告する。LGTMそのものは全スレッドのResolveを許可しない。
4. **Readyの直前**に`pr.read`でopen、未マージ、Draftであり、headが検証結果とLGTMの対象に一致することを確認する。不一致・失敗・不明なら停止する。
5. GHディスパッチャーの`pr.ready`を、対象と明示的な`grant: "sensitive-write"`を指定して実行する。
6. **Readyの直後**にも`pr.read`を実行する。open、未マージ、`draft=false`、同じheadが確認できて初めて完了とする。`failed`、`unknown_outcome`、head変更は成功として扱わず、自動リトライしない。

PR、プロファイル由来か明示指定か、レビュアー仕様とペイン、最新head、検証、ラウンド数、LGTM、Resolve結果、残った任意の指摘・会話、Ready状態を報告する。レビュアーペインは開いたままにする。
スキルを変更するPRの場合は、マージ後の[ロールアウト](../_docs/skill-distribution.md)も案内する。
