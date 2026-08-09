# Posting API

GitHub Action の入力、出力、permission は `gh/actions.json` を正本とし、すべて `gh/scripts/gh.sh` 経由で実行する。この文書にはレビュー固有の接続規則だけを置く。

## 取得

`pr.read` で対象と head SHA を固定してから、差分、ファイル、会話コメント、既存レビュー、review comment、review thread を該当する read Action で取得する。同じ原因、条件、影響を扱う既存の指摘は重複して投稿しない。

## 投稿

- 本文は一時ファイルに保存し、`jq --rawfile` で payload を組み立てる。シェル引数には本文を埋め込まない。
- inline finding は `reviews.create` の `comments` にまとめる。差分行に付けられない指摘だけを review body に置く。
- payload を `review/scripts/validate-review-payload.sh reviews.create <payload-file>` で検査してから投稿する。
- 再チェック返信は `review/scripts/validate-review-payload.sh review-comments.reply <payload-file>` で検査してから投稿する。
- 投稿直前と投稿後の確認は、`SKILL.md` の安全条件に従う。

## API 固有の注意

- inline comment の `position` は hunk をまたいで数える Legacy diff position であり、hunk ごとにリセットしない。
- 返信の `reply_to` には `review-comments.read` の REST 数値 ID を使う。`review-threads.read` の GraphQL node ID は使わない。
- 一時ファイルはワーキングディレクトリ内に置き、不要になったら削除する。
