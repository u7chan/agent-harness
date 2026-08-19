# 投稿 API

GitHub Action の入力、出力、`permission` は `gh/actions.json` を正本とし、すべて `gh/scripts/gh.sh` 経由で実行する。この文書にはレビュー固有の接続規則だけを置く。

## 取得

`pr.read` で対象と head の SHA を固定してから、差分、ファイル、会話コメント、既存レビュー、レビューコメント、レビュースレッドを該当する `read` Action で取得する。同じ原因、条件、影響を扱う既存の指摘は重複して投稿しない。

## 投稿

- 本文は一時ファイルに保存し、`jq --rawfile` でペイロードを組み立てる。シェル引数には本文を埋め込まない。
- インライン指摘は `reviews.create` の `comments` にまとめる。差分行に付けられない指摘だけをレビュー本文に置く。
- ペイロードを `review/scripts/validate-review-payload.sh reviews.create <payload-file>` で検査してから投稿する。
- 再チェック返信は `review/scripts/validate-review-payload.sh review-comments.reply <payload-file>` で検査してから投稿する。
- 投稿直前と投稿後の確認は、`SKILL.md` の安全条件に従う。

## 再チェックの投稿と Resolve

- 再チェック返信、最新 head のフルレビュー、最終 LGTM、スレッドの Resolve はこの順序で行う。LGTM の投稿と対象・本文・commit・レビュー状態の検証が終わるまで `review-threads.resolve` を呼ばない。
- 自動 Resolve の対象は、同じ PR の `thread_id`、root の数値 `root_comment_id`、root と今回の返信の `reviewer_login`、今回新規に確認した `recheck_reply_id` が一致し、返信本文が `Resolved` の候補だけに限る。`Partial`、`Unresolved`、`Unknown`、他者の root、ユーザー判断待ちの議論は対象外である。
- `review-comments.reply` が `status=ok` を返した場合だけ、返された ID を保存し、`review-comments.read` と `review-threads.read` で本文、投稿者、root への `in_reply_to_id`、thread の所属を再確認する。`already_applied`、`failed`、`unknown_outcome` は今回の自動 Resolve 対象を増やさない。
- Resolve は一件ずつ行い、直後に同じ thread と root を再取得して、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも再取得に失敗した場合や状態が不明な場合は成功として扱わない。

## API 固有の注意

- インラインコメントの `position` はハンクをまたいで数える従来形式の差分位置であり、ハンクごとにリセットしない。
- 返信の `reply_to` には `review-comments.read` の REST 数値 ID を使う。`review-threads.read` の GraphQL ノード ID は使わない。
- 一時ファイルはワーキングディレクトリ内に置き、不要になったら削除する。
