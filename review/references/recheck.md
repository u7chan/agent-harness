# Recheck Workflow

## 対象とラウンド

- 明示的な再チェック依頼がある場合だけ、以前の会話で自分が投稿した未解決 thread を対象にする。
- 初回レビューを Round 1、再チェックを Round 2、Round 3 とし、最大 3 ラウンドにする。
- Resolve 済み、他者や別会話のコメント、再チェック中に新しく見つけた論点は対象にしない。
- Round 3 の後も Blocker が残る場合は追加投稿せず、Draft のままユーザーへ報告する。

## 判定

元コメントの発生条件、原因、問題となる挙動、影響を再構成し、現在も同じ失敗経路へ到達するかを確認する。テスト追加だけを解消の根拠にしない。

- **resolved**: 元の失敗条件が閉じ、同じ原因から問題となる挙動へ到達しない。
- **partial**: 一部の条件は閉じたが、元コメントの別の入力、状態、経路が残る。
- **unresolved**: 元の失敗条件または影響が残る。
- **unknown**: コード、実行条件、仕様、権限の不足により判断できない。

判定後は [output-templates.md](output-templates.md) の対応する返信を同じ thread に投稿する。resolved は根拠を返信した後、ユーザーが確認した場合だけ Resolve する。partial と unresolved は現在のラベルを付け、unknown は Resolve しない。全対象が resolved なら再チェック合格の review result を使う。

## Thread の特定

1. `review-threads.read` の `database_id` と `review-comments.read` の root comment の数値 ID を照合する。
2. `database_id` がない場合だけ、PR、path、line、投稿者、`in_reply_to_id == null` を照合し、outdated なら original position を優先する。
3. 一意に特定できなければ unknown とし、返信しない。

## 報告

ラウンド、返信件数、ユーザー確認後に Resolve した件数、未解決または判断不能の条件を簡潔に伝える。
