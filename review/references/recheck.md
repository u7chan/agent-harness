# 再チェック手順

## 決定的なスナップショットと責任境界

Review skill は元 finding の再評価、分類理由、full review、LGTM 可否、ラウンド制御を担当する。取得・投稿・mutation は `gh` Action が担当し、分類や LGTM policy を Action に実装しない。skill は各 read Action の結果を、ネットワーク・時刻・永続 state に依存しない `review/scripts/recheck-state.py` に渡して判定する。

helper の入力は次の操作を持つ JSON である。

- `parse`: current output template の direct reply の strict header だけを `Resolved`、`Partial`、`Unresolved`、`Unknown` として認識する。
- `reconcile`: `review-threads.read` の出力を正規化し、thread ごとの root、tail、コメント一覧を持つ canonical snapshot を返す。ID 欠落・重複、root が一意でない、直接 root への返信でない、pagination が不完全な場合は `stop` になる。REST との相互照合は行わない。
- `plan`: 対象 thread の root が自分の指摘か、未 Resolve か、同じ分類の返信が既に tail にあるか（同 actor・同 root・同分類 = plan レベルの dedup）を判定し、`reuse`（投稿不要）か `post`（投稿する）を返す。対象の特定に失敗した場合は `stop` になる。
- `gate`: 分類返信の record と最新 head の full review 結果から LGTM 可否を判定し、`lgtm_eligible` か `blocked` を返す。

各 record は実行中だけ次を保持し、ファイルや再起動後へ持ち越さない。

```text
thread_id, root_comment_id, reviewer_login, classification,
classification_reply_id, verification_head_sha
```

`verification_head_sha` はその分類返信を再評価した時点の head SHA である。edit history や snapshot checkpoint は使わない。

## 対象と初期スナップショット

- 明示的に再チェックを依頼された場合だけ実行する。初回レビューを Round 1、再チェックを Round 2、Round 3 と数え、最大 3 ラウンドまで行う。Round 3 を終えても Blocker が残る場合は追加で投稿せず、Draft のまま報告する。
- `pr.read` で対象の repository、PR 番号、開始時の head SHA を固定し、`review-threads.read` は全ページ取得する。途中で head が変わった場合は、そのスナップショットを最新 head として扱わず、再取得した head を対象に確認をやり直す。
- 再分類の候補は、初期取得時に `resolved == false` で、同じ PR の同じレビュースレッドにある次のすべてを満たす root comment だけとする。ここで `reviewer_login` は API の `user.login` を正規化した値である。
  1. `in_reply_to_id == null` の root である。
  2. `review-threads.read` の `database_id` と `review-comments.read` の数値 ID が一致する。
  3. root の `reviewer_login` が今回のレビュアー自身である。
  4. ユーザー判断待ちの議論ではなく、今回再チェックする自分の指摘である。
- Resolve 済みのスレッド、他者の root comment、別の会話、ユーザー判断待ちの議論、root を一意に特定できないものは候補にしない。対象の組 `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` は今回の実行中だけ保持し、ファイルや永続状態には保存しない。

## 判定と返信

元のコメントから発生条件、原因、問題となる挙動、影響を再構成し、現在も同じ失敗経路に到達するかを確認する。テストを追加しただけでは、解消の根拠としない。

- **Resolved**: 元の失敗条件が閉じ、同じ原因から問題となる挙動へ到達しない。
- **Partial**: 一部の条件は閉じたが、元コメントの別の入力、状態、経路が残る。
- **Unresolved**: 元の失敗条件または影響が残る。
- **Unknown**: コード、実行条件、仕様、権限の情報が不足しているため判定できない。

候補を一意に特定できた場合だけ、[output-templates.md](output-templates.md) の対応する返信を root comment への同じレビュースレッドに投稿する。返信結果は次の 3 種だけを区別する。

