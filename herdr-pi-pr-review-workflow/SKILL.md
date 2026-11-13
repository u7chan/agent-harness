---
name: herdr-pi-pr-review-workflow
description: >
  PR の作成から、別ペインの独立 Pi レビュアーによるレビュー・修正ループ、検証済み LGTM、Ready までを統括する。
  「PR作ったらレビューおねがい」「PR作ってレビューして」のように PR 作成とレビューをまとめて依頼されたら使う。
  PR が既にある場合はレビュー・修正ループだけを行う。単発レビューだけなら review を使う。Herdr 必須。
---

# PR Review Workflow

現在のエージェントがユーザーからのフィードバック対応、実装、修正、調整を担当し、別ペインでは独立した Pi レビュアーだけを実行する。
Issue は必須ではない。PR がまだない場合は Draft PR の作成から始め、PR が既にある場合はそのレビューから始める。
単発レビューには代わりに [review](../review/SKILL.md) を使う。PR 作成を含まない依頼で PR を勝手に作らない。

## Boundaries

- ペイン、Pi の起動、委譲、非同期の結果返却は [Herdr](../herdr/SKILL.md) に従う。
- GitHub の読み書きはすべて [GH](../gh/SKILL.md) のディスパッチャーを使う。
- レビュー基準、再チェック、LGTM 検証、Resolve の方針は [Review](../review/SKILL.md)、特に [再チェック手順](../review/references/recheck.md) を正本とする。ここではルールを重複定義しない。
- 現在のエージェントの provider、model、thinking は変更しない。別の coordinator、`impl`、`pr-fix`、`ui-tester` を起動しない。
- レビュアーは実装・コミット・push を行わない。レビューイベントは `COMMENT` だけを使い、`APPROVE`、マージ、Issue のクローズは行わない。
- Ready は AI レビュー通過後の最終状態であり、最終ゲートは人間である。マージは行わない。ユーザーが確認後に明示的に指示した場合だけ、別操作として扱う。
- ラウンド数、head、未解決の指摘、ペイン ID は現在の会話内だけで管理する。実行状態を永続化したり、ワークフローランタイムを追加したりしない。

## Preflight

副作用のある操作に入る前に、次のすべてを確認する。失敗、不明な結果、曖昧な対象は推測せず停止する。

1. Herdr の Preflight と Caller pinning を満たし、現在のワークスペースとペインを固定する。`pi` も必須とする。
2. リポジトリの指示と Git 状態を読む。チェックアウト、作業ブランチ、HEAD を固定し、想定外の作業ツリー変更がないことを確認する。保護された base へ直接 push しない。
3. 現在の head で必須のテスト、チェック、フォーマッター、リンターをすべて成功させる。必須検証の失敗・スキップ・実行不能は `blocked` として停止する。既存の検証結果を再利用するのは、head と検証範囲を確認できた場合だけとする。
4. 対象 PR を 1 件特定する。PR が既にある場合はその PR を対象にする。PR がまだない場合、依頼が PR 作成を含むときだけ「PR 作成」節の順で Draft PR を作成する。含まない場合は停止して PR の URL または番号を求める。
5. `pr.read` で repository、base、head、state を固定する。対象は open かつ未マージでなければならず、Issue 参照では代用できない。push 済み HEAD が PR の head に一致することを確認する。PR 作成経路では `draft=true` であることも確認する。不一致、push 結果不明、取得失敗は停止する。Draft でない既存 PR は Draft 化しない。
6. PR 本文と合意済みの依頼から、変更目的、完了条件、維持すべき契約、運用・互換性要件を抽出する。口頭のフィードバック条件も委譲文に含める。重要な未決事項をレビュアーに創作させない。
7. ユーザー可視のサーフェスを変更する場合、またはリポジトリが証跡を要求する場合、[証跡契約](references/evidence.md) に従って現在の head の証跡を PR 本文の証跡節へ更新する。不要と判断した場合は理由を記録する。

### PR 作成

