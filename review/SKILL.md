---
name: review
description: >
  GitHub Pull Request またはローカルのコード変更をレビューし、具体的な根拠に基づく指摘を報告する。
  PR の URL・番号が指定されたレビュー、ローカル変更のレビュー、以前の指摘の再チェックに使う。
---

# Review

Pull Request またはローカル変更について、差分によって生じる具体的な失敗経路を検証する。

## モード

- PR の URL または番号が指定された場合は PR レビューモードとし、GitHub への投稿まで進める。
- PR 指定がない場合はローカルレビューモードとし、GitHub へ投稿せずチャットで報告する。
- 明示的に再チェックを依頼された場合は、同じ PR の同じレビュースレッドで自分が投稿した未解決の root comment を再分類し、同時に最新 head 全体を通常どおりレビューする。
- レビューの依頼だけではファイルを変更しない。修正依頼はレビューと分けて扱う。

## 安全条件

- GitHub 操作には `gh/scripts/gh.sh` を使い、github.com だけを対象にする。
- PR の URL から特定した `owner/repo` を全アクションの `reference` に渡し、解決した対象が途中で変わっていないことを確認する。
- 開始時の head コミットの SHA を記録する。投稿直前に `pr.read` で head の SHA とドラフト状態を再取得し、SHA が変わっていれば投稿せず報告する。
- `reviews.create` には固定した SHA を `commit_id` として渡す。レビューイベントには `COMMENT` だけを使う。
- マージ、Issue のクローズ、`APPROVE` レビューは行わない。通常のレビューではスレッドを Resolve せず、再チェックで [recheck.md](references/recheck.md) が定める対象だけを、検証済み LGTM の後に自動 Resolve する。
- 再チェックの自動 Resolve 対象は、同じ PR の `thread_id`、root comment の `root_comment_id`、root と返信の `reviewer_login`、今回の再チェックで新規に確認した `recheck_reply_id`（分類が `Resolved`）の組で一意に特定する。他者の root、ユーザー判断待ちの会話、`Partial`、`Unresolved`、`Unknown` は対象にしない。
- LGTM の投稿と本文・head の検証が成功する前に Resolve してはならない。Resolve ごとに対象と状態を再取得し、対応するスレッドが `resolved=true` であることを確認する。失敗、`unknown_outcome`、再取得失敗、対象不一致は成功として扱わず報告する。
- 投稿後はレスポンスを再取得し、対象、本文、コメント位置、`commit_id` が意図どおりか確認する。

## 手順

1. PR モードでは `pr.read` から対象と head の SHA を固定する。ローカルモードでは `git status` の結果、未ステージ・ステージ済み・ベースブランチとの差分、未追跡ファイルを対象に含める。
2. PR の説明、差分、コメント、既存レビュー、関連コード、型、設定、テストを必要な範囲で読む。PR の取得順と投稿上の注意は [posting-api.md](references/posting-api.md) に従う。
3. 目的、維持すべき契約、変更の伝播先を整理し、[review-lenses.md](references/review-lenses.md) から関係する観点だけを選ぶ。
4. 各候補について発生条件、失敗経路、影響を調べ、ガード、呼び出し元、型、仕様、テストによる反証を先に探す。
5. [review-criteria.md](references/review-criteria.md) の品質ゲートを通過した候補だけを指摘する。原因に最も近い差分行へ付け、差分行に置けない問題だけをレビュー本文に含める。
6. PR モードでは [output-templates.md](references/output-templates.md) から該当する状態のテンプレートを選んでペイロードを作り、`review/scripts/validate-review-payload.sh` を通してから投稿する。ローカルモードでは同じラベルと形式でチャットへ報告する。
7. 投稿内容の検証結果、PR の URL、指摘件数を簡潔に報告する。監査情報が必要な場合に限り、出力テンプレートの折りたたみを使う。
8. 再チェックでは [recheck.md](references/recheck.md) に従い、該当する返信とレビュー結果のテンプレートを使う。

## 参照先

- 観点の選択: [review-lenses.md](references/review-lenses.md)
- 品質ゲートとラベル: [review-criteria.md](references/review-criteria.md)
- コメント、レビュー本文、再チェック返信: [output-templates.md](references/output-templates.md)
- GitHub の取得・投稿: [posting-api.md](references/posting-api.md)
- 再チェック: [recheck.md](references/recheck.md)
