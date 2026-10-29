---
name: herdr-pi-pr-review-workflow
description: >
  既存の Draft PR を、現在の窓口兼開発担当と別ペインの Pi Reviewer でレビュー・修正し、
  最大3ラウンドで検証済みLGTM、対象スレッドのResolve、Draft解除まで進める。
  Issueなしの口頭FB・軽微な修正にも使う。単発レビューではなく、修正ループとDraft解除を依頼されたときに使う。
  Requires Herdr: the reviewer runs in the current workspace and worktree.
---

# PR レビュー進行

現在のエージェントが窓口・開発・修正・進行を兼任し、独立した Pi Reviewer だけを別ペインで動かす。
Issueは不要。口頭FBの整理、最初の実装、ブランチ作成、Draft PR作成はこのスキルの開始前に済ませる。
単発のレビュー依頼には [review](../review/SKILL.md) を使い、勝手に修正ループやDraft解除を始めない。

## 責任境界

- ペイン、Pi起動、委譲、非同期の結果返却は [herdr](../herdr/SKILL.md) を正とする。
- GitHubの読み書きは [gh](../gh/SKILL.md) のdispatcherだけを使う。
- レビュー基準、再チェック、LGTM検証、Resolveの対象と手順は [review](../review/SKILL.md)、特に [再チェック手順](../review/references/recheck.md) を正とし、ここに複製しない。
- 窓口のprovider / model / thinkingは変更しない。別の司令塔、`impl`、`pr-fix`、`ui-tester`は起動しない。
- Reviewerは実装・コミット・pushをしない。レビューイベントは`COMMENT`だけとし、`APPROVE`、マージ、Issueのクローズは行わない。
- 状態は現在の会話だけで管理する。ラウンド、head、未解決指摘、ペインIDをファイルへ永続化せず、新しい実行基盤も作らない。

## 開始条件

副作用の前に次を確認する。失敗・不明・対象の曖昧さがあれば停止し、推測で補わない。

1. Herdrの`Preflight`と`Caller pinning`を通し、現在のworkspaceとpaneを固定する。`pi`も必要。
2. 対象PRを一意に特定し、`pr.read`でリポジトリ、base、head、状態を固定する。対象はopenかつ未マージのDraft PR。Issueの有無は開始条件にしない。
3. 対象リポジトリの指示とGit状態を読む。対象checkout、作業ブランチ、push済みHEADがPRのheadと一致し、予期しない作業ツリー変更がないことを確認する。保護されたbaseへ直接pushしない。
4. 変更目的、完了条件、維持する契約、運用・互換要件を、PR本文と合意済みの依頼から整理する。口頭FB由来の条件は委譲本文にも明記する。重要な未決定をReviewerの推測で埋めない。
5. リポジトリ・依頼が要求するテスト、check、formatter、linter等をすべて現在のheadで成功させる。失敗・未実行・実行不能は`blocked`として停止する。既存の検証結果を使う場合も、そのheadと対象範囲を確認する。

## Reviewerの設定と起動

保存先、選択順、読み書き、エラーの正本は [Pi Development Profiles](../_docs/pi-development.md)。以下のスクリプトは、このスキルの親（パッケージルート）から解決する。

```bash
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review
```

`review`だけを検証・解決し、使わない役割や`pr_fix_shared_with_impl`で開始を妨げない。
`result=ok`の設定を再利用し、使用profileとReviewerのprovider / model / thinkingを報告する。
この実行で指定された値はprofileより優先し、保存設定を自動で書き換えない。

明示指定を合成する場合は`pi --list-models`の正確なIDを使い、完全なspecを次で再検証する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

`result=ok`以外は起動しない。profileが欠落・不正・未解決なら、完全な明示specが検証できる場合を除き、設定の修復または不足値の確認のため停止する。環境既定や別モデルへ黙ってフォールバックしない。
`reason=migration-required`なら、明示specの有無によらず[設定移行](../_docs/pi-development-migration.md)のため停止する。
このスキルはbootstrapも行わず、profileや`active`を自動保存・変更しない。

Herdrの単一ペイン手順で、現在のworkspaceの空き対話シェルを優先し、なければ現在のpaneから明示的にsplitする。新しいworkspaceやworktreeは作らない。

