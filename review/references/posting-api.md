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

再チェック分類返信の `review-comments.reply` には `number`、`reply_to`（root の REST 数値 ID）、`body`、`grant` を渡す。Action は次の順序で動作する。

1. `reply_to` から root まで `in_reply_to_id` を辿り、root が対象 PR に所属することを確認する（root 解決に visited set と最大深さ 50 のガードを持つ）。
2. 対象 PR の全レビューコメントを REST で全ページ取得し、同 body・同 actor・同 root（`in_reply_to_id == root`）の返信が既にあれば `already_applied` を返して POST しない。
3. なければ root への `in_reply_to` 付きで POST する。POST は 1 回だけ試行し、レスポンスが曖昧な場合（失敗時）は改めて全コメントを再読取して exact match を adopt する（二重投稿防止）。adopt できなければ `unknown_outcome` とする。
4. POST 成功後はレスポンスの ID で再取得し、ID・URL・PR 所属・本文（file-based 比較）・actor・`in_reply_to_id` が意図どおりであることを確認する。不一致は `unknown_outcome` とし、成功 target を作らない。

baseline 入力（`baseline_comment_ids` 等）や thread 入力は渡さない。edit history の照合や GraphQL preflight も行わない。

## 再チェックの投稿と Resolve

- 再チェック返信、最新 head のフルレビュー、最終 LGTM はこの順序で行う。LGTM の投稿自体はスレッドを Resolve しない。workflow コンテキストの自動 Resolve は、LGTM 検証の成立後に [recheck.md](recheck.md) の「Workflow コンテキストの自動 Resolve」に従う別操作である。
- Resolve は明示指示があった thread だけを対象に、`SKILL.md` / [recheck.md](recheck.md) の手順に従って閉会コメントを投稿してから `review-threads.resolve` を呼ぶ。pi-issue-pr-workflow の委譲による workflow コンテキストも明示指示の一種であり、閉会コメントは `Resolved` 分類返信が兼ねる。`Partial`、`Unresolved`、`Unknown`、他者の root、ユーザー判断待ちの議論は、指示があっても対象外である。
- `review-comments.reply` の `status=ok`（投稿成功）または exact-match dedup の `already_applied` だけを分類 record（`classification_reply_id` は返されたコメント ID）として採用する。`failed`、`unknown_outcome` は今回の record に加えず、retry もしない。
- Resolve は一件ずつ行い、直前に `review-threads.read` で対象の `thread_id`・`root_comment_id`・root の `reviewer_login` が指示対象と一致することを確認し、直後に同じ thread と root を再取得して、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも再取得に失敗した場合や状態が不明な場合は成功として扱わない。

## API 固有の注意

- インラインコメントの `position` はハンクをまたいで数える従来形式の差分位置であり、ハンクごとにリセットしない。
- 返信の `reply_to` には `review-comments.read` の REST 数値 ID を使う。`review-threads.read` の GraphQL ノード ID は使わない。
- 一時ファイルはワーキングディレクトリ内に置き、不要になったら削除する。
