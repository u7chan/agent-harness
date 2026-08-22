# 再チェック手順

## 決定的なスナップショットと責任境界

Review skill は元 finding の再評価、分類理由、full review、LGTM 可否、ラウンド制御を担当する。取得・投稿・mutation は `gh` Action が担当し、分類や LGTM policy を Action に実装しない。skill は各 read Action の結果を、ネットワーク・時刻・永続 state に依存しない `review/scripts/recheck-state.py` に渡して判定する。

helper の入力は次の操作を持つ JSON である。

- `parse`: current output template の direct reply の strict header だけを `Resolved`、`Partial`、`Unresolved`、`Unknown` として認識する。
- `reconcile`: REST comments と GraphQL threads/comments を、GraphQL connection の順序を保ったまま ID、actor、body、reply topology、edit metadata で一意に照合し、ordered fingerprint を返す。ID 欠落・重複、片 API の欠落、pagination incomplete、topology/body/edit metadata 不一致は `stop` になる。REST にない edit history は比較せず、GraphQL `lastEditedAt` を fingerprint の正本にする。
- `plan`: 現在 head で再評価した分類と tail を比較し、`post`、`reuse`、`stop` を返す。semantic reuse は自分の同じ root への direct `Resolved` tail だけに限定する。
- `verify_reuse` / `verify_transport`: plan fingerprint と fresh fingerprint の一致、または `F0 -> expected reply 1件だけ -> F1` を検証し、`new_reply_verified`、`reused_reply_verified`、`already_applied_reply_verified`、`transport_already_applied`、`precondition_changed`、`failed`、`unknown_outcome` を区別する。
- `resolve_eligibility` / `resolve_post`: head、検証済み LGTM、root/thread/reviewer/anchor、対象 thread 単位の fingerprint、tail、未 Resolve 状態と、Resolve 後の `resolved=false -> true` 以外の差分がないことを判定する。PR 全体の snapshot checkpoint は保持するが、対象外 thread の変更は無条件に許可しない。先行する同一 run の `resolved_by_run` 結果を `this_run_resolve_records` として渡した場合だけ、その thread のコメント不変な `false -> true` delta を許可する。Resolve Action の `already_applied` は対象 thread が fresh read で検証済みの `resolved=true` になった場合だけ `already_resolved_external` とし、未解決・欠落・不一致・取得不能は fail closed にする。

各 record は実行中だけ次を保持し、ファイルや再起動後へ持ち越さない。

```text
thread_id, root_comment_id, reviewer_login, classification,
classification_reply_id, reply_source, materialization_state,
transport_outcome, verification_head_sha, plan_fingerprint,
verified_fingerprint, verified_snapshot_fingerprint
```

`verified_fingerprint` は record の対象 thread だけの fingerprint、`verified_snapshot_fingerprint` は分類返信を検証した PR 全体 snapshot の checkpoint である。`verified_snapshot` は同一 run の memory-only reconciliation に使い、再起動後へ持ち越さない。

`verification_head_sha == lgtm_commit_id == Resolve 直前の current head.sha` を満たさない record は、LGTM/Resolve eligibility に入れない。

## 対象と初期スナップショット

- 明示的に再チェックを依頼された場合だけ実行する。初回レビューを Round 1、再チェックを Round 2、Round 3 と数え、最大 3 ラウンドまで行う。Round 3 を終えても Blocker が残る場合は追加で投稿せず、Draft のまま報告する。
- `pr.read` で対象の repository、PR 番号、開始時の head SHA を固定し、`review-threads.read` と `review-comments.read` は全ページ取得する。途中で head が変わった場合は、そのスナップショットを最新 head として扱わず、再取得した head を対象に確認をやり直す。
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

候補を一意に特定できた場合だけ、[output-templates.md](output-templates.md) の対応する返信を root comment への同じレビュースレッドに投稿する。`review-comments.reply` には同じ baseline の `thread_id` と `baseline_thread_resolved` も渡し、Action は POST 直前に GraphQL の全 comment connection を再取得して baseline/current の comment set、reply topology、identity、必要 metadata、PR 所属、resolved state を照合する。`Resolved` の `reuse` は write せず、fresh snapshot で既存 tail anchor を `reused_reply_verified` として記録する。`post` の `status=ok` は expected delta を fresh REST/GraphQL snapshot で検証できた場合だけ `new_reply_verified` とする。`status=already_applied` は、同じ operation の expected delta を検証できた場合だけ `already_applied_reply_verified` として採用し、古い non-tail exact match は `transport_already_applied` のまま対象にしない。失敗、`unknown_outcome`、`precondition_changed` は同じ run で retry せず、Resolve target に追加しない。

`Partial`、`Unresolved`、`Unknown` の返信は分類として記録してもスレッドを Resolve しない。root の特定自体が曖昧な場合は `Unknown` として返信せず、Resolve もしない。他者のスレッドやユーザー判断待ちの議論に、同じレビュアーが `Resolved` と返信しても自動 Resolve の対象にはならない。

## 最新 head のフルレビュー

