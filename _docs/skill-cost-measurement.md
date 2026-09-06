# スキルコスト計測の基準

- ステータス: 計測基準(ドラフト)。実運用セッションの集計結果はまだない
- 対象: 代表タスク単位の token・tool step・API 数の記録と before/after 比較
- 関連: [_docs/skill-testing.md](skill-testing.md)(検証手順)、[_docs/architecture.md](architecture.md)(構造制約)
- 非ゴール: 全モデルのベンチマーク、根拠のない一律ステップ上限、review 担当の独立性や必須テストの削除、workflow state machine の追加、dashboard / telemetry runtime の新規作成

## 位置づけ

Issue #157 の**計測候補**。採否・着手時期は未定。実運用セッションの token usage・tool trace はこの基準の確立時点で集計していないため、「異常なトークン消費が起きている」「何% 削減できる」といった断定は、計測値が出るまで行わない。

既存資産は Action / helper の契約テストと手動 smoke 手順のみで、代表タスク単位の比較基準がなかった。この文書は (1) 記録スキーマ、(2) 計数の定義、(3) 比較可能性の規則、(4) オフライン集計スクリプトの使い方を定め、skill 挙動自体は変更しない。

## 代表タスク

同じタスク群を繰り返し実行して比較する。3 件とも実運用の skill・workflow をそのまま使い、計測のための別経路は作らない。

- **T1: 単一 Issue の read。** orchestrator が 1 つの Issue を `issue.get` で読み、内容を 1 段落で要約して終える。実装・レビューはしない。
- **T2: 小さな PR の初回レビュー、指摘なし。** 既存の小さい Draft PR を対象に review skill の通常フローを実行する。指摘が 1 件も出ない対象を選び、recheck・Resolve は発生させない。
- **T3: Blocker 1 件の fix → 再チェック → Resolve。** 指摘 1 件(Blocker)に対し impl 兼 pr-fix 役で修正し、recheck を通し、明示指示で該当 thread を Resolve するまで。単一エージェントで完結する形を基本とし、workflow 委譲を併用する場合は役割(ファイル)を分けて記録する。

各タスクの記録には次のメタを添える: skill revision(下記「比較可能性」)、対象の規模(タスク入力の文字数・PR diff 行数など計測者が決めて記録する値)、provider / model / thinking、成否(タスクが目的を達成したか、途中で blocked になったか)、実行日時。

## 記録スキーマ

1 タスク実行 = 計測レコード 1 件(マークダウンの表か JSON オブジェクト)。列は次のとおり。

| 項目 | 内容 | 取得方法 |
|---|---|---|
| 実行 ID / 日時 | 計測者が採番 | 手動 |
| タスク | T1 / T2 / T3 と対象(Issue 番号・PR 番号) | 手動 |
| 入力規模 | プロンプト文字数、対象 diff 行数など | 手動 |
| skill revision | 使用したスキルのピン留め SHA(または worktree の git SHA) | `git rev-parse` |
| provider / model / thinking | 例: `zai / glm-5.3-flash / max` | セッション先頭の `model_change`・`thinking_level_change` |
| 成否 | completed / blocked / 中断 | 手動判定 |
| token | input / output / cacheRead / cacheWrite / reasoning(セッション合計と per-model) | スクリプト |
| 3 計数 | LLM tool calls / gh CLI 起動 / HTTP・API リクエスト(下限) | スクリプト |
| bytes | 読み込んだ文書・API 結果の概算 bytes、再取得回数 | スクリプト |
| 経過時間 | セッション先頭〜末尾の秒数 | スクリプト |
| 親子構成 | 親セッションと子セッションのファイル一覧と役割 | 手動(下記「token の取得方法」) |
| ステップの検証目的 | 各主要ステップが何を検証したか(例: 「書き込み後の実体確認」)。安全確認を単なる重複として削らない | 手動 |

## token の取得方法

pi はセッション単位で JSONL を書く(1 セッション = 1 エージェント役割)。集計はログから行い、推測で値を作らない。

- assistant message の `usage` が 1 回の API 呼び出しの実績: `input` / `output` / `cacheRead` / `cacheWrite` / `reasoning` / `totalTokens` / `cost.total`。これをセッション内で合計する。取得できる項目だけを記録し、欠けている項目は「なし」と記録する(0 をでっち上げない)。
- **親子の区別**: 親と子は別セッションファイル。ファイル単位で役割を付け(例: orchestrator / impl / review)、ファイルごとの値と、全ファイル合計(総量)の両方を出す。どの子がどの親に属するかはログからは確定しないため、計測者が対応を記録する。
- compaction が起きたセッションは先頭のエントリが削除され、usage 合計・経過時間は**切り詰め後の範囲**になる。`compaction` エントリ自体の `usage`(要約呼び出しの消費)と `tokensBefore` は合計に含め、「compaction 後の値である」ことをレコードに明記する。
- セッション途中で `model_change` があった場合は per-model の内訳で記録する(重いモデルをどこに使うべきかの判断材料)。

