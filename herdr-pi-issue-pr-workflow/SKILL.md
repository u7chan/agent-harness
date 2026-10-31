---
name: herdr-pi-issue-pr-workflow
description: >
  Herdr のペインで役割ごとに Pi エージェントを起動し、GitHub Issue の実装から Draft PR の最終レビューまでを統括する。
  Pi 専用の Issue→PR ワークフロー（チーム編成、実装、レビュー、修正）を依頼されたときに使う。
  Herdr 必須。各役割のエージェントは現在の Herdr ワークスペース内のペインで動作する。
---

# Pi Issue PR Workflow

ワークフローの調整だけを行う。orchestrator のペインで Issue の実装・修正はしない。

## Boundaries

既存スキルを読み、その動作を重複実装せず正本に従う。

- ペイン、Pi エージェント起動、非同期委譲、結果返却は [Herdr](../herdr/SKILL.md)。
- GitHub の読み書きはすべて [GH](../gh/SKILL.md)。
- PR 全体のレビュー、再チェック、会話の Resolve 方針は [Review](../review/SKILL.md)。

これらのスキルを安全性と操作ルールの正本とする。すべてのエージェントは現在の Herdr ワークスペースと worktree 内で動かす。ワークフロー専用のランタイム、永続的な実行状態、固定の provider/model 一覧を追加しない。永続化禁止の対象は現在フェーズ、レビューラウンド、レビュー済み head、未解決 Blocker など実行ごとの進行状態である。[チームプロファイル](#team-profiles) だけは Issue の要求に基づく例外で、名前付きのチーム編成のみを保存し、実行の進行状態は保存しない。

## Local review before filing an Issue

Issue 起票前に次の表を適用する。手順は [`herdr-issue-review`](../herdr-issue-review/SKILL.md) に従う。

| 変更種別 | 起票前のローカルレビュー |
|---|---|
| 新機能・大きな変更 | 必須 |
| 明白なバグ修正・小さな変更 | 省略可 |
| どちらとも判断できない | 必須 |

変更の大小は差分行数ではなく、変更規模と不確実性で判断する。新機能、新たな契約、インターフェース変更、既存動作の変更は、差分が数行でも大きな変更とする。その実行内容がそれに応じた規模になるためである。省略可能なのは誤字、リンク切れ、原因が 1 つに特定された障害など、報告だけで修正方法と検証方法が明らかで、レビューが作業を遅らせるだけの場合。迷ったらレビューする。

このルールは、このワークフローが起票するすべての Issue に適用する。レビュー時に報告した別 Issue 候補（[Initial review](#initial-review)）も含む。ローカルレビューは PR レビューの代わりではない。`review` ロールによる PR レビューは別途必須である。

## Preflight

ワークフローの副作用を発生させる前に、次を確認する。

1. 一意に特定できる GitHub Issue 参照を要求する。なければユーザーに尋ねる。
2. Herdr の事前検証を通し、Herdr スキルの条件に加えて `HERDR_WORKSPACE_ID` を必須とする。
3. `pi` を必須とし、`pi --list-models` から実際に利用可能なモデル一覧を取得する。
4. GH スキルで Issue 本文と会話コメントを読む。
5. 対象リポジトリの指示と Git/worktree の状態を確認する。

orchestrator-first 方式の worktree チームでは、orchestrator へ渡すタスク文面は [キックオフ用テンプレート](references/kickoff-task-template.md) に従う。テンプレートが定めるのはタスク文の形式だけで、チーム表と承認ルールは [Kickoff gate](#kickoff-gate) を正本とする。

リポジトリが曖昧、worktree に想定外の変更がある、必須ツールが利用できない場合は停止する。対象を推測したり、変更を破棄したり、代替ワークスペースを作成したりしない。

## Team specification

論理ロールは `impl`、`review`、`pr-fix` で、`ui-tester` は任意の追加ロール。実際に起動するエージェントはすべて Pi とする。物理エージェントの完全な仕様には、次の 3 つを必ず含める。

- 正確な provider ID。
- `pi --list-models` で当該 provider 配下に存在する正確な model ID。
- そのモデルがサポートする thinking レベル（`off`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max` のいずれか）。

`pr-fix` は独立エージェントではなく `impl` に兼務させてもよい。`review` は必ず別エージェントであり、実装を編集してはならない。`ui-tester` も独立した物理エージェントで、仕様に含まれない場合は起動しない。`ui-tester` を使わない実行には、余分なペインや条件を追加しない。`ui-tester` は実装の編集、コミット、PR 編集、GitHub レビュー投稿、PR コメント投稿を行わない。指摘は orchestrator のトリアージ材料となり、再現可能な機能不具合は必須修正、それ以外は同じ修正ラウンドに含めてよい。一方、Blocker 判定の正本は `review` ロールである。`ui-tester` のタスク文面、再検証、完了、環境分離は [ui-tester ロール参照](references/ui-tester-role.md) に定める。

明示された provider/model の組は `pi --list-models` で検証する。ただし、その thinking 列の yes/no をレベル検証に使わない。完全な仕様は次のヘルパーで解決する。ヘルパーはインストール済み Pi ランタイムの公開 API から当該モデルと、サポート対象および clamp 後の thinking レベルを確認する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

出力は `provider`、`model`、`requested`、`supported`、`effective`、`result`、`thinking_level_map` を含む 1 行の key=value 形式で、`result=ok` 以外は非 0 終了する。`result=ok`（実効レベルが指定レベルと一致）の場合だけ仕様確定とする。それ以外は未解決として停止する。Pi のデフォルトへの無断切り替え、clamp されたレベルの受け入れ、alias の独自管理、未提供 ID の推測を行わない。指定の一部欠落、不正、曖昧、非対応、clamp 済みの仕様はすべて未解決とする。

## Team profiles

ユーザーが承認したチーム編成は、ユーザーが所有する名前付きプロファイルとして保存する。保存、選択、検証、ヘルパーコマンド、出力契約はスキル外の [Pi Development Profiles](../_docs/pi-development.md) を正本とする。パッケージルートから `scripts/pi-development/team-record.sh` を使う。このワークフローではロール単位の部分投影ではなく、常にチーム全体を解決する。

通常の実行ではプロファイルを書き換えない。実行限定の上書きや `ui-tester` の除外は保存済み編成を変えない。正本を変更できるのは明示的な `use`/`write` 操作、および次の初期化だけ。

この実行で合意したチームを `default` として初期化（bootstrap）するのは、次の条件が**すべて**成立したときだけ。

- `result=missing`
- `reason=no-profiles`
- `profiles_present=false`
- `source=default`（`active` が存在しない）
- 実行で `--profile` が指定されていない

初期化では合意した編成を `write --profile default` で保存し、承認待ちは追加しない。`profiles_present=true` なのに選択名だけが存在しない場合、`active` が壊れている場合、明示指定のプロファイルがない場合は初期化しない。これらは提案経路に戻り、ユーザーが明示した場合だけ保存する。`profiles/` や `active` を読み取れない場合も `profiles_present=false` の例外ではない。`result=invalid`（プロファイル集合の `profiles_present` は空）となるため初期化しない。

保存するのはチーム仕様のみ。対象 PR は保存しないため、再利用を妨げるのは対象 PR が未確定の場合だけ。`ui-tester` のタスクも再利用条件にはしない。今回指定がなければ [ui-tester ロール参照の既定タスク](references/ui-tester-role.md#default-task) が使われるため。保存済みの provider、model、thinking、編成の各値は、今回の実行でその値が指定されていない場合だけ再利用する（[Kickoff gate](#kickoff-gate)）。

未移行の資産は初回起動時の欠落ではなく `migration-required` を返す。その上に初期化しない。継続前にバックアップを伴う手動の [プロファイル移行](../_docs/pi-development-migration.md) を行う。

## Kickoff gate

[ui-tester の参加ルール](references/ui-tester-role.md#participation) に従って `ui-tester` の参加を決め、すべてのキックオフ返信に参照先で定められた固定の 1 行を表示して進む。文面の正本は参照先であり、ここでは再定義しない。この判定は自動で、承認待ちを追加しない。ユーザーは同じ返信で判定を上書きできる。

ロールの割当、エージェント仕様、対象 PR のどれかが未確定なら、Issue と関連リポジトリの情報を確認し、進行前にチーム全体を提案する。ユーザーが指定した有効な値はすべて維持する。

提案前に [チームプロファイル](#team-profiles) の再利用を検討する。

1. `scripts/pi-development/team-record.sh resolve [--profile <name>]` で実効プロファイルを解決する。`ui-tester` 参加判定がある場合は `--require-role ui-tester` を追加する。「`fallback で`」は今回の実行のプロファイル選択なので `--profile fallback` とし、`active` は変えない。「`fallback に切り替えて`」は別操作の `use fallback`（[Team profiles](#team-profiles)）。`reason=migration-required` なら代替チームを提案せず移行のために停止する。
2. 次の条件が**すべて**成立する場合だけ、表と承認待ちを省略する。すなわち、`result=ok` で、今回の実行で provider/model/thinking が一切明示されず、`pr-fix` が `impl` を兼務するかどうかや独自の `ui-tester` 構成も指定されていないこと（Issue から導いた参加判定、または同じ返信でユーザーが上書きした参加判定は今回の参加ロールを決めるだけで、編成の明示指定とはみなさない）、そして対象 PR が確定していること。この場合はプロファイルと参加するロールを示す次の**1 行だけ**と参加判定の 1 行を出し、[Start the team](#start-the-team) へ進む。

   ```text
   前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]
   ```

   編成はプロファイルに含まれるため、今回の実行で編成が明示されていれば再利用せず、提案と承認待ちへ進む。そうしないと今回の指定より保存済み編成を優先してしまう。参加判定の上書きは編成の明示指定ではないため、再利用経路を維持する。参加判定は出所に関係なく今回のチームだけに適用する。保存済み `ui-tester` を上書きするのは一方向だけ。参加する場合は `--require-role` によりロールのないプロファイルを `unresolved` にする。参加しない場合はロールを除いてプロファイルを再利用するが、保存済み編成から `ui-tester` は削除しない。
3. それ以外はこの節のルールに従ってチーム全体を提案し、承認を待つ。プロファイルがまったくない場合に限り、合意したチームを [Team profiles](#team-profiles) の条件で `default` として初期化する。それ以外の保存はユーザーの明示指示がある場合だけ。

提案には次の表を使う。

| Role | Assignee | Provider | Model | Thinking | Selection reason |
|---|---|---|---|---|---|

この節のチーム表と承認ルールを正本とし、[キックオフ用テンプレート](references/kickoff-task-template.md) は orchestrator に渡すタスク文面の形式だけを規定する。

モデル能力と thinking はタスクに合わせ、必要な複雑さにだけ強い推論能力を割り当てる。不確実性とトレードオフを明示し、価格・クォータ・遅延・能力に関する根拠のない主張をしない。

標準では `impl` に `pr-fix` を兼務させる。別担当を提案するのは、専門知識が異なる、コンテキスト負荷が見込まれる、独立して理解できる領域に変更がまたがるなど、具体的な引き継ぎ上の利点がある場合だけ。その理由を提案に示す。

Issue 本文とリポジトリ規約から、今回の実行で作る対象 PR を決定して提案に明記する。

- 複数 PR 計画（例：インフラ PR①のブランチを基に UI PR②を作る）がある場合、今回作る PR の位置を `対象 PR: <position>/<total>`（例：`対象 PR: 1/2`）と記載する。1 回の実行で作る PR は必ず 1 件。複数 PR の Issue は連続した実行で完了し、後続の実行では前回のロールペインを再利用する（[Sequential runs](references/sequential-runs.md)）。
- それ以外は `対象 PR: single`。
- 計画はあるが今回の位置を確定できない場合は、推測せず提案内で対象を未解決のままにし、追加の停止・承認ループを作らず既存の承認を待つ。

GitHub は default ブランチへ到達したコミットメッセージ中のクローズキーワードを解釈するため、その使用判断も同じ提案に含める。`close #<issue>`、`closes`、`fixes`、`resolves` などのクローズキーワードを PR 本文とコミットメッセージに使うのは、今回が計画の最後の PR で、かつリポジトリ規約がキーワードを要求する場合だけ。それ以外は両方で `Related to #<issue>` などの非クローズ参照を使う。リポジトリ規約だけでは最後の PR とは判断できない。Issue に計画がない場合はクローズキーワードなしを既定とし、承認済み提案で別途定められた場合にだけ従う。スタックした PR で base ブランチと work ブランチが異なる場合、その差とマージ時のクローズキーワードの危険性を明記する。分割と綴りの例は [複数 PR の Issue 参照](references/multi-pr-issue.md) を参照する。

今回の実行で指定された `ui-tester` タスクはそのまま保持して委譲文に含め、チーム表へ列を追加しない。指定がなければ [ui-tester の既定タスク](references/ui-tester-role.md#default-task) を使い、タスクについて追加承認を待たない。

**チーム全体の提案についてユーザーの明示的な承認を待つ。** 承認前にはブランチの作成・切り替え、ペイン作成、エージェント起動、GitHub 書き込みを行わない。割当がすべて有効かつ確定し、対象 PR も確定した場合だけ、承認されたチームを要約して追加の承認ラウンドなしに進む。

合意済みチームは今回の実行で使い、保存プロファイルを変更しない。編成は実行限定であり、保存済み `ui-tester` の除外、`pr-fix` の分離、provider/model/thinking の上書きは保存先に反映しない。唯一の自動保存は [Team profiles](#team-profiles) の条件による bootstrap で、`team-record.sh write --profile default` で保存する。それ以外は明示指示がある場合だけ `team-record.sh write --profile <name>` を使い、`--pr-fix-shared-with-impl` や参加ロールの選択を含む合意済みの編成そのものを保存する。今回指定された値はプロファイルより優先し、上書きされた保存値を黙って使わず、未解決の値も保存しない。`編成見せて` の依頼では、`resolve` の出力からチーム表を表示するだけで、承認待ちも変更も行わない。

## Start the team

チーム確定後に次を行う。

1. リポジトリの現状と指示から base ブランチを決定する。
2. 指示に従って専用 work ブランチを作る。既存の work ブランチは、ユーザーが明示的に選択した場合だけ使う。保護された base へ直接 push しない。
3. 各参加ロールについて、この orchestrator が同一 Issue の以前の実行から使っているペインを再利用できるか判断する。[Sequential runs](references/sequential-runs.md) の条件を**すべて**満たす場合だけ再利用する。満たさない、または確認できない場合は新しいペインが必要とする。判断には現在の会話だけを使う。
4. 新たに必要な物理エージェント 1 体につきシェルペインを 1 つ用意する。複数の場合は Herdr レイアウトプランナーで新規ペインをまとめてグリッドに配置し、セル順の ID を取得する。

   ```bash
   herdr/scripts/pane-layout.sh apply --count <new physical agents> --label <team label>
   ```

   `--count` は**新規ペイン数だけ**であり、再利用分を含めない。0 の場合は何も作らずプランナーも呼ばない。新規が 1 つの場合、最小数 2 のプランナーは使えないため、Herdr スキルの単一ペイン規則で orchestrator のペインから分割する。
5. 各新規ペインで検証済みの値を使ってエージェントを起動する。

   ```bash
   herdr agent start <name> --kind pi --pane <pane-id> -- \
     --provider <provider> --model <model> --thinking <thinking>
   ```

6. 新規ペインには責務に基づいたエージェント名とペインラベルを付ける。再利用するペインの既存の名前とラベルは維持する。
7. 作業を送る前に、起動した各 Pi ペインのランタイム状態を確認し、実効 provider/model/thinking が承認済みの仕様と完全一致することを検証する。不一致・検証不能なら停止する。

起動するのは参加ロールだけ。`impl`（独立させなければ `pr-fix` を兼務）と `review` は常に参加し、判定により `ui-tester` を追加する。`pane-layout.sh apply --count <new physical agents>` にはチーム総数ではなく新規ペイン数を渡す。再利用なしの場合、兼務チームは 2 つ、別 `pr-fix` または `ui-tester` の片方を追加すると 3 つ、両方あれば 4 つとなる。部分再利用では新規数が減り、全ロール再利用なら 0 になる。プランナーは新規ペインを計画済みグリッドに収め、呼び出し元のタブに収まらない場合はラベル付きの新タブを作る（[pane layout](../herdr/references/pane-layout.md#tab-policy)）。そのため 4 ペインチームが新タブで起動する場合もある。起動結果が失敗・不明の場合、実装を開始せず、作成済みペインも自動で閉じない。観測した状態を報告する。

開始時にタスクを受け取るのは `impl` だけ。`review` と独立した `pr-fix` は担当フェーズまで待機する。`ui-tester` も Draft PR 作成まで待機する。再利用する各ペインは、この実行で最初の委譲をする前に compact する（[Sequential runs](references/sequential-runs.md)）。compact はタスクではなく TUI コマンドなので、キックオフで作業を受け取るロールの条件は変わらない。

## Delegation contract

各タスクでは Herdr スキルの非同期親→子ラッパーを使用する。委譲文にロール、Issue、base/work ブランチ、存在する場合は PR、リポジトリの指示、フェーズ固有の範囲、期待する報告を含める。同じ worktree を共有するからといって会話コンテキストを共有すると仮定しない。再利用したペインでも同様。compact で前回実行の事実は引き継がれないため、タスク文で渡す（[Sequential runs](references/sequential-runs.md)）。

各ロールは直接の親への結果返却ヘルパーを使い、`completed` または `blocked` を返す。報告には実施内容、検証、関係するコミットまたは PR、未解決条件を含める。プロンプト送信だけでは完了の証拠にならない。次のフェーズへ進む前にエージェントの状態と出力を確認する。orchestrator ペインをブロックせずに返却を待つこと。親がツール呼び出し中は返却がキューに入るため、`sleep` を使った長いフォアグラウンドのポーリングで占有しない（Herdr の非同期委譲ルール参照）。

`completed` には Issue とリポジトリの指示で要求される検証が**すべて実行され、成功したこと**が必要。必須チェックの失敗、スキップ、実行不能では、コマンドと結果を示して `blocked` を返す。検証が終了しただけでは進めない。

Issue、チーム割当とペイン ID、base/work ブランチ、現在のフェーズ、PR、レビュー済み head、レビューラウンド、未解決 Blocker は現在の会話内だけで追跡する。実行状態をディスクに書かない。[チームプロファイル](#team-profiles) には編成のみ保存する。

### Implementation

`impl` に次の作業を依頼する。

1. Issue とコメントを読む。
2. Issue の範囲に限って実装し、リポジトリの指示に従う。
3. 必須のテスト、チェック、フォーマッター、リンターをすべて実行して成功させる。
4. work ブランチにコミットして push する。コミットメッセージには Kickoff gate で決めたクローズキーワード方針を適用する。
5. GH スキルで、リポジトリ固有の必要な説明を含む Draft PR を作成する。PR 本文にも同じ方針を適用する。
6. コミット、検証結果、PR 番号と URL を返す。

必須検証の成功、確認済み push、Draft PR の作成がすべて揃うまで進まない。必須検証が失敗または実行不能なら `blocked` を要求し、実装完了とはみなさず停止する。Git/GitHub の不明な結果を成功とみなしたり、無条件に同じ操作を繰り返したりしない。

### ui-tester verification

仕様に `ui-tester` がある場合、Draft PR の実際の差分をもとに [Draft PR re-judgment](references/ui-tester-role.md#draft-pr-re-judgment) で参加を再判定し、ユーザーに見える画面・操作が変更された場合だけ委譲する。`ui-tester` の作業は Round 1 レビューと並行してよい。Kickoff gate で設定したタスク（今回指定されたタスク、なければ既定の E2E タスク）を渡す。指定済みタスクを既定タスクで上書きしない。

`ui-tester` は [証跡仕様](references/ui-tester-role.md#evidence) に従って証拠を生成する。通常はスクリーンショットとし、時間経過に依存する主張だけ WebM 動画を使う。GIF やテキストの重ね合わせは禁止。全成果物を `PW_ARTIFACT_DIR` 内に置き、添付の 10 MB 上限を守る。動画が上限を満たせない場合はスクリーンショットを記録された代替とする。検証項目ごとに証明する成果物の絶対パスを返す。`ui-tester` 自身はコメントを含め GitHub へ投稿しない。orchestrator が投稿前にサイズを確認し、証跡を投稿する。以下の再検証も同じ証跡契約に従う。

返却された証跡は、GH スキルの `comments.create` と明示的な `grant` で、[証跡コメントの形式](references/ui-tester-role.md#evidence-posting) に従って PR コメントとして投稿する。本文の先頭には head を示すマーカーを付け、全添付に言及する。投稿前に PR コメントからそのマーカーを検索する。同じ head のコメントを再利用できるのは、その本文に今回返却された全項目がすでに記載されている場合だけ。項目が追加された場合は新しいコメントを作る（`comments.update` では添付を追加できないため）。修正 push で head が変わった場合は head ごとにコメントを分け、各レビューラウンドにつき最大 1 件とする。

投稿前に成果物の存在、添付可能な拡張子、10 MB 以内のサイズをすべて確認する。gh CLI 自身のチェックでは Free プランの 10 MB 制限を検出できない。`MISSING_DEPENDENCY`、`ATTACH_UNSUPPORTED`、`ATTACH_INVALID` は再試行不能な書き込み前エラー（`retryable=false`）とし、原因を報告して完了前に停止する。`unknown_outcome` は不明として扱い、PR コメントのマーカーを再確認して判断する。再確認で確定できない場合は観測した状態を報告して停止する。返却された項目に添付証拠がないまま完了を報告しない。

`ui-tester` はレビューラウンドを追加しない。その指摘はトリアージの入力となり、再現可能な機能不具合は修正必須、それ以外の指摘は同じ修正ラウンドで扱ってよい。Blocker 判定の正本は `review` ロール。`ui-tester` の指摘による修正は担当 `pr-fix` へ渡す。`ui-tester` の修正 push も通常の修正 push であり、既存の 3 ラウンドのレビュー予算を消費する。Round 3 後に必須の `ui-tester` 指摘が残る場合は、ラウンドを追加せず停止して報告する。

各修正 push 後、`ui-tester` は最新 head で、報告済み項目と影響範囲に限定して再検証し、それぞれ pass または unverified を報告する。`ui-tester` による有料 API 検証は既定で無効とし、Issue の検証ポリシーを優先する。タスク文面、再検証チェックリスト、環境分離値は [ui-tester ロール参照](references/ui-tester-role.md) を正本とする。

### Initial review

`review` へ PR の URL または番号を渡し、Review スキルの PR モードを明示的に依頼する。レビュアーは結果を GitHub に投稿し、レビューラウンド、head コミット、指摘件数、Blocker の有無を返す。

ユーザーが依頼した運用・互換性要件を、委譲文でレビュアーへ引き継ぐ。Review スキルは適用した前提をすべてのレビュー結果に記録する。別 Issue の候補は指摘件数に含めず、LGTM を妨げずに報告する。

レビュアーは修正実装、PR の APPROVE、マージを行わない。Review スキルが LGTM を報告した場合、Nit、Consider、FYI はワークフローを妨げない。

### Review fixes

Blocker が残る場合、担当 `pr-fix` へ PR と実際に投稿された指摘を正確に渡す。`impl` が `pr-fix` を兼務する場合は同じエージェントとペインを使う。

修正担当に次を依頼する。

1. GH スキルで現在の PR フィードバックを読む。
2. スコープを広げずに報告済み Blocker へ対処する。
3. 更新後の head に必要な検証をすべて再実行して成功させる。
4. 修正をコミットして push する。
5. リポジトリの指示で必要な場合は該当レビューコメントへ返信する。
6. コミット、検証結果、返信、未解決フィードバックを返す。

必須検証が失敗または実行不能の場合、修正担当は `blocked` を返す。修正担当はレビュー会話を Resolve してはならない。

### Review loop

修正 push を確認した後、同じ `review` エージェントに Review スキルの再チェック手順（`review/references/recheck.md`）を明示的に依頼し、以前の未解決指摘をすべて再チェックするとともに最新 head をレビューさせる。ユーザーの運用・互換性要件も引き継ぐ。通常の PR モードだけを依頼したり、再チェックを任意にしたりしない。委譲には以前の未解決 root コメントの再分類と、正本の定める範囲での最新 head レビューの**両方**を必須として記載する。再分類への返信だけでは LGTM の根拠にならない。

再チェック委譲では、このワークフローの auto-resolve 指定も渡す。分類返信を投稿し LGTM を検証した後、レビュアーが `Resolved` と分類したスレッドを Resolve する（[Completion](#completion) 参照）か、検証済み対象を orchestrator へ引き渡してから orchestrator が Resolve する。Review スキルの再チェック参照（`references/recheck.md` の「Workflow コンテキストの自動 Resolve」）がトリガー、返信確認、軽量チェック、実行の正本となる。ワークフロー側は auto-resolve を指定するだけで、方針を再定義・再導出しない。引き継ぎ時の報告には、各対象を `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` の組で含める（Review スキルの再チェック報告仕様参照）。orchestrator は新しい読み取り結果から対象を再導出せず、報告された集合を正本とする。各対象に `review-threads.resolve` を実行し、`review-threads.read` で読み直して `resolved=true` を確認する。

最初の PR 全体レビューを Round 1 と数え、合計最大 3 ラウンドとする。

- 最新 head の検証済みレビューで Blocker がなく LGTM が投稿された場合、ワークフローを完了する。
- Round 3 より前に Blocker が残る場合は、修正と再チェックを繰り返す。
- Round 3 後も Blocker が残る場合は停止し、残った失敗条件と証拠を報告する。
- いずれかのエージェントが `blocked` を返した場合、そのフェーズを停止し、必要な判断または入力を求める。

Herdr や GitHub の操作の周囲に別の再試行、キュー、状態マシンを追加しない。


## Completion

次の条件が**すべて確認できた場合だけ**完了とする。

- Issue の実装が PR の head へ push されている。
- 現在の PR head で必須の検証がすべて成功している。
- PR が存在し、Draft のままである。
- 現在の PR head が、Review スキルによる最新の検証済み LGTM レビュー（正本に定める範囲での再チェック時の最新 head レビューを含む）の対象コミットに一致し、Blocker がない。
- PR 本文とコミットメッセージが、Kickoff gate で対象 PR 向けに決定したクローズキーワード方針に従っている。
- 必須のレビュー修正が残っていない。
- **`ui-tester` を指定した場合だけ**、担当したすべての項目について、現在の PR head で pass が確認されたか、未検証の理由とともに unverified として報告されている。さらに、現在の head で pass となった項目には、同じ head の証跡コメントへ証拠が添付されており、そのコメントを読み直して確認している（[ui-tester verification](#ui-tester-verification)）。この条件はレビューの LGTM 条件に追加するもので、置き換えではない。
- 最新の再チェックで `Resolved` に分類された全スレッドが、返信確認と軽量チェック後に Resolve 済みである（このワークフローの auto-resolve）。`Partial`、`Unresolved`、`Unknown`、ほかの投稿者のスレッド、ユーザー判断待ちの議論は開いたままにする。
- 実行に含めた `ui-tester` のうち、起動したが一度も委譲しなかったペインは `herdr pane close <pane-id>` で閉じ、[Completion cleanup](references/ui-tester-role.md#completion-cleanup) の 1 行を報告している。委譲を受けたすべてのペインは開いたままにする。

会話の Resolve は Review スキルの方針を正本とし、その再チェック参照（`references/recheck.md`）に従う。ワークフロー外では Resolve に明示指示が必要。ワークフロー内の修正→再チェックでは auto-resolve を委譲する。再チェックに workflow コンテキストの auto-resolve 指定を付け、検証済み LGTM の後で、`Resolved` に分類されたスレッドをレビュアー、または引き継ぎを受けた orchestrator が、報告された検証済み対象集合に基づいて Resolve する。各 Resolve は、再チェック正本が要求する返信確認・軽量チェックを行い、`review-threads.read` で `resolved=true` を再確認する。最新の再チェックで `Resolved` と分類されなかったスレッドは開いたままにする。検証済み LGTM だけでスレッドが自動 Resolve されることはない。PR を自動で Ready にしたり、上記未使用の `ui-tester` 以外のペインを閉じたり、PR をマージしたり、Issue をクローズしたりしない。

未使用の `ui-tester` ペインは、完了が確認できてから `herdr pane close <pane-id>` で閉じる。このワークフローが作成し、一度も委譲していないペインだけを閉じ、その結果を 1 行で報告する。ユーザーが作成したペイン、委譲を受けたペイン、実行が失敗または完了前に停止した場合のすべてのペインは残す。これがワークフローによる唯一の自動ペインクローズであり、委譲済みペインまで閉じる可能性のある `herdr tab close` や `herdr workspace close` は使わない。

Issue、採用チーム仕様の由来（[実効チームプロファイル](#team-profiles) または今回の承認）、対象 PR の位置（`対象 PR: 1/2` または `対象 PR: single`。スタックした PR の場合は base ブランチとの差も記載）、base/work ブランチ、Draft PR、最新コミット、検証、レビューラウンド数、別 Issue 候補、残存する任意の指摘・会話、作成した全ペインのロールと観測状態を報告する。`ui-tester` 参加判定の 1 行、Draft PR 時点の再判定、閉じた場合の終了行、証跡コメントを投稿または再利用した場合は最新 head のコメントも含める。PR の変更ファイルにスキルが 1 つでも含まれる場合は、マージ後に [_docs/skill-distribution.md](../_docs/skill-distribution.md) のロールアウト手順を実行するよう報告内で案内する。明示的なクリーンアップ依頼がない限り、未使用 `ui-tester` の例外を除いて、ペインは確認可能な状態で残す。