- 対象候補の分類返信を終えた後、`pr.read` で head SHA を再確認し、その SHA の差分、影響範囲、関連テストを初回レビューと同じ深さでレビューする。再チェック中に新しく見つけた論点や fix が導入した回帰を対象外にしない。
- 既存 Blocker がすべて `Resolved` と確認でき、かつ最新 head のフルレビューで新しい Blocker がない場合だけ、最新 head に固定した `reviews.create` の `COMMENT` レビューで `LGTM` を投稿する。`Partial`、`Unresolved`、`Unknown` の既存 Blocker、フルレビューで判断できない Blocker、または新しい Blocker が一つでもあれば LGTM を投稿しない。
- LGTM の投稿前に payload を検証し、投稿後に対象、本文、head SHA、レビュー状態を再取得して検証する。検証済み LGTM の `commit_id` を `lgtm_commit_id` として保持し、投稿後の `pr.read` で `head.sha == lgtm_commit_id` も確認する。LGTM の投稿または検証が失敗・不明な場合は、Resolve を開始せず、LGTM として報告しない。

## 安全な投稿・Resolve 順序

### 1. 返信と分類

初期スナップショットから候補を一意に特定し、各 root comment に今回の分類を materialize する。`Resolved` で、`new_reply_verified`、`reused_reply_verified`、`already_applied_reply_verified` のいずれかであり、同じ head の record だけを `(thread_id, root_comment_id, reviewer_login, classification_reply_id)` の provisional Resolve 集合に入れる。`reuse` は過去の返信を現在 head の証明として扱わず、今回の再検証結果を既存 anchor に結び付けるだけである。

### 2. 最新 head のフルレビュー

最新 head を再取得して全体をレビューし、新しい指摘を通常のレビュー結果に含める。Blocker が残る、または重要な判定が `Unknown` の場合は LGTM と Resolve を行わない。

### 3. 検証済み LGTM

Blocker がないことを確認した後でだけ、固定した最新 head に対する `COMMENT` の LGTM を投稿する。レスポンスを再取得し、PR、本文、commit、レビュー状態が意図どおりであることを確認する。この確認が終わるまで、対象集合を一つも Resolve しない。

### 4. 個別 Resolve と再取得

対象集合を一件ずつ処理する。各件で次を行う。

1. `pr.read` を Resolve の直前に実行し、対象の PR が同じで、現在の `head.sha` が検証済み LGTM の `lgtm_commit_id` と一致することを確認する。head が変化した、取得に失敗した、または一致を確認できない場合は Resolve せず、その時点で不明または未解決として報告する。
2. `review-threads.read` と `review-comments.read` を再実行し、対象の PR、`thread_id`、`root_comment_id`、root の `reviewer_login`、今回の `classification_reply_id`、返信本文の `Resolved` 分類が変わっていないことを確認する。ユーザー判断待ち、他者の root、返信の欠落、対象不一致なら Resolve しない。
3. 対象がまだ未解決なら `review-threads.resolve` を実行する。すでに解決済みなら、外部で変更された可能性として状態を検証し、対象集合との一致を確認する。複数の provisional target を逐次処理する場合、先行してこの run で `resolved_by_run` を検証した結果だけを `this_run_resolve_records` に渡す。未検証の他 thread の編集、削除、identity変更、state変更は許可しない。
4. Resolve の直後に同じ対象を再取得し、対象が一致したまま `resolved=true` であることを確認する。`status=ok` または `status=already_applied` でも、この再取得を通らなければ成功と数えない。`already_applied` で fresh target が `resolved=false` のまま、または target が欠落・不一致の場合は成功件数にも target にも加えない。
5. `failed`、`unknown_outcome`、head の取得失敗・変化、再取得失敗、状態不一致は成功として扱わず、その thread を未解決または不明として報告する。別の thread の成功で置き換えたり、結果不明のまま再試行したりしない。

この順序により、LGTM のない Resolve、単なる push を根拠にした Resolve、対象を取り違えた Resolve を防ぐ。対象集合に入らないすべてのスレッドは、`Partial`、`Unresolved`、`Unknown`、他者の投稿、ユーザー判断待ちを含め、未解決のまま保持する。

## レビュースレッドの特定

1. `review-threads.read` の `database_id` と、`review-comments.read` で取得したルートコメントの数値 ID を照合する。
2. `database_id`、GraphQL node ID、reply target のいずれかが欠落・重複・不一致なら `Unknown` / `STOP_UNKNOWN` とし、semantic reuse の path/line fallback は使わない。`path`、`line`、`outdated` は finding の補助確認に限り、ID の代用にしない。
3. 投稿した分類返信の ID をスレッドのコメント一覧で確認し、root comment、同じレビュアー、今回の `Resolved` 分類の三者が同じ会話に属することを検証する。

## 報告

ラウンド、最新 head SHA、フルレビュー結果、分類返信件数、検証済み LGTM の有無、対象集合の Resolve 成功・未解決・不明件数を簡潔に伝える。`new_reply_verified`、`reused_reply_verified`、`already_applied_reply_verified`、raw `transport_already_applied`、`precondition_changed`、`failed`、`unknown_outcome`、`resolved_by_run`、`already_resolved_external`、`unresolved`、`unknown` は別集計する。Resolve の失敗や結果不明を成功件数に含めず、対象外として保持した `Partial`、`Unresolved`、`Unknown`、他者のスレッド、ユーザー判断待ちの議論も明示する。
