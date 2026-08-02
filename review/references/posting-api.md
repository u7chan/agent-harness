# Posting API Mapping

すべての GitHub 操作は `gh/scripts/gh.sh` 経由で行う。カテゴリ `pr`, `review`, `review-comment`, `review-thread`, `comment` のアクションを使用する。
入力は stdin または JSON ファイルで渡す（文字列を直接引数にしない）。

## PR 情報の取得

```bash
# PR メタデータ取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh pr.read

# PR 差分取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh pr.diff.read

# PR ファイル一覧取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh pr.files.read

# PR コミット一覧取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh pr.commits.read

# Issue コメント取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh comments.read
```

## レビュー情報の取得

```bash
# レビュー一覧取得
echo '{"number": <PR番号>}' | gh/scripts/gh.sh reviews.read

# レビューコメント取得（REST: 数値ID、path、line を含む）
echo '{"number": <PR番号>}' | gh/scripts/gh.sh review-comments.read

# レビュースレッド取得（GraphQL: resolved 状態、thread_id 含む）
echo '{"number": <PR番号>}' | gh/scripts/gh.sh review-threads.read
```

`review-comments.read` の出力から数値コメント ID を取得し、`review-threads.read` の出力からスレッドの resolve 状態と thread_id を取得する。

## レビュー投稿

複数行の本文は JSON ファイル経由で渡す。

```bash
# インラインコメント付きレビュー作成
jq -n \
  --argjson number <PR番号> \
  --rawfile body review-body.md \
  --arg event COMMENT \
  --arg grant write \
  '{
    number: $number,
    body: $body,
    comments: [
      {
        path: "<ファイルパス>",
        position: <diff内の位置>,
        body: "<コメント本文>"
      }
    ],
    event: $event,
    grant: $grant
  }' > review-payload.json

gh/scripts/gh.sh reviews.create review-payload.json
```

- `comments[].position` は diff hunk 内の位置（絶対行番号ではない）。
- 複数コメントを 1 つの review にまとめる。
- `event` は常に `"COMMENT"`（PENDING や APPROVE は使わない）。

```bash
# 指摘なしレビュー（comments 配列なし）
jq -n \
  --argjson number <PR番号> \
  --rawfile body no-findings.md \
  --arg event COMMENT \
  --arg grant write \
  '{number: $number, body: $body, event: $event, grant: $grant}' \
  > no-findings-payload.json

gh/scripts/gh.sh reviews.create no-findings-payload.json
```

## 個別アクション

```bash
# コメントへの返信（スレッド内）
echo '{
  "number": <PR番号>,
  "reply_to": <返信先コメントID>,
  "body": "<返信本文>",
  "grant": "write"
}' | gh/scripts/gh.sh review-comments.reply
```

`reply_to` には `review-comments.read` の出力に含まれる数値 ID を使う。

```bash
# スレッド解決（sensitive-write、ユーザー確認後に実行）
echo '{
  "thread_id": "<GraphQL thread node ID>",
  "grant": "sensitive-write"
}' | gh/scripts/gh.sh review-threads.resolve

# スレッド未解決に戻す
echo '{
  "thread_id": "<GraphQL thread node ID>",
  "grant": "sensitive-write"
}' | gh/scripts/gh.sh review-threads.unresolve
```

`thread_id` は `review-threads.read` の出力に含まれる GraphQL ノード ID を使う。

## JSON payload の扱い

- 複数行 Markdown 本文は jq の `--rawfile` または JSON ファイルで渡す。
- 永続化が必要な場合はワーキングディレクトリ配下に一時ファイルを作成し、`/tmp` は使わない。
- JSON ファイル内では実改行を使う。文字列としての `\n` を埋め込まない。
- JSON 表現としての `\n` は正常（jq が適切にエンコードする）。検査対象は GitHub 上の表示本文（API 応答の decoded body）に限定する。

## 注意事項

- `review-comments.create` は常に `commit_id` が必要。PR の head commit SHA を `pr.read` から取得する。
- `position` は GitHub の Legacy diff position。API 制約により絶対行番号（`line`）は使えない。
- 返信の `reply_to` には `review-comments.read` の REST API が返す数値 ID を使う。`review-threads.read` の GraphQL ノード ID とは異なる。
- スレッド解決の `thread_id` には `review-threads.read` の GraphQL ノード ID を使う。
- すべての write 系アクションには `grant` フィールドが必要。
- APPROVE レビューは発行しない。merge や issue close は行わない。
