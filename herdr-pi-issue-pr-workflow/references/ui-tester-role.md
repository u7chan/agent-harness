# ui-tester role

任意の `ui-tester` ロールの記録形式、そのロールが実行に参加するかを決めるルール、使用する環境分離の値を定める。ロールのルールは [Team specification](../SKILL.md#team-specification) と [ui-tester verification](../SKILL.md#ui-tester-verification) にある。このファイルは、参加判定、既定タスク、証跡契約、その PR 本文への反映形式、1 行の報告形式を所有する。

## Participation

参加は Kickoff gate で、Issue 本文とコメント、および対象リポジトリの規約から決める。判定は承認ラウンドを追加せず、ユーザーは同じ返信で上書きできる。次の 3 つのいずれかである。

- include — Issue、そのコメント、またはリポジトリ規約が、変更の影響を受けうるユーザー可視のサーフェス（画面、ページ、コンポーネント、レンダリングされる文書、ユーザーが受け取るメッセージ）を名指ししている。
- include — リポジトリ規約が、変更内容にかかわらず証跡を要求している。Kickoff gate でその証跡項目をタスクとして指定する。
- exclude — 変更がバックエンド、CLI、内部リファクタリングだけであり、ユーザー可視のサーフェスが名指しされていない。
- ambiguous — 材料では確定できない。ロールを含め、Draft PR の実際の差分から再判定する。

推測を積み重ねて判断に到達しない。判断を支える Issue の文面を 1 行に引用し、材料が確定しない場合は ambiguous のままにする。

Playwright の可用性も参加を決める。Playwright スキルは、`playwright/scripts/pw.sh` が存在し、`PW_BIN`（既定 `playwright-cli`）が実行可能な場合に利用できる。利用できない場合はロールを除外し、その理由を 1 行に記す。証跡が必須なのに Playwright が利用できない場合は、証跡なしで完了せず `blocked` として理由を報告する。ユーザーが指定したタスクはこれを上書きし、委譲に使う。

判定はキックオフ返信にちょうど 1 行で示す。

```text
ui-tester: 同梱（<根拠>）
ui-tester: 除外（<根拠>）
ui-tester: 同梱（曖昧: <根拠>; Draft PR の差分で再判定）
```

## Default task

タスクは、Playwright スキルを通した Issue のユーザー可視サーフェスの E2E 検証である。リポジトリ規約が証跡を要求する場合は、その証跡項目がタスクになる。今回の実行が別のタスクを指定しない場合だけ既定の E2E タスクを使うため、承認待ちにはならない。今回指定されたタスクはそのまま保持し、既定タスクで置き換えない。

## Evidence

証跡はタスクが名指しする受け入れサーフェスを証明し、orchestrator が PR 本文の証跡節へ反映する。`ui-tester` 自身は証跡を反映せず、GitHub へコメントもしない。ファイルと検証項目への対応を返し、反映は orchestrator に属する（[ui-tester verification](../SKILL.md#ui-tester-verification)）。

- 既定はスクリーンショットとする。サーフェスを証明する最小枚数（変更前と変更後の状態、または完了状態）にする。
- Before/After の静止画には、変更箇所の印を付ける。印の付け方、撮影手順、撮影後の確認は [Playwright の証跡手順](../../playwright/references/evidence.md) に従う。
- 動画は、時間に依存する主張（アニメーション、ドラッグ、複数ステップのフロー）にだけ使う。形式は WebM で、playwright-cli の既定である。
- GIF を生成せず、動画にテキストを焼き込まない。静止画の印（点線の枠と短いラベル）は可。動画は PR 本文の証跡節で短いタイムライン（`0:00-0:05 <step> / 0:05-0:12 <step>`）を返して説明する。
- すべての成果物を `PW_ARTIFACT_DIR` の下に置き、内容に基づいて名前を付ける。反映では本文の参照と添付パスが同じリテラル文字列である必要があり、動画には alt テキストがないためである。
- 添付サイズの上限は 10 MB。超える動画は、収まるまで解像度と CRF を調整して ffmpeg で再エンコードする。ffmpeg は任意で、リポジトリの依存ではない。利用できない、または再エンコード後も 10 MB を超える場合は、スクリーンショットへフォールバックし、上限超過のファイルを渡す代わりにそのフォールバックを返却に記録する。

orchestrator は本文へ反映する前にすべての成果物のサイズを確認する。

## Evidence in the PR body

orchestrator は返却された成果物を PR 本文の証跡節へ反映する。証跡コメントは投稿しない。節の形式、配置、添付、`head` の更新、再利用、`pr.read` による確認は [_docs/pr-evidence.md](../../_docs/pr-evidence.md) を正本とする。

本文は、返却が渡した全項目を列挙し、各成果物をそれが証明する項目の隣で参照する。成果物の絶対パスは返却が渡したとおりに正確に使う。

- 画像は alt テキスト付きのインライン参照 `![<what it shows>](<absolute path>)` とし、同じパスを `attachments` に `<absolute path>#<what it shows>` として入れる。
- 動画は単独の段落 `![](<absolute path>)` にしてプレイヤーとしてレンダリングし、その下に返却のタイムラインを置く。動画には alt テキストがないためである。
- すべての添付を参照する。本文が参照しないファイルは gh CLI が追加し、更新後の検証を判定不能にする。

前回の証跡節の画像を再利用できるのは、本文が新しい返却の全項目をすでに列挙している場合だけである。項目が欠けていれば新しい証跡で差し替える。修正 push で head が変わった場合は、節の `head` を最新 head に更新する。UI が変わらない場合は画像を再利用し、その旨を節に書く。

以下は項目と成果物の対応を示す例であり、節の形式は共有ドキュメントに従う。

```markdown
<!-- pi:ui-evidence:start head=<head SHA> -->

## 証跡

| 変更前 | 変更後 |
| --- | --- |
| ![<what it shows>](<absolute path>) | ![<what it shows>](<absolute path>) |

- <item>: <description>
- 対象 head: `<head SHA>`。UI 変更なしで再利用する場合は、再利用元の head も書く。

![](<absolute path to the video>)

<timeline from the return>

<!-- pi:ui-evidence:end -->
```

## Draft PR re-judgment

Draft PR が存在した後、委譲前に実際の差分から参加を再判定する。差分がユーザー可視のサーフェスを変更する場合、またはリポジトリ規約が証跡を要求する場合は委譲する。どちらにも該当しない場合は委譲せず、ペインは [Completion cleanup](#completion-cleanup) に委ねる。再判定はキックオフと同じ 1 行で報告する。

## Completion cleanup

完了時には、他の完了条件をすべて確認した後、このワークフローが作成して一度も委譲していない `ui-tester` ペインだけを `herdr pane close <pane-id>` で閉じ、ちょうど 1 行を報告する。

```text
ui-tester: <pane-id> をクローズ（未委譲）
```

ユーザーが作成したペインや、委譲を受けたペインは閉じない。実行が失敗した、または完了前に停止した場合は何も閉じない。閉じるのはその 1 ペインだけである。`herdr tab close` や `herdr workspace close` は委譲済みペインも一緒に閉じるため、このクリーンアップには使わない。

## Delegation body

本文は全ロールに適用する委譲契約を使い、次を記録する。

- Kickoff gate で設定したタスク（今回のタスク、または既定タスク）。
- 対象 PR とその head SHA。
- タスクが名指しする範囲（既定の E2E タスクならユーザー可視サーフェス）。
- [evidence](#evidence) 契約: 返す成果物、`PW_ARTIFACT_DIR` 下の場所、10 MB 上限、動画の条件、静止画の印。
- 下記の環境分離ブロック。
- 期待する返却: 検証項目ごとに 1 行、それぞれに成果物の行を付ける。

## Return report

返却は head SHA と項目ごとの 1 行を示す。各成果物の行はその上の項目に属するため、項目と成果物の対応は位置で決まる。

```text
item: <verification item>
head: <head SHA>
result: pass | fail | unverified
evidence: <command or observation>
artifact: <absolute path> | <media type> | <bytes> | screenshot | video
timeline: <start>-<end> <step> / <start>-<end> <step>
reason: <required for unverified>
fallback: video -> screenshots; <reason>
```

- `artifact:` はファイルごとに繰り返し、受け入れサーフェスが視覚的な全項目で必須である。
- `timeline:` は任意で動画専用であり、orchestrator が PR 本文の証跡節に引用するために書く。
- `fallback:` は任意で、置き換えた証跡（10 MB を超えた動画など）を記録する。

修正 push 後も、再検証した項目には同じブロックを使う。再検証の範囲は [ui-tester verification](../SKILL.md#ui-tester-verification) に定める。項目ごとの指摘は orchestrator のトリアージ用に報告へ残し、`completed` の必須チェックルールは全ロールに適用するルールである（[Delegation contract](../SKILL.md#delegation-contract)）。

## Environment separation

値は対象リポジトリの規約から取得する。ui-tester の状態を実装エージェントの状態から分離する。

| State | Variable | Note |
|---|---|---|
| pi session storage | `PI_CODING_AGENT_SESSION_DIR` | `--session-dir` が環境変数より優先する |
| Playwright session | `PW_SESSION` | 名前付きセッション。既定は `playwright` |
| Playwright artifacts | `PW_ARTIFACT_DIR` | スクリーンショット、トレース、ダウンロード |
| application state | アプリケーション自身の変数 | アプリケーションの README または実装に従う |
| application ports | アプリケーション自身の変数 | 実装エージェントが使わないポートを束縛する |
