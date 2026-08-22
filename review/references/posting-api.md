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

再チェック分類返信の `review-comments.reply` には、helper が返した `plan_fingerprint`、その operation の `baseline_comment_ids`、同じ snapshot の `thread_id` と `baseline_thread_resolved` を必ず渡す。利用できる場合は `baseline_comments` も渡し、body、actor、reply target、`updated_at` の変更を Action の write preflight で検知する。REST にない `last_edited_at` の等値比較は行わず、checkpoint 間の edit metadata は GraphQL `lastEditedAt` を fingerprint の正本として検知する。Action は REST と GraphQL の comment connection を全ページ取得し、POST 直前にも baseline/current の comment set、reply topology、identity、必要 metadata、PR 所属、baseline の `resolved` state を照合する。baseline に含まれる古い exact-body reply は dedup しない。

- current snapshot が baseline と同じなら POST する。
- baseline 外の expected direct reply 1件だけなら `already_applied` を返す。
- baseline 外の nonmatching comment、複数 effect、edit/delete は `PRECONDITION_CHANGED` として POST しない。
- POST 後も baseline + returned reply 1件だけを full pagination で確認する。外部 comment が同時に見えた場合は `PRECONDITION_CHANGED` とし、成功 target を作らない。

## 再チェックの投稿と Resolve

- 再チェック返信、最新 head のフルレビュー、最終 LGTM、スレッドの Resolve はこの順序で行う。LGTM の投稿と対象・本文・commit・レビュー状態の検証が終わるまで `review-threads.resolve` を呼ばない。
- 自動 Resolve の対象は、同じ PR の `thread_id`、root の数値 `root_comment_id`、root と今回の返信の `reviewer_login`、今回確認した `classification_reply_id` が一致し、返信本文が `Resolved` の検証済み record だけに限る。`Partial`、`Unresolved`、`Unknown`、他者の root、ユーザー判断待ちの議論は対象外である。
- `review-comments.reply` の `status=ok`、または operation-scoped expected delta を検証した `already_applied` だけを helper で materialize する。返された ID を保存し、`review-comments.read` と `review-threads.read` で本文、投稿者、root への `in_reply_to_id`、thread の所属、tail、fingerprint を再確認する。historical `already_applied`、`failed`、`unknown_outcome`、`PRECONDITION_CHANGED` は今回の自動 Resolve 対象を増やさない。Resolve の `already_applied` は state-only delta を検証しても `already_resolved_external` に分類し、`resolved_by_run` に加算しない。
- Resolve record の `verified_fingerprint` は対象 thread 単位で保持し、PR 全体の `verified_snapshot_fingerprint` は別の checkpoint として保持する。複数 target を逐次 Resolve する場合は、先行 target の helper 出力 `decision=resolved_by_run` を `this_run_resolve_records` に渡す。その結果に含まれる対象 thread のコメント不変な `false -> true` だけを後続 target の fresh snapshotで許可し、未検証の他 thread の reply/edit/delete/identity/state変更は fail closed にする。
- 検証済み LGTM の `commit_id` を `lgtm_commit_id` として保持し、各 `review-threads.resolve` の直前に `pr.read` の現在の `head.sha == lgtm_commit_id` を確認する。head が変化した場合や取得結果が失敗・不明な場合は Resolve せず、未解決または不明として報告する。
- Resolve は一件ずつ行い、直後に同じ thread と root を再取得して、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも再取得に失敗した場合や状態が不明な場合は成功として扱わない。

## API 固有の注意

- インラインコメントの `position` はハンクをまたいで数える従来形式の差分位置であり、ハンクごとにリセットしない。
- 返信の `reply_to` には `review-comments.read` の REST 数値 ID を使う。`review-threads.read` の GraphQL ノード ID は使わない。
- 一時ファイルはワーキングディレクトリ内に置き、不要になったら削除する。
