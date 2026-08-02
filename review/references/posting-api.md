# Posting API Mapping

すべての GitHub 操作は `gh/scripts/gh.sh` 経由で行う。カテゴリ `pr`, `review`, `review-comment`, `review-thread`, `comment` のアクションを使用する。
入力は stdin または JSON ファイルで渡す（文字列を直接引数にしない）。

各アクションの field 定義・型・permission は `gh/actions.json` の `input_schema` / `output_schema` を正本とする。このドキュメントは操作順序・安全ルール・API 注意事項のみを記述する。

## 操作フロー

### 1. 情報収集（read）

以下の順で必要な情報を取得する。

| 順序 | アクション | 目的 |
|------|-----------|------|
| 1 | `pr.read` | PR メタデータ、head commit SHA の固定 |
| 2 | `pr.diff.read` | 差分全体 |
| 3 | `pr.files.read` | ファイル一覧 |
| 4 | `comments.read` | Issue コメント（conversation） |
| 5 | `reviews.read` | 既存レビュー |
| 6 | `review-comments.read` | 既存レビューコメント（REST） |
| 7 | `review-threads.read` | 既存スレッドと resolve 状態（GraphQL） |

入出力の詳細は各アクションの `actions.json` 定義を参照する。

### 2. レビュー投稿（write）

`reviews.create` で投稿する。payload は `actions.json` の `input_schema` に従い jq で構築する。

```bash
# インラインコメント付きレビュー
jq -n \
  --arg reference "<owner/repo または PR URL>" \
  --argjson number <PR番号> \
  --arg commit_id <head commit SHA> \
  --rawfile body review-body.md \
  --rawfile comment_body comment-body.md \
  --arg event COMMENT \
  --arg grant write \
  '{...}' > review-payload.json

gh/scripts/gh.sh reviews.create review-payload.json
```

- 複数コメントがある場合は各本文を個別ファイルに用意し `--rawfile` で読み込む。
- 複数コメントを 1 つの review にまとめる。
- `event` は常に `"COMMENT"`。PENDING や APPROVE は使わない。
- 指摘がない場合も COMMENT review を投稿する（comments 配列なし）。

### 3. 返信とスレッド解決

```bash
# スレッドへの返信
jq -n --argjson reply_to <返信先コメントID> --rawfile body reply-body.md ... \
  | gh/scripts/gh.sh review-comments.reply

# スレッド解決（ユーザー確認後に実行）
echo '{...}' | gh/scripts/gh.sh review-threads.resolve

# スレッド未解決に戻す
echo '{...}' | gh/scripts/gh.sh review-threads.unresolve
```

各アクションの payload field は `actions.json` を参照する。

## API 注意事項

### ID の使い分け

| 用途 | 取得元 | ID の種類 |
|------|--------|----------|
| 返信の `reply_to` | `review-comments.read` | REST 数値 ID |
| スレッド解決の `thread_id` | `review-threads.read` | GraphQL ノード ID |

GraphQL ノード ID を `reply_to` に使うと API エラーになる。必ず REST 数値 ID を使用する。

### position について

`comments[].position` は GitHub の Legacy diff position。hunk をまたいで継続カウントされる（hunk ごとにリセットされない）。
API 制約により `line`（絶対行番号）は指定できない。

### commit_id

`reviews.create` の `commit_id` には、レビュー開始時に `pr.read` で固定した head commit SHA を渡す。投稿後、API 応答の `commit_id` が固定 SHA と一致することを確認する。

## JSON payload の扱い

- jq の `--rawfile` で値を渡し、JSON のエスケープは jq に任せる。
- 不要になった一時ファイルはワーキングディレクトリ配下に作成し、`/tmp` は使わない。
- GitHub 上の表示本文（API 応答の decoded body）にリテラル `\n`（二文字のバックスラッシュ+n）が出現していないか検査する。JSON ペイロード内の `\n` エスケープは正常なため検査不要。

## 禁止事項

- APPROVE review は発行しない。`event` は常に `"COMMENT"`。
- merge や issue close は行わない。
- バッククォート、`$()`、引用符、改行を含む本文をシェル引数へ直接埋め込まない。