- **投稿成功**: `review-comments.reply` の `status=ok`。返信を投稿し、レスポンスの再取得で本文・投稿者・root への `in_reply_to_id` を検証できた。
- **already-applied**: `status=already_applied`。同 body・同 actor・同 root の返信が既に存在するため投稿しなかった（リトライや二重実行の結果）。返された既存コメント ID を `classification_reply_id` として採用してよい。
- **stop**: `status=failed` / `unknown_outcome`（投稿失敗で再読取しても exact match を adopt できなかった場合など）。同じ run で retry せず、Resolve の対象にもしない。

`plan` が `reuse` を返した場合は投稿せず、既存の tail 返信を今回の分類 anchor として記録する。`Partial`、`Unresolved`、`Unknown` の返信は分類として記録してもスレッドを Resolve しない。root の特定自体が曖昧な場合は `Unknown` として返信せず、Resolve もしない。

## 最新 head のフルレビュー

- 対象候補の分類返信を終えた後、`pr.read` で head SHA を再確認し、その SHA の差分、影響範囲、関連テストを初回レビューと同じ深さでレビューする。再チェック中に新しく見つけた論点や fix が導入した回帰を対象外にしない。
- 既存 Blocker がすべて `Resolved` と確認でき、かつ最新 head のフルレビューで新しい Blocker がない場合だけ、最新 head に固定した `reviews.create` の `COMMENT` レビューで `LGTM` を投稿する。`Partial`、`Unresolved`、`Unknown` の既存 Blocker、フルレビューで判断できない Blocker、または新しい Blocker が一つでもあれば LGTM を投稿しない。
- LGTM の投稿前に payload を検証し、投稿後に対象、本文、head SHA、レビュー状態を再取得して検証する。検証できた LGTM だけを LGTM として報告し、失敗・不明な場合は LGTM として報告しない。

## 安全な投稿順序

### 1. 返信と分類

初期スナップショットから候補を一意に特定し、各 root comment に今回の分類を materialize する（`reuse` は過去の返信を現在 head の証明として扱わず、今回の再検証結果を既存 anchor に結び付けるだけである）。投稿成功または already-applied の返信について `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` を record として保持する。

### 2. 最新 head のフルレビュー

最新 head を再取得して全体をレビューし、新しい指摘を通常のレビュー結果に含める。Blocker が残る、または重要な判定が `Unknown` の場合は LGTM を投稿しない。

### 3. 検証済み LGTM

Blocker がないことを確認した後でだけ、固定した最新 head に対する `COMMENT` の LGTM を投稿し、レスポンスを再取得して PR、本文、commit、レビュー状態が意図どおりであることを確認する。LGTM は「レビューが通った」記録であり、スレッドを自動的に Resolve しない。

## 明示指示による Resolve

Resolve は「この会話は終わった」記録であり、LGTM とは独立した操作である。明示指示があった thread だけを対象に行い、自動 Resolve は、委譲タスクで自動 Resolve を明示指定された場合（workflow コンテキスト、次節）を除いて行わない。

1. ユーザーが Resolve を明示指示した thread だけを対象にする。`Partial`、`Unresolved`、`Unknown`、他者の root、ユーザー判断待ちの議論は、指示があっても Resolve しない。
2. Resolve の前に、そのスレッドに閉会コメント（対象の会話と判断を要約した返信）を投稿する。投稿には `review-comments.reply` を使い、投稿成功または already-applied を確認する。
3. `review-threads.read` で対象の PR、`thread_id`、`root_comment_id`、root の `reviewer_login` が指示の対象と一致することを確認する。対象不一致、取得失敗、root の特定不能なら Resolve しない。
4. 対象がまだ未解決なら `review-threads.resolve` を実行し、直後に同じ対象を再取得して、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも、この再取得を通らなければ成功と数えない。
5. `failed`、`unknown_outcome`、取得失敗、状態不一致は成功として扱わず、その thread を未解決または不明として報告する。結果不明のまま再試行しない。

