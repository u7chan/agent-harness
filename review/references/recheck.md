# 再チェック手順

## 対象と初期スナップショット

- 明示的に再チェックを依頼された場合だけ実行する。初回レビューを Round 1、再チェックを Round 2、Round 3 と数え、最大 3 ラウンドまで行う。Round 3 を終えても Blocker が残る場合は追加で投稿せず、Draft のまま報告する。
- `pr.read` で対象の repository、PR 番号、開始時の head SHA を固定し、`review-threads.read` と `review-comments.read` は全ページ取得する。途中で head が変わった場合は、そのスナップショットを最新 head として扱わず、再取得した head を対象に確認をやり直す。
- 再分類の候補は、初期取得時に `resolved == false` で、同じ PR の同じレビュースレッドにある次のすべてを満たす root comment だけとする。ここで `reviewer_login` は API の `user.login` を正規化した値である。
  1. `in_reply_to_id == null` の root である。
  2. `review-threads.read` の `database_id` と `review-comments.read` の数値 ID が一致する。
  3. root の `reviewer_login` が今回のレビュアー自身である。
  4. ユーザー判断待ちの議論ではなく、今回再チェックする自分の指摘である。
- Resolve 済みのスレッド、他者の root comment、別の会話、ユーザー判断待ちの議論、root を一意に特定できないものは候補にしない。対象の組 `(thread_id, root_comment_id, reviewer_login, recheck_reply_id)` は今回の実行中だけ保持し、ファイルや永続状態には保存しない。

## 判定と返信

元のコメントから発生条件、原因、問題となる挙動、影響を再構成し、現在も同じ失敗経路に到達するかを確認する。テストを追加しただけでは、解消の根拠としない。

- **Resolved**: 元の失敗条件が閉じ、同じ原因から問題となる挙動へ到達しない。
- **Partial**: 一部の条件は閉じたが、元コメントの別の入力、状態、経路が残る。
- **Unresolved**: 元の失敗条件または影響が残る。
- **Unknown**: コード、実行条件、仕様、権限の情報が不足しているため判定できない。

候補を一意に特定できた場合だけ、[output-templates.md](output-templates.md) の対応する返信を root comment への同じレビュースレッドに投稿する。`review-comments.reply` の結果が `status=ok` のときだけ、返された `recheck_reply_id` と本文、投稿者、`in_reply_to_id`、スレッドを再取得して今回の返信であることを確認する。`already_applied` は過去の返信との重複を示すだけで今回の分類を証明しないため、自動 Resolve の対象に追加しない。失敗または `unknown_outcome` も対象に追加しない。

`Partial`、`Unresolved`、`Unknown` の返信は分類として記録してもスレッドを Resolve しない。root の特定自体が曖昧な場合は `Unknown` として返信せず、Resolve もしない。他者のスレッドやユーザー判断待ちの議論に、同じレビュアーが `Resolved` と返信しても自動 Resolve の対象にはならない。

## 最新 head のフルレビュー

- 対象候補の分類返信を終えた後、`pr.read` で head SHA を再確認し、その SHA の差分、影響範囲、関連テストを初回レビューと同じ深さでレビューする。再チェック中に新しく見つけた論点や fix が導入した回帰を対象外にしない。
- 既存 Blocker がすべて `Resolved` と確認でき、かつ最新 head のフルレビューで新しい Blocker がない場合だけ、最新 head に固定した `reviews.create` の `COMMENT` レビューで `LGTM` を投稿する。`Partial`、`Unresolved`、`Unknown` の既存 Blocker、フルレビューで判断できない Blocker、または新しい Blocker が一つでもあれば LGTM を投稿しない。
- LGTM の投稿前に payload を検証し、投稿後に対象、本文、head SHA、レビュー状態を再取得して検証する。LGTM の投稿または検証が失敗・不明な場合は、Resolve を開始せず、LGTM として報告しない。

## 安全な投稿・Resolve 順序

### 1. 返信と分類

初期スナップショットから候補を一意に特定し、各 root comment に今回の分類返信を投稿する。`Resolved` で、かつ今回新規に作成された返信だけを `(thread_id, root_comment_id, reviewer_login, recheck_reply_id)` の対象集合に入れる。

### 2. 最新 head のフルレビュー

最新 head を再取得して全体をレビューし、新しい指摘を通常のレビュー結果に含める。Blocker が残る、または重要な判定が `Unknown` の場合は LGTM と Resolve を行わない。

### 3. 検証済み LGTM

Blocker がないことを確認した後でだけ、固定した最新 head に対する `COMMENT` の LGTM を投稿する。レスポンスを再取得し、PR、本文、commit、レビュー状態が意図どおりであることを確認する。この確認が終わるまで、対象集合を一つも Resolve しない。

### 4. 個別 Resolve と再取得

対象集合を一件ずつ処理する。各件で次を行う。

1. `review-threads.read` と `review-comments.read` を再実行し、対象の PR、`thread_id`、`root_comment_id`、root の `reviewer_login`、今回の `recheck_reply_id`、返信本文の `Resolved` 分類が変わっていないことを確認する。ユーザー判断待ち、他者の root、返信の欠落、対象不一致なら Resolve しない。
2. 対象がまだ未解決なら `review-threads.resolve` を実行する。すでに解決済みなら、外部で変更された可能性として状態を検証し、対象集合との一致を確認する。
3. Resolve の直後に同じ対象を再取得し、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも、この再取得を通らなければ成功と数えない。
4. `failed`、`unknown_outcome`、再取得失敗、状態不一致は成功として扱わず、その thread を未解決または不明として報告する。別の thread の成功で置き換えたり、結果不明のまま再試行したりしない。

この順序により、LGTM のない Resolve、単なる push を根拠にした Resolve、対象を取り違えた Resolve を防ぐ。対象集合に入らないすべてのスレッドは、`Partial`、`Unresolved`、`Unknown`、他者の投稿、ユーザー判断待ちを含め、未解決のまま保持する。

## レビュースレッドの特定

1. `review-threads.read` の `database_id` と、`review-comments.read` で取得したルートコメントの数値 ID を照合する。
2. `database_id` がない場合に限り、PR、`path`、`line`、投稿者が自分のアカウントであること、`in_reply_to_id == null` を照合する。`outdated` の場合は元の位置を優先する。この代替照合でも一意にならない場合は `Unknown` とし、返信も Resolve も行わない。
3. 投稿した分類返信の ID をスレッドのコメント一覧で確認し、root comment、同じレビュアー、今回の `Resolved` 分類の三者が同じ会話に属することを検証する。

## 報告

ラウンド、最新 head SHA、フルレビュー結果、分類返信件数、検証済み LGTM の有無、対象集合の Resolve 成功・未解決・不明件数を簡潔に伝える。Resolve の失敗や結果不明を成功件数に含めず、対象外として保持した `Partial`、`Unresolved`、`Unknown`、他者のスレッド、ユーザー判断待ちの議論も明示する。
