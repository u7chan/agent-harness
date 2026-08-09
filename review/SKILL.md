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
- 明示的に再チェックを依頼された場合は、以前の会話で自分が投稿した未解決の指摘だけを再検証する。
- レビューの依頼だけではファイルを変更しない。修正依頼はレビューと分けて扱う。

## 安全条件

- GitHub 操作には `gh/scripts/gh.sh` を使い、github.com だけを対象にする。
- PR の URL から特定した `owner/repo` を全アクションの `reference` に渡し、解決した対象が途中で変わっていないことを確認する。
- 開始時の head commit SHA を記録する。投稿直前に `pr.read` で head SHA と Draft 状態を再取得し、SHA が変わっていれば投稿せず報告する。
- `reviews.create` には固定した SHA を `commit_id` として渡す。review event は `COMMENT` だけを使う。
- merge、issue close、APPROVE review は行わない。スレッドの Resolve はユーザーの確認後だけ行う。
- 投稿後はレスポンスを再取得し、対象、本文、コメント位置、`commit_id` が意図どおりか確認する。

## 手順

1. PR モードでは `pr.read` から対象と head SHA を固定する。ローカルモードでは `git status` の結果、未ステージ・ステージ済み・base からの差分、未追跡ファイルを対象に含める。
2. PR の説明、差分、コメント、既存レビュー、関連コード、型、設定、テストを必要な範囲で読む。PR の取得順と投稿上の注意は [posting-api.md](references/posting-api.md) に従う。
3. 目的、維持すべき契約、変更の伝播先を整理し、[review-lenses.md](references/review-lenses.md) から関係する観点だけを選ぶ。
4. 各候補について発生条件、失敗経路、影響を調べ、ガード、呼び出し元、型、仕様、テストによる反証を先に探す。
5. [review-criteria.md](references/review-criteria.md) の品質ゲートを通過した候補だけを指摘する。原因に最も近い差分行へ付け、差分行に置けない問題だけを review body に含める。
6. PR モードでは [output-templates.md](references/output-templates.md) から該当する状態のテンプレートを選んで payload を作り、`review/scripts/validate-review-payload.sh` を通してから投稿する。ローカルモードでは同じラベルと形式でチャットへ報告する。
7. 投稿内容の検証結果、PR の URL、指摘件数を簡潔に報告する。監査情報が必要な場合に限り、出力テンプレートの折りたたみを使う。
8. 再チェックでは [recheck.md](references/recheck.md) に従い、該当する返信と review result のテンプレートを使う。

## 参照先

- 観点の選択: [review-lenses.md](references/review-lenses.md)
- 品質ゲートとラベル: [review-criteria.md](references/review-criteria.md)
- コメント、review body、再チェック返信: [output-templates.md](references/output-templates.md)
- GitHub の取得・投稿: [posting-api.md](references/posting-api.md)
- 再チェック: [recheck.md](references/recheck.md)
