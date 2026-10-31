---
name: herdr-pi-issue-pr-workflow
description: >
  Herdrのペインで役割ごとにPiエージェントを起動し、GitHub Issueの実装からDraft PRの最終レビューまでを統括する。
  Pi専用のIssue→PRワークフロー（チーム編成、実装、レビュー、修正）を依頼されたときに使う。
  Herdr必須。各役割のエージェントは現在のHerdrワークスペース内のペインで動作する。
---

# Pi Issue PR Workflow

ワークフローの調整だけを行う。orchestratorのペインでIssueの実装・修正はしない。

## Boundaries

既存スキルを読み、その動作を重複実装せず正本に従う。

- ペイン、Piエージェント起動、非同期委譲、結果返却は[Herdr](../herdr/SKILL.md)。
- GitHubの読み書きはすべて[GH](../gh/SKILL.md)。
- PR全体のレビュー、再チェック、会話のResolve方針は[Review](../review/SKILL.md)。

これらのスキルを安全性と操作ルールの正本とする。すべてのエージェントは現在のHerdrワークスペースとworktree内で動かす。ワークフロー専用のランタイム、永続的な実行状態、固定のprovider/model一覧を追加しない。永続化禁止の対象は現在フェーズ、レビューラウンド、レビュー済みhead、未解決Blockerなど実行ごとの進行状態である。[チームプロファイル](#team-profiles)だけはIssueの要求に基づく例外で、名前付きのチーム編成のみを保存し、実行の進行状態は保存しない。

## Local review before filing an Issue

Issue起票前に次の表を適用する。手順は[`herdr-issue-review`](../herdr-issue-review/SKILL.md)に従う。

| 変更種別 | 起票前のローカルレビュー |
|---|---|
| 新機能・大きな変更 | 必須 |
| 明白なバグ修正・小さな変更 | 省略可 |
| どちらとも判断できない | 必須 |

変更の大小は差分行数ではなく、変更規模と不確実性で判断する。新機能、新たな契約、インターフェース変更、既存動作の変更は、差分が数行でも大きな変更とする。その実行内容がそれに応じた規模になるためである。省略可能なのは誤字、リンク切れ、原因が1つに特定された障害など、報告だけで修正方法と検証方法が明らかで、レビューが作業を遅らせるだけの場合。迷ったらレビューする。

このルールは、このワークフローが起票するすべてのIssueに適用する。レビュー時に報告した別Issue候補（[Initial review](#initial-review)）も含む。ローカルレビューはPRレビューの代わりではない。`review`ロールによるPRレビューは別途必須である。

## Preflight

ワークフローの副作用を発生させる前に、次を確認する。

1. 一意に特定できるGitHub Issue参照を要求する。なければユーザーに尋ねる。
2. Herdrの事前検証を通し、Herdrスキルの条件に加えて`HERDR_WORKSPACE_ID`を必須とする。
3. `pi`を必須とし、`pi --list-models`から実際に利用可能なモデル一覧を取得する。
4. GHスキルでIssue本文と会話コメントを読む。
5. 対象リポジトリの指示とGit/worktreeの状態を確認する。

orchestrator-first方式のworktreeチームでは、orchestratorへ渡すタスク文面は[キックオフ用テンプレート](references/kickoff-task-template.md)に従う。テンプレートが定めるのはタスク文の形式だけで、チーム表と承認ルールは[Kickoff gate](#kickoff-gate)を正本とする。

リポジトリが曖昧、worktreeに想定外の変更がある、必須ツールが利用できない場合は停止する。対象を推測したり、変更を破棄したり、代替ワークスペースを作成したりしない。

## Team specification

論理ロールは`impl`、`review`、`pr-fix`で、`ui-tester`は任意の追加ロール。実際に起動するエージェントはすべてPiとする。物理エージェントの完全な仕様には、次の3つを必ず含める。

- 正確なprovider ID。
- `pi --list-models`で当該provider配下に存在する正確なmodel ID。
- そのモデルがサポートするthinkingレベル（`off`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max`のいずれか）。

`pr-fix`は独立エージェントではなく`impl`に兼務させてもよい。`review`は必ず別エージェントであり、実装を編集してはならない。`ui-tester`も独立した物理エージェントで、仕様に含まれない場合は起動しない。`ui-tester`を使わない実行には、余分なペインや条件を追加しない。`ui-tester`は実装の編集、コミット、PR編集、GitHubレビュー投稿、PRコメント投稿を行わない。指摘はorchestratorのトリアージ材料となり、再現可能な機能不具合は必須修正、それ以外は同じ修正ラウンドに含めてよい。一方、Blocker判定の正本は`review`ロールである。`ui-tester`のタスク文面、再検証、完了、環境分離は[ui-testerロール参照](references/ui-tester-role.md)に定める。

明示されたprovider/modelの組は`pi --list-models`で検証する。ただし、そのthinking列のyes/noをレベル検証に使わない。完全な仕様は次のヘルパーで解決する。ヘルパーはインストール済みPiランタイムの公開APIから当該モデルと、サポート対象およびclamp後のthinkingレベルを確認する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

出力は`provider`、`model`、`requested`、`supported`、`effective`、`result`、`thinking_level_map`を含む1行のkey=value形式で、`result=ok`以外は非0終了する。`result=ok`（実効レベルが指定レベルと一致）の場合だけ仕様確定とする。それ以外は未解決として停止する。Piのデフォルトへの無断切り替え、clampされたレベルの受け入れ、aliasの独自管理、未提供IDの推測を行わない。指定の一部欠落、不正、曖昧、非対応、clamp済みの仕様はすべて未解決とする。

## Team profiles

ユーザーが承認したチーム編成は、ユーザーが所有する名前付きプロファイルとして保存する。保存、選択、検証、ヘルパーコマンド、出力契約はスキル外の[Pi Development Profiles](../_docs/pi-development.md)を正本とする。パッケージルートから`scripts/pi-development/team-record.sh`を使う。このワークフローではロール単位の部分投影ではなく、常にチーム全体を解決する。

通常の実行ではプロファイルを書き換えない。実行限定の上書きや`ui-tester`の除外は保存済み編成を変えない。正本を変更できるのは明示的な`use`/`write`操作、および次の初期化だけ。

この実行で合意したチームを`default`として初期化（bootstrap）するのは、次の条件が**すべて**成立したときだけ。

- `result=missing`
- `reason=no-profiles`
- `profiles_present=false`
- `source=default`（`active`が存在しない）
- 実行で`--profile`が指定されていない

初期化では合意した編成を`write --profile default`で保存し、承認待ちは追加しない。`profiles_present=true`なのに選択名だけが存在しない場合、`active`が壊れている場合、明示指定のプロファイルがない場合は初期化しない。これらは提案経路に戻り、ユーザーが明示した場合だけ保存する。`profiles/`や`active`を読み取れない場合も`profiles_present=false`の例外ではない。`result=invalid`（プロファイル集合の`profiles_present`は空）となるため初期化しない。

保存するのはチーム仕様のみ。対象PRは保存しないため、再利用を妨げるのは対象PRが未確定の場合だけ。`ui-tester`のタスクも再利用条件にはしない。今回指定がなければ[ui-testerロール参照の既定タスク](references/ui-tester-role.md#default-task)が使われるため。保存済みのprovider、model、thinking、編成の各値は、今回の実行でその値が指定されていない場合だけ再利用する（[Kickoff gate](#kickoff-gate)）。

未移行の資産は初回起動時の欠落ではなく`migration-required`を返す。その上に初期化しない。継続前にバックアップを伴う手動の[プロファイル移行](../_docs/pi-development-migration.md)を行う。

## Kickoff gate

[ui-testerの参加ルール](references/ui-tester-role.md#participation)に従って`ui-tester`の参加を決め、すべてのキックオフ返信に参照先で定められた固定の1行を表示して進む。文面の正本は参照先であり、ここでは再定義しない。この判定は自動で、承認待ちを追加しない。ユーザーは同じ返信で判定を上書きできる。

ロールの割当、エージェント仕様、対象PRのどれかが未確定なら、Issueと関連リポジトリの情報を確認し、進行前にチーム全体を提案する。ユーザーが指定した有効な値はすべて維持する。

提案前に[チームプロファイル](#team-profiles)の再利用を検討する。

1. `scripts/pi-development/team-record.sh resolve [--profile <name>]`で実効プロファイルを解決する。`ui-tester`参加判定がある場合は`--require-role ui-tester`を追加する。「`fallback で`」は今回の実行のプロファイル選択なので`--profile fallback`とし、`active`は変えない。「`fallback に切り替えて`」は別操作の`use fallback`（[Team profiles](#team-profiles)）。`reason=migration-required`なら代替チームを提案せず移行のために停止する。
2. 次の条件が**すべて**成立する場合だけ、表と承認待ちを省略する。すなわち、`result=ok`で、今回の実行でprovider/model/thinkingが一切明示されず、`pr-fix`が`impl`を兼務するかどうかや独自の`ui-tester`構成も指定されていないこと（Issueから導いた参加判定、または同じ返信でユーザーが上書きした参加判定は今回の参加ロールを決めるだけで、編成の明示指定とはみなさない）、そして対象PRが確定していること。この場合はプロファイルと参加するロールを示す次の**1行だけ**と参加判定の1行を出し、[Start the team](#start-the-team)へ進む。

   ```text
   前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]
   ```

   編成はプロファイルに含まれるため、今回の実行で編成が明示されていれば再利用せず、提案と承認待ちへ進む。そうしないと今回の指定より保存済み編成を優先してしまう。参加判定の上書きは編成の明示指定ではないため、再利用経路を維持する。参加判定は出所に関係なく今回のチームだけに適用する。保存済み`ui-tester`を上書きするのは一方向だけ。参加する場合は`--require-role`によりロールのないプロファイルを`unresolved`にする。参加しない場合はロールを除いてプロファイルを再利用するが、保存済み編成から`ui-tester`は削除しない。
3. それ以外はこの節のルールに従ってチーム全体を提案し、承認を待つ。プロファイルがまったくない場合に限り、合意したチームを[Team profiles](#team-profiles)の条件で`default`として初期化する。それ以外の保存はユーザーの明示指示がある場合だけ。

提案には次の表を使う。

| Role | Assignee | Provider | Model | Thinking | Selection reason |
|---|---|---|---|---|---|

この節のチーム表と承認ルールを正本とし、[キックオフ用テンプレート](references/kickoff-task-template.md)はorchestratorに渡すタスク文面の形式だけを規定する。

モデル能力とthinkingはタスクに合わせ、必要な複雑さにだけ強い推論能力を割り当てる。不確実性とトレードオフを明示し、価格・クォータ・遅延・能力に関する根拠のない主張をしない。

標準では`impl`に`pr-fix`を兼務させる。別担当を提案するのは、専門知識が異なる、コンテキスト負荷が見込まれる、独立して理解できる領域に変更がまたがるなど、具体的な引き継ぎ上の利点がある場合だけ。その理由を提案に示す。

Issue本文とリポジトリ規約から、今回の実行で作る対象PRを決定して提案に明記する。

- 複数PR計画（例：インフラPR①のブランチを基にUI PR②を作る）がある場合、今回作るPRの位置を`対象 PR: <position>/<total>`（例：`対象 PR: 1/2`）と記載する。1回の実行で作るPRは必ず1件。複数PRのIssueは連続した実行で完了し、後続の実行では前回のロールペインを再利用する（[Sequential runs](references/sequential-runs.md)）。
- それ以外は`対象 PR: single`。
- 計画はあるが今回の位置を確定できない場合は、推測せず提案内で対象を未解決のままにし、追加の停止・承認ループを作らず既存の承認を待つ。

GitHubはdefaultブランチへ到達したコミットメッセージ中のクローズキーワードを解釈するため、その使用判断も同じ提案に含める。`close #<issue>`、`closes`、`fixes`、`resolves`などのクローズキーワードをPR本文とコミットメッセージに使うのは、今回が計画の最後のPRで、かつリポジトリ規約がキーワードを要求する場合だけ。それ以外は両方で`Related to #<issue>`などの非クローズ参照を使う。リポジトリ規約だけでは最後のPRとは判断できない。Issueに計画がない場合はクローズキーワードなしを既定とし、承認済み提案で別途定められた場合にだけ従う。スタックしたPRでbaseブランチとworkブランチが異なる場合、その差とマージ時のクローズキーワードの危険性を明記する。分割と綴りの例は[複数PRのIssue参照](references/multi-pr-issue.md)を参照する。

今回の実行で指定された`ui-tester`タスクはそのまま保持して委譲文に含め、チーム表へ列を追加しない。指定がなければ[ui-testerの既定タスク](references/ui-tester-role.md#default-task)を使い、タスクについて追加承認を待たない。

**チーム全体の提案についてユーザーの明示的な承認を待つ。** 承認前にはブランチの作成・切り替え、ペイン作成、エージェント起動、GitHub書き込みを行わない。割当がすべて有効かつ確定し、対象PRも確定した場合だけ、承認されたチームを要約して追加の承認ラウンドなしに進む。

合意済みチームは今回の実行で使い、保存プロファイルを変更しない。編成は実行限定であり、保存済み`ui-tester`の除外、`pr-fix`の分離、provider/model/thinkingの上書きは保存先に反映しない。唯一の自動保存は[Team profiles](#team-profiles)の条件によるbootstrapで、`team-record.sh write --profile default`で保存する。それ以外は明示指示がある場合だけ`team-record.sh write --profile <name>`を使い、`--pr-fix-shared-with-impl`や参加ロールの選択を含む合意済みの編成そのものを保存する。今回指定された値はプロファイルより優先し、上書きされた保存値を黙って使わず、未解決の値も保存しない。「編成見せて」の依頼では、`resolve`の出力からチーム表を表示するだけで、承認待ちも変更も行わない。

## Start the team

チーム確定後に次を行う。

1. リポジトリの現状と指示からbaseブランチを決定する。
2. 指示に従って専用workブランチを作る。既存のworkブランチは、ユーザーが明示的に選択した場合だけ使う。保護されたbaseへ直接pushしない。
3. 各参加ロールについて、このorchestratorが同一Issueの以前の実行から使っているペインを再利用できるか判断する。[Sequential runs](references/sequential-runs.md)の条件を**すべて**満たす場合だけ再利用する。満たさない、または確認できない場合は新しいペインが必要とする。判断には現在の会話だけを使う。
4. 新たに必要な物理エージェント1体につきシェルペインを1つ用意する。複数の場合はHerdrレイアウトプランナーで新規ペインをまとめてグリッドに配置し、セル順のIDを取得する。

   ```bash
   herdr/scripts/pane-layout.sh apply --count <new physical agents> --label <team label>
   ```

   `--count`は**新規ペイン数だけ**であり、再利用分を含めない。0の場合は何も作らずプランナーも呼ばない。新規が1つの場合、最小数2のプランナーは使えないため、Herdrスキルの単一ペイン規則でorchestratorのペインから分割する。
5. 各新規ペインで検証済みの値を使ってエージェントを起動する。

   ```bash
   herdr agent start <name> --kind pi --pane <pane-id> -- \
     --provider <provider> --model <model> --thinking <thinking>
   ```

6. 新規ペインには責務に基づいたエージェント名とペインラベルを付ける。再利用するペインの既存の名前とラベルは維持する。
7. 作業を送る前に、起動した各Piペインのランタイム状態を確認し、実効provider/model/thinkingが承認済みの仕様と完全一致することを検証する。不一致・検証不能なら停止する。

起動するのは参加ロールだけ。`impl`（独立させなければ`pr-fix`を兼務）と`review`は常に参加し、判定により`ui-tester`を追加する。`pane-layout.sh apply --count <new physical agents>`にはチーム総数ではなく新規ペイン数を渡す。再利用なしの場合、兼務チームは2つ、別`pr-fix`または`ui-tester`の片方を追加すると3つ、両方あれば4つとなる。部分再利用では新規数が減り、全ロール再利用なら0になる。プランナーは新規ペインを計画済みグリッドに収め、呼び出し元のタブに収まらない場合はラベル付きの新タブを作る（[pane layout](../herdr/references/pane-layout.md#tab-policy)）。そのため4ペインチームが新タブで起動する場合もある。起動結果が失敗・不明の場合、実装を開始せず、作成済みペインも自動で閉じない。観測した状態を報告する。

開始時にタスクを受け取るのは`impl`だけ。`review`と独立した`pr-fix`は担当フェーズまで待機する。`ui-tester`もDraft PR作成まで待機する。再利用する各ペインは、この実行で最初の委譲をする前にcompactする（[Sequential runs](references/sequential-runs.md)）。compactはタスクではなくTUIコマンドなので、キックオフで作業を受け取るロールの条件は変わらない。

## Delegation contract

各タスクではHerdrスキルの非同期親→子ラッパーを使用する。委譲文にロール、Issue、base/workブランチ、存在する場合はPR、リポジトリの指示、フェーズ固有の範囲、期待する報告を含める。同じworktreeを共有するからといって会話コンテキストを共有すると仮定しない。再利用したペインでも同様。compactで前回実行の事実は引き継がれないため、タスク文で渡す（[Sequential runs](references/sequential-runs.md)）。

各ロールは直接の親への結果返却ヘルパーを使い、`completed`または`blocked`を返す。報告には実施内容、検証、関係するコミットまたはPR、未解決条件を含める。プロンプト送信だけでは完了の証拠にならない。次のフェーズへ進む前にエージェントの状態と出力を確認する。orchestratorペインをブロックせずに返却を待つこと。親がツール呼び出し中は返却がキューに入るため、`sleep`を使った長いフォアグラウンドのポーリングで占有しない（Herdrの非同期委譲ルール参照）。

`completed`にはIssueとリポジトリの指示で要求される検証が**すべて実行され、成功したこと**が必要。必須チェックの失敗、スキップ、実行不能では、コマンドと結果を示して`blocked`を返す。検証が終了しただけでは進めない。

Issue、チーム割当とペインID、base/workブランチ、現在のフェーズ、PR、レビュー済みhead、レビューラウンド、未解決Blockerは現在の会話内だけで追跡する。実行状態をディスクに書かない。[チームプロファイル](#team-profiles)には編成のみ保存する。

### Implementation

`impl`に次の作業を依頼する。

1. Issueとコメントを読む。
2. Issueの範囲に限って実装し、リポジトリの指示に従う。
3. 必須のテスト、チェック、フォーマッター、リンターをすべて実行して成功させる。
4. workブランチにコミットしてpushする。コミットメッセージにはKickoff gateで決めたクローズキーワード方針を適用する。
5. GHスキルで、リポジトリ固有の必要な説明を含むDraft PRを作成する。PR本文にも同じ方針を適用する。
6. コミット、検証結果、PR番号とURLを返す。

必須検証の成功、確認済みpush、Draft PRの作成がすべて揃うまで進まない。必須検証が失敗または実行不能なら`blocked`を要求し、実装完了とはみなさず停止する。Git/GitHubの不明な結果を成功とみなしたり、無条件に同じ操作を繰り返したりしない。

### ui-tester verification

仕様に`ui-tester`がある場合、Draft PRの実際の差分をもとに[Draft PR re-judgment](references/ui-tester-role.md#draft-pr-re-judgment)で参加を再判定し、ユーザーに見える画面・操作が変更された場合だけ委譲する。`ui-tester`の作業はRound 1レビューと並行してよい。Kickoff gateで設定したタスク（今回指定されたタスク、なければ既定のE2Eタスク）を渡す。指定済みタスクを既定タスクで上書きしない。

`ui-tester`は[証跡仕様](references/ui-tester-role.md#evidence)に従って証拠を生成する。通常はスクリーンショットとし、時間経過に依存する主張だけWebM動画を使う。GIFやテキストの重ね合わせは禁止。全成果物を`PW_ARTIFACT_DIR`内に置き、添付の10 MB上限を守る。動画が上限を満たせない場合はスクリーンショットを記録された代替とする。検証項目ごとに証明する成果物の絶対パスを返す。`ui-tester`自身はコメントを含めGitHubへ投稿しない。orchestratorが投稿前にサイズを確認し、証跡を投稿する。以下の再検証も同じ証跡契約に従う。

返却された証跡は、GHスキルの`comments.create`と明示的な`grant`で、[証跡コメントの形式](references/ui-tester-role.md#evidence-posting)に従ってPRコメントとして投稿する。本文の先頭にはheadを示すマーカーを付け、全添付に言及する。投稿前にPRコメントからそのマーカーを検索する。同じheadのコメントを再利用できるのは、その本文に今回返却された全項目がすでに記載されている場合だけ。項目が追加された場合は新しいコメントを作る（`comments.update`では添付を追加できないため）。修正pushでheadが変わった場合はheadごとにコメントを分け、各レビューラウンドにつき最大1件とする。

投稿前に成果物の存在、添付可能な拡張子、10 MB以内のサイズをすべて確認する。gh CLI自身のチェックではFreeプランの10 MB制限を検出できない。`MISSING_DEPENDENCY`、`ATTACH_UNSUPPORTED`、`ATTACH_INVALID`は再試行不能な書き込み前エラー（`retryable=false`）とし、原因を報告して完了前に停止する。`unknown_outcome`は不明として扱い、PRコメントのマーカーを再確認して判断する。再確認で確定できない場合は観測した状態を報告して停止する。返却された項目に添付証拠がないまま完了を報告しない。

`ui-tester`はレビューラウンドを追加しない。その指摘はトリアージの入力となり、再現可能な機能不具合は修正必須、それ以外の指摘は同じ修正ラウンドで扱ってよい。Blocker判定の正本は`review`ロール。`ui-tester`の指摘による修正は担当`pr-fix`へ渡す。`ui-tester`の修正pushも通常の修正pushであり、既存の3ラウンドのレビュー予算を消費する。Round 3後に必須の`ui-tester`指摘が残る場合は、ラウンドを追加せず停止して報告する。

各修正push後、`ui-tester`は最新headで、報告済み項目と影響範囲に限定して再検証し、それぞれpassまたはunverifiedを報告する。`ui-tester`による有料API検証は既定で無効とし、Issueの検証ポリシーを優先する。タスク文面、再検証チェックリスト、環境分離値は[ui-testerロール参照](references/ui-tester-role.md)を正本とする。

### Initial review

`review`へPRのURLまたは番号を渡し、ReviewスキルのPRモードを明示的に依頼する。レビュアーは結果をGitHubに投稿し、レビューラウンド、headコミット、指摘件数、Blockerの有無を返す。

ユーザーが依頼した運用・互換性要件を、委譲文でレビュアーへ引き継ぐ。Reviewスキルは適用した前提をすべてのレビュー結果に記録する。別Issueの候補は指摘件数に含めず、LGTMを妨げずに報告する。

レビュアーは修正実装、PRのAPPROVE、マージを行わない。ReviewスキルがLGTMを報告した場合、Nit、Consider、FYIはワークフローを妨げない。

### Review fixes

Blockerが残る場合、担当`pr-fix`へPRと実際に投稿された指摘を正確に渡す。`impl`が`pr-fix`を兼務する場合は同じエージェントとペインを使う。

修正担当に次を依頼する。

1. GHスキルで現在のPRフィードバックを読む。
2. スコープを広げずに報告済みBlockerへ対処する。
3. 更新後のheadに必要な検証をすべて再実行して成功させる。
4. 修正をコミットしてpushする。
5. リポジトリの指示で必要な場合は該当レビューコメントへ返信する。
6. コミット、検証結果、返信、未解決フィードバックを返す。

必須検証が失敗または実行不能の場合、修正担当は`blocked`を返す。修正担当はレビュー会話をResolveしてはならない。

### Review loop

修正pushを確認した後、同じ`review`エージェントにReviewスキルの再チェック手順（`review/references/recheck.md`）を明示的に依頼し、以前の未解決指摘をすべて再チェックするとともに最新headをレビューさせる。ユーザーの運用・互換性要件も引き継ぐ。通常のPRモードだけを依頼したり、再チェックを任意にしたりしない。委譲には以前の未解決rootコメントの再分類と、正本の定める範囲での最新headレビューの**両方**を必須として記載する。再分類への返信だけではLGTMの根拠にならない。

再チェック委譲では、このワークフローのauto-resolve指定も渡す。分類返信を投稿しLGTMを検証した後、レビュアーが`Resolved`と分類したスレッドをResolveする（[Completion](#completion)参照）か、検証済み対象をorchestratorへ引き渡してからorchestratorがResolveする。Reviewスキルの再チェック参照（`references/recheck.md`の「Workflow コンテキストの自動 Resolve」）がトリガー、返信確認、軽量チェック、実行の正本となる。ワークフロー側はauto-resolveを指定するだけで、方針を再定義・再導出しない。引き継ぎ時の報告には、各対象を`(thread_id, root_comment_id, reviewer_login, classification_reply_id)`の組で含める（Reviewスキルの再チェック報告仕様参照）。orchestratorは新しい読み取り結果から対象を再導出せず、報告された集合を正本とする。各対象に`review-threads.resolve`を実行し、`review-threads.read`で読み直して`resolved=true`を確認する。

最初のPR全体レビューをRound 1と数え、合計最大3ラウンドとする。

- 最新headの検証済みレビューでBlockerがなくLGTMが投稿された場合、ワークフローを完了する。
- Round 3より前にBlockerが残る場合は、修正と再チェックを繰り返す。
- Round 3後もBlockerが残る場合は停止し、残った失敗条件と証拠を報告する。
- いずれかのエージェントが`blocked`を返した場合、そのフェーズを停止し、必要な判断または入力を求める。

HerdrやGitHubの操作の周囲に別の再試行、キュー、状態マシンを追加しない。


## Completion

Complete only when all of the following are confirmed:

- the Issue implementation is pushed to the PR head;
- every required verification has succeeded on the current PR head;
- the PR exists and remains Draft;
- the current PR head matches the commit covered by the latest verified Review-skill LGTM review (including a recheck's latest-head review under its canonical scope), with no Blocker;
- the PR body and the commit messages follow the close keyword decision for the target PR determined at the Kickoff gate;
- no required review fix remains unaddressed;
- when a ui-tester is specified only, every item it took on is either verified as passing on the current PR head or reported as unverified with its reason, and every item it passed on the current PR head has its evidence attached in that head's evidence comment, judged by reading that comment ([ui-tester verification](#ui-tester-verification)); the ui-tester condition adds to, and never replaces, the review LGTM requirement;
- every thread the latest recheck classified `Resolved` has been resolved after reply confirmation and the lightweight checks (this workflow's auto-resolve), while `Partial`, `Unresolved`, `Unknown`, other authors' threads, and user-decision discussions remain open;
- a `ui-tester` the run included but never delegated to is closed with `herdr pane close <pane-id>` and the one line in [Completion cleanup](references/ui-tester-role.md#completion-cleanup), while every pane that took a delegation stays open.

Conversation resolution follows the Review skill's Resolve policy, which is canonical in its recheck reference (`references/recheck.md`). Outside this workflow it remains explicit instruction only. Within the fix → recheck loop, auto-resolve is delegated: the recheck carries the workflow's auto-resolve designation, and after a verified LGTM the threads it classified `Resolved` are resolved by the reviewer or, on handoff, by the orchestrator using the reported verified target set, each confirmed by a `review-threads.read` re-check of `resolved=true` with the reply confirmation and lightweight checks that recheck.md defines. Every thread the latest recheck did not classify `Resolved` remains open. A verified LGTM never auto-resolves a thread by itself. Do not automatically mark the PR ready, close panes other than the unused `ui-tester` pane above, merge the PR, or close the Issue.

Close the unused `ui-tester` pane once completion is confirmed with `herdr pane close <pane-id>`: the pane this workflow created that received no delegation is closed, and the closure is reported as one line. Keep a user-created pane, a pane that received a delegation, and every pane when the run fails or stops before completion; this is the only pane closure the workflow performs on its own, and `herdr tab close` and `herdr workspace close` are never used for it, because they would close delegated panes too.

Report the Issue, the origin of the used team specification (the [effective team profile](#team-profiles) or this run's approval), the target PR position (`対象 PR: 1/2` or `対象 PR: single`, with the base branch difference when the PR is stacked), base and work branches, Draft PR, latest commit, verification, review round count, separate Issue candidates if any, unresolved optional feedback or conversations, and every created pane's role and observed state, including the `ui-tester` participation line, its Draft PR re-judgment, the closure line when one was closed, and the latest head's evidence comment when one was posted or reused. When the PR's changed files include any skill, the report must also prompt the post-merge rollout: after merging, run the rollout procedure in [_docs/skill-distribution.md](../_docs/skill-distribution.md). Leave the panes available for inspection unless the user explicitly requests cleanup, except the unused `ui-tester` pane closed above.