- 依頼が PR 作成を含むのは、「PR作ったらレビューおねがい」「PR作ってレビューして」のように作成とレビューがまとめて依頼された場合だけとする。「レビューおねがい」だけなら作成しない。
- 現在の作業ブランチを push する。push 結果が不明なら停止する。
- base はリポジトリの指示とブランチの親から決める。推測できない場合はユーザーに確認する。
- GH の `pr.create` を `draft: true` と明示的な `grant: "write"` で実行する。PR 本文はリポジトリの指示に従い、変更目的、変更内容、検証結果、ロールアウトを含める。UI 変更またはリポジトリが証跡を要求する場合は、証跡が揃っていれば [_docs/pr-evidence.md](../_docs/pr-evidence.md) の証跡節を本文に含める。PR 作成後に揃う場合は、`pr.update` で節を挿入または更新する。Issue 参照が合意済みなら Issues に書く。
- 返却された PR の番号と URL を固定し、手順 5 の `pr.read` へ進む。

## Reviewer Setup

プロファイルの保存、選択、入出力、エラーは [Pi Development Profiles](../_docs/pi-development.md) を正本とする。次のスクリプトはこのスキルの親ディレクトリ（パッケージルート）から解決する。

```bash
scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review
```

`review` ロールだけを検証・解決する。使用しないロールや `pr_fix_shared_with_impl` によって起動を妨げてはならない。
`result=ok` の仕様を再利用し、その profile、provider、model、thinking を報告する。
今回の実行で明示指定された値は、プロファイルを自動的に書き換えることなく優先する。

明示的な上書きを組み立てる場合は `pi --list-models` の正確な ID を使い、仕様全体を再検証する。

```bash
scripts/pi-development/resolve-model-spec.sh \
  --provider <provider> --model <model> --thinking <level>
```

`result=ok` の場合のみ起動する。プロファイルが存在しない、不正、未解決の場合は、有効な完全明示指定がない限り、修復または必要な入力を求めて停止する。ランタイムのデフォルトや別モデルへ黙って切り替えない。
`reason=migration-required` なら、明示指定があっても [移行手順](../_docs/pi-development-migration.md) のために停止する。
プロファイルや `active` を自動作成・保存・変更しない。

Herdr の単一ペイン手順に従う。現在のワークスペースにある空の対話シェルを優先し、なければ現在のペインから `--direction right` で分割する。右に分割できない場合は、別方向を推測せずユーザーに確認する。ワークスペース、worktree、タブは作成しない。

```bash
herdr agent start pr-review --kind pi --pane <pane-id> -- \
  --provider <provider> --model <model> --thinking <thinking>
herdr pane rename <pane-id> pr-review
```

JSON 応答から ID を読み取り、ラベルを確認する。画面とランタイム状態で対話可能なこと、実効 provider・model・thinking が確定した仕様に一致することを検証する。起動引数だけでは証拠にならない。不明または不一致の場合は委譲前に停止する。
この実行の全ラウンドで同じレビュアーを使う。

## Review and Fixes

Herdr の `scripts/parent-delegate-async.sh` で委譲し、`scripts/child-return-result.sh` で結果を返す。委譲後はターンを終了し、`--wait` や長時間の `sleep` ポーリングで親をブロックしない。
委譲文には、リポジトリの絶対パス、指示、PR、base/work ブランチ、head、ラウンド、目的、完了条件、運用・互換性要件、検証結果、読み取り専用の責務、期待する報告を含める。

1. **Round 1**：Review スキルの PR モードを明示的に依頼する。GitHub へのレビュー投稿とその検証を必須とし、`completed` または `blocked` の報告にレビュー ID/URL、レビュー対象 head、指摘件数、Blocker、検証済み LGTM 状態を含めさせる。プロンプトの送信や未検証の LGTM 申告だけでは完了としない。
2. **Fixes**：Blocker が残る場合、現在のエージェントが投稿済みフィードバックを読み、スコープを拡大せず修正する。必須検証をすべて通し、コミット、push を行い、リポジトリの指示に従って該当コメントに返信する。修正を push したという理由だけでスレッドを Resolve しない。push 結果が不明、または検証失敗の場合は先に進まない。
3. **Round 2 / Round 3**：修正 push の確認後、同じレビュアーに [再チェック手順](../review/references/recheck.md) を明示的に依頼する。以前の未解決指摘の再分類と、同手順で定める範囲における最新 head のレビューの両方を実施させる。分類返信だけでは LGTM としない。運用・互換性要件を引き継ぐ。
4. 再チェック委譲時に workflow コンテキストの auto-resolve を明示的に指定する。対象判定、返信確認、対象、軽量チェックは正本の再チェック手順に従う。引き継ぎ時には検証済み対象の組 `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` を要求し、その組を正本とする。新たな読み取り結果から対象を再構築しない。各 Resolve 後に `review-threads.read` で `resolved=true` を確認する。