この方針により、LGTM のない自動 Resolve、単なる push を根拠にした Resolve、対象を取り違えた Resolve は設計上存在しない。明示指示がなく、workflow コンテキストの委譲（次節）による自動 Resolve の指定もないすべてのスレッドは、`Partial`、`Unresolved`、`Unknown`、他者の投稿、ユーザー判断待ちを含め、未解決のまま保持する。

## Workflow コンテキストの自動 Resolve

再チェックの委譲タスクが自動 Resolve を明示的に指定した場合（workflow コンテキスト）に限り、次の条件をすべて満たす thread だけを自動で Resolve できる。それ以外（workflow 外・手動フロー）は前節のとおり明示指示のみで、自動 Resolve はしない。

- 対象: この run の再チェックで root が自分の指摘・未 Resolve と確認でき、tail に `Resolved` 分類の返信がある thread（投稿成功、already-applied で採用した既存返信、plan の `reuse` anchor を含む）。`Partial`、`Unresolved`、`Unknown`、他者の root、ユーザー判断待ちの議論は対象にしない。
- 前提: LGTM 検証が成立していること（`gate` が `lgtm_eligible`）。LGTM 自体が Resolve を意味するわけではなく、返信の確認と軽量チェックは独立に行う。
- 手順:
  1. fresh read（`review-threads.read`）で、① thread が対象 PR に属し未解決であること、② tail の返信が review 担当自身の `Resolved` 分類であること、の 2 点を確認する。この 2 点が確認できた thread だけを対象にする。
  2. `review-threads.resolve` で解決し、直後に同じ対象を再取得して、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも、この再取得を通らなければ成功と数えない。
  3. `failed`、`unknown_outcome`、取得失敗、対象不一致は成功として扱わず、その thread を未解決または不明として報告する。結果不明のまま再試行しない。
- 軽量チェックのみ: 事前条件は上記 2 点の確認と `review-threads.resolve` の検証だけにする。Resolve 判定に追加のスナップショット検証や run をまたぐ状態を持ち込まず、廃止した機構も再導入しない。

workflow では `Resolved` 分類返信が閉会コメントを兼ねる。前節の手動フローと異なり、Resolve のために追加の返信を投稿する必要はない。

## レビュースレッドの特定

1. `review-threads.read` の `database_id` と、`review-comments.read` で取得したルートコメントの数値 ID を照合する。
2. `database_id`、GraphQL node ID、reply target のいずれかが欠落・重複・不一致なら `Unknown` / `STOP_UNKNOWN` とし、semantic reuse の path/line fallback は使わない。`path`、`line`、`outdated` は finding の補助確認に限り、ID の代用にしない。
3. 投稿した分類返信の ID をスレッドのコメント一覧で確認し、root comment、同じレビュアー、今回の `Resolved` 分類の三者が同じ会話に属することを検証する。

## 報告

ラウンド、最新 head SHA、フルレビュー結果、分類返信件数（投稿成功 / already-applied / stop を別集計）、検証済み LGTM の有無、Resolve（明示指示 / workflow コンテキスト）の成功・未解決・不明件数を簡潔に伝える。Resolve の失敗や結果不明を成功件数に含めず、対象外として保持した `Partial`、`Unresolved`、`Unknown`、他者のスレッド、ユーザー判断待ちの議論も明示する。

workflow コンテキストで自動 Resolve が指定された run では、reviewer が自分で Resolve せずオーケストレーターへ引き渡す場合（handoff）、報告に対象 thread ごとの verified target set として `(thread_id, root_comment_id, reviewer_login, classification_reply_id)`（「レビュースレッドの特定」の組と同一）を必ず含める。オーケストレーターはこの報告された組を対象の正とし、fresh read から対象を再構成しない。オーケストレーター側の完了確認は、`review-threads.resolve` の実行後に `review-threads.read` で各対象を再取得し、対象が一致したまま `resolved=true` であることを確認することである。