```bash
herdr agent start pr-review --kind pi --pane <pane-id> -- \
  --provider <provider> --model <model> --thinking <thinking>
herdr pane rename <pane-id> pr-review
```

JSON応答のIDとlabelを確認し、対話準備完了と実効provider / model / thinkingが確定設定と一致することを画面・状態から検証する。起動引数だけを証拠にしない。不明・不一致なら委譲せず停止する。
このrunの全ラウンドで同じReviewerを使う。

## レビューと修正

委譲はHerdrの`scripts/parent-delegate-async.sh`、返却は`scripts/child-return-result.sh`を使う。`--wait`やsleepによる長いpollで親を塞がず、委譲したらターンを終える。
委譲本文にはリポジトリの絶対パス、指示、PR、base・作業ブランチ、head、ラウンド、変更目的・完了条件・運用互換要件、検証結果、読み取り専用の責務、期待する返却を含める。

1. **Round 1**: ReviewerにreviewスキルのPRモードを明示依頼する。GitHubへ結果を投稿・検証し、review ID / URL、対象head、指摘件数、Blocker、検証済みLGTMの有無を`completed`または`blocked`で返却させる。プロンプト送信や未検証のLGTM報告を完了扱いしない。
2. **修正**: Blockerがあれば窓口自身が投稿済みフィードバックを読み、範囲を広げずに修正する。必要な全検証を成功させ、コミット・pushし、リポジトリ規約に従って該当コメントへ返信する。窓口は修正だけを理由にスレッドをResolveしない。結果不明のpushや失敗した検証では進めない。
3. **Round 2 / Round 3**: 確認済みの修正push後、同じReviewerに[再チェック手順](../review/references/recheck.md)を明示依頼する。過去の未解決指摘の再分類と、その正本が定める最新headのレビューの両方を必須にする。分類返信だけではLGTMにならない。運用・互換要件も引き継ぐ。
4. 再チェックの委譲には、このworkflowコンテキストの自動Resolveを明示指定する。実行条件・返信確認・対象・軽量チェックは再チェック手順に従う。Reviewerが実行せず窓口へ引き渡す場合は、検証済み対象集合`(thread_id, root_comment_id, reviewer_login, classification_reply_id)`を返却させ、その集合を正として処理する。対象をfresh readから再構成しない。各Resolve後は`review-threads.read`で`resolved=true`を確認する。

初回を含め最大3ラウンド。現在のheadに対する検証済みLGTMがありBlockerがなければ、3回を待たず完了判定へ進む。Round 3後もBlockerがあれば追加レビューせずDraftのまま停止し、残条件と根拠を報告する。
途中の`blocked`、重要な判断不能、headの変化、未確認の書き込み結果も停止条件とする。Nit / Consider / FYIや別Issue候補だけでは、reviewスキルが認めたLGTMを妨げない。

## 完了とDraft解除

このスキルによるレビュー・修正・Draft解除の実行依頼は、以下の条件を満たした後の`pr.ready`までを含む。追加の承認待ちは設けないが、単発レビュー依頼をその承認に読み替えない。

1. 必須検証が現在のPR headですべて成功し、pushを確認できていること。
2. 最新headをカバーするreviewスキルのLGTMが投稿・検証済みで、Blockerがないこと。
3. 最新の再チェックから引き継いだResolve対象がすべて処理・再取得確認済みであること。対象外の会話は開いたまま報告する。LGTM自体を全スレッドのResolve指示にしない。
4. **Draft解除の直前**に`pr.read`し、open・未マージ・Draftで、headが検証とLGTMの対象に一致することを再確認する。差異・失敗・不明なら停止する。
5. GH dispatcherの`pr.ready`に対象と明示的な`grant: "sensitive-write"`を渡す。
6. **Draft解除の直後**にも`pr.read`し、open・未マージ・`draft=false`・同じheadを確認して初めて完了とする。`failed` / `unknown_outcome`やheadの変化を成功扱いせず、自動再試行しない。

PR、profileまたは明示設定の出所、Reviewerのspec・pane、最新head、検証、レビュー回数、LGTM、Resolve結果、残る任意指摘・対象外会話、Draft解除を報告する。Reviewerのペインは開いたまま残す。
スキル変更を含むPRなら、マージ後に[配布・ロールアウト](../_docs/skill-distribution.md)が必要なことも伝える。