初回を含め、レビューは最大 3 ラウンドとする。最新 head で Blocker のない検証済み LGTM が得られたら、polish の対象を確認し、対象がなければ完了処理へ進む。Round 3 後も Blocker があれば Draft のまま停止し、残存条件と証拠を報告する。通常のラウンドを追加しない。
`blocked`、重大な不確実性、head の変更、未確認の書き込みでも停止する。Nit / Consider / FYI や別 Issue 候補だけでは、Review スキルが認めた LGTM を妨げない。

### Polish

LGTM 後に Nit または Consider が残り、次のすべてを満たす場合だけ、1 回の push でまとめて修正し、同じレビュアーに再チェックを依頼できる。FYI は対象外とする。

- 修正対象が今回の差分とその直接の周辺に限定され、新規ファイル、依存、公開 API、スキーマ、互換挙動の変更を含まない。
- 設計判断や仕様変更を伴わない。
- 修正後に必須検証をすべて通せる。
- レビュアーが解消条件を具体的に示している。

polish は最大 2 回とする。修正 push 後の再チェックで最新 head の LGTM を取り直すまでを 1 回と数える。ラウンド計数は [再チェック手順](../review/references/recheck.md) に従い、委譲文に `round_kind=polish` と `polish_round=<1|2>` を含め、レビュー本文には `Round 4/5` または `Round 5/5` として記録する。Blocker 修正と同じ push で直せる Nit は、polish を消費せず同梱する。
再チェック後の Nit / Consider の件数が前ラウンドより減っていなければ停止する。polish 中に Blocker が出た場合は、通常ラウンドへ戻さず、その時点で Draft のまま停止する。スコープの拡大、同じ指摘の再発、head 不明、検証失敗でも停止する。

## Completion and Ready

このレビュー・修正・Ready ワークフローの実行依頼には、次の条件を満たした後の `pr.ready` も含まれ、追加の承認待ちは不要。単発レビューの依頼では Ready を許可しない。既に Ready の PR では `pr.ready` を実行しない。

1. 現在の PR head で必須検証がすべて成功し、push が確認されている。
2. 最新 head に対して投稿・検証済みの Review スキルの LGTM があり、Blocker がない。
3. 最新の再チェックで得た Resolve 対象をすべて処理し、再読込で確認している。それ以外の会話は開いたまま報告する。LGTM そのものは全スレッドの Resolve を許可しない。
4. **Ready の直前**に `pr.read` で open、未マージ、head が検証結果と LGTM の対象に一致することを確認する。UI 変更またはリポジトリが証跡を要求する場合は、[_docs/pr-evidence.md](../_docs/pr-evidence.md) の完了ゲートに従って、本文の証跡節が現在 head を指し、pass 項目の画像参照があることも確認する。不一致・失敗・不明なら停止する。Draft でなければ `pr.ready` を実行せず、手順 6 へ進む。
5. GH ディスパッチャーの `pr.ready` は Draft のときだけ、対象と明示的な `grant: "sensitive-write"` を指定して実行する。既に Ready なら実行しない。
6. **Ready の直後**（既に Ready だった場合は手順 4 の後）に `pr.read` を実行する。open、未マージ、`draft=false`、同じ head が確認できて初めて完了とする。`failed`、`unknown_outcome`、head 変更は成功として扱わず、自動リトライしない。
7. Ready 後は停止する。マージは行わない。最終ゲートは人間であり、人間が確認してマージする。AI にマージさせる場合も、このスキルの完了条件には含めず、別の明示的な指示として扱う。

PR、プロファイル由来か明示指定か、レビュアー仕様とペイン、最新 head、検証、通常ラウンド数と polish 回数、LGTM、Resolve 結果、残った任意の指摘・会話、別 Issue 候補、Ready 状態を報告する。証跡節を更新または再利用した場合は、その head と再利用元も報告する。レビュアーペインは開いたままにする。マージは人間の最終ゲートであることも伝える。
スキルを変更する PR の場合は、マージ後の [ロールアウト](../_docs/skill-distribution.md) も案内する。