## 3 計数の定義

LLM のツール呼び出し、gh CLI 起動、HTTP / API リクエストを混ぜない。それぞれ意味が違う。

1. **LLM tool calls**: assistant message の `toolCall` 要素数。リトライも別の呼び出しとして数える。種別別(read / bash / fetch_content 等)の内訳を保持する。
2. **gh CLI 起動**: bash ツール呼び出しのうち gh スキルの dispatcher(`gh.sh`)を起動しているもの。アクション別に数える(`issue.get`・`pr.read`・`review-threads.read` 等)。生の `gh` コマンドの直接起動は別枠で数える。
3. **HTTP / API リクエスト**: セッションログは gh CLI 内部の HTTP リクエストを記録しない。**下限**として数える: ネットワーク系ツール呼び出し(`fetch_content` / `web_search` / `source_check`)+ gh dispatcher 起動数 + 生 `gh` コマンド数。各起動は少なくとも 1 つの API リクエストを伴うため、これ未満にはならない。gh CLI 内部のページネーション等は含まれないことを明記する。

## オフライン集計スクリプト

`python3 <checkout>/_docs/scripts/skill-cost.py [--json] <セッション.jsonl> ...`

- 入力: 1 つ以上の pi セッション JSONL。複数ファイルは「セッション(役割)ごと + 総量」で出力する。
- 出力(セッションごと): session id / version、経過時間、per-model と合計の token、compaction の回数と tokensBefore、tool call 種別別回数、gh dispatcher 起動数(アクション別)、同一 (アクション, 対象) の再取得、raw gh・handoff 返却の回数、ツール結果の概算 bytes(doc_read / gh_api / bash_other / network_tool 別)、同一対象の再読み込み(read の同一 path、fetch の同一 URL)、エラー数(tool result の `isError`、assistant の `errorMessage`)、stop理由の分布。
- 実装は python3 標準ライブラリのみ。単発 CLI・決定的動作。デーモン・常駐・ネットワークアクセス・永続化はしない。
- テスト: `bash <checkout>/_docs/tests/skill-cost/run.sh`(合成 fixture のみ。実セッションの断片はコミットしない)。

## 比較可能性の規則

- before / after は**同じタスク・同じ対象**で行う。T1〜T3 の対象(Issue・PR)が変わるなら、入力規模の差をレコードに記録して読み手が補正できるようにする。
- provider / model / thinking を変えたら別の比較とする。1 変数ずつ変える。
- skill revision を必ず記録する。ピン留めクローンの SHA か、検証用 worktree の git SHA。revision が違う比較は「参考値」扱いにする。
- 1 回の計測はノイズを含む。差が小さい場合は繰り返し実行して傾向を見る。
- キャッシュの影響(cacheRead)が大きい条件(直前の実行で暖まったキャッシュ)とそうでない条件を混ぜない。

## コスト所在の切り分け

計測値から「コストがどこにあるか」を説明するための対応。

| 所在 | 手がかり |
|---|---|
| 文書読込 | `read` ツール呼び出し数と doc_read bytes、同一 path の再読み込み |
| 委譲 | 子セッションファイルの token 合計、親セッションの handoff 返却呼び出し数 |
| 探索 | bash 系呼び出し数と bash_other bytes、`fetch_content` / 検索系の回数 |
| GitHub 確認 | gh dispatcher 起動数(アクション別)と gh_api bytes、同一 (アクション, 対象) の再取得 |

同一対象の再取得が多い場合は、その対象がどのステップの何を検証するための再取得かを確認する。書き込み後の実体確認(エンベロープの再読み込み)など安全確認は目的があるため、単なる重複として削る前に目的を記録する。

## 削減案の選別と「変更しない」判断の記録

- 削減案は**測定された差**だけを根拠に採否する。同一条件の before / after で差が確認できた案のみ候補にする。差が小さい・再現しない案は採らない。
- 効果が大きい案から着手し、1 度に 1 変数ずつ変えて再度計測する。
- **採らない・変更しない判断もレコードに残す**: 案、根拠となった数値、採らない理由(差が小さい / 安全確認を削ることになる / runtime の追加が必要など)。計測レコードの末尾に「判断」節として追記する。
- skill 挙動の変更は本基準のスコープ外。変更が必要になった場合は、その時点で別 Issue を立て、この基準の before / after を添える。

## soft budget と人間への判断返し(検討事項)

phase ごとの soft budget(例: 探索に使う目安)や、予算超過時に人間へ判断を戻す条件は**検討事項**として扱う。本基準では機構を作らない(強制しない)。計測が積み上がり、代表タスクの分布が見えてきた時点で、分布を根拠に再検討する。上限値を先に決めて後から根拠を探さない。

## 実ログの扱い

- 実セッション JSONL はコミットしない。計測はローカルで行い、PR や計測レコードには数値の要約だけを載せる。パスは `<checkout>` 等のプレースホルダで書く。
- fixture は完全に合成データとし、実セッションの断片を含めない。
