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

再チェック分類返信の `review-comments.reply` には `number`、`reply_to`（root の REST 数値 ID）、`body`、`grant` を渡す。Action の結果は次の意味で扱う。

- `ok`: root への返信を投稿し、再取得で ID・URL・PR 所属・本文・actor・`in_reply_to_id` を検証できた。
- `already_applied`: 同 body・同 actor・同 root（`in_reply_to_id == root`）の返信を確認した。新しく投稿せず、返された既存コメント ID を採用できる。
- `failed`: 処理に失敗した。分類 record として採用しない。
- `unknown_outcome`: 投稿の成否または投稿後の状態を検証できない。成功と数えず、同じ run で再試行しない。

baseline 入力（`baseline_comment_ids` 等）や thread 入力は渡さない。

## 再チェックの投稿と Resolve

再チェック返信、[recheck.md](recheck.md) の範囲での最新 head のレビュー、最終 LGTM はこの順序で行う。Resolve の対象・閉会コメント・前後確認の手順の正本は [recheck.md](recheck.md) の「明示指示による Resolve」と「Workflow コンテキストの自動 Resolve」であり、この文書は API 接続上の契約だけを置く。LGTM の投稿自体はスレッドを Resolve しない。

- 分類 record として採用できる `review-comments.reply` の結果は、`status=ok`（投稿成功）と exact-match dedup の `already_applied`（`classification_reply_id` は返されたコメント ID）だけである。`failed`、`unknown_outcome` は今回の record に加えず、retry もしない。
- `review-threads.resolve` は一件ずつ呼び、直後に `review-threads.read` で同じ対象を再取得して `resolved=true` を確認する。再取得に失敗した場合や状態が不明な場合は成功として扱わない。対象との一致確認の条件は recheck.md に従う。

## API 固有の注意

- インラインコメントの `position` はハンクをまたいで数える従来形式の差分位置であり、ハンクごとにリセットしない。
- 返信の `reply_to` には `review-comments.read` の REST 数値 ID を使う。`review-threads.read` の GraphQL ノード ID は使わない。
- 一時ファイルはワーキングディレクトリ内に置き、不要になったら削除する。
