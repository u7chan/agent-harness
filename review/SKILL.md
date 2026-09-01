---
name: review
description: >
  GitHub Pull Request またはローカルのコード変更をレビューし、具体的な根拠に基づく指摘を報告する。
  PR の URL・番号が指定されたレビュー、ローカル変更のレビュー、以前の指摘の再チェックに使う。
---

# Review

Pull Request またはローカル変更について、差分によって生じる具体的な失敗経路を検証する。

レビューの成功条件は finding を出すことではなく、変更が目的・完了条件・維持すべき契約を破っていないかを十分に検証することである。十分に検証して問題が確認できなければ、`0 findings` / LGTM で正常終了する。敵対的レビューでは指摘の量ではなく、仮説を厳しく検証することに敵対性を使う。

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
- マージ、Issue のクローズ、`APPROVE` レビューは行わない。スレッドの Resolve は、明示指示があった場合（手動フロー）か、委譲タスクで自動 Resolve を明示指定された場合（workflow コンテキスト）だけに行う。手動フローは [recheck.md](references/recheck.md) の「明示指示による Resolve」に従い、そのスレッドに閉会コメントを付けてから行う。workflow コンテキストは同ファイルの「Workflow コンテキストの自動 Resolve」に従う。LGTM から自動的に Resolve しない。
- 再チェックの Resolve 対象は、同じ PR の `thread_id`、root comment の `root_comment_id`、root と返信の `reviewer_login`、今回の分類 anchor `classification_reply_id`（分類が `Resolved`）の組で一意に特定する。対象は明示指示、または workflow コンテキストの委譲で自動 Resolve 対象とされた thread に限る。他者の root、ユーザー判断待ちの会話、`Partial`、`Unresolved`、`Unknown` は対象にしない。
- 再チェックの分類パース・thread snapshot の正規化・`post|reuse|stop`・LGTM policy の判定は `review/scripts/recheck-state.py` に入力する。返信結果は「投稿成功 / already-applied / stop」の 3 種だけを扱う。skill は元 finding の再評価と LGTM policy だけを判断し、Action に分類判断を移さない。
- LGTM の投稿と本文・head の検証が成功して初めて LGTM と報告する。Resolve は LGTM と独立した「会話を閉じる」記録であり、明示指示、または workflow コンテキストの委譲で指定された thread だけを対象に、`review-threads.resolve` の前後で対象と状態を再取得して、対応するスレッドが `resolved=true` であることを確認する。head の変化、失敗、`unknown_outcome`、再取得失敗、対象不一致は Resolve せず、成功として扱わず報告する。
- 投稿後はレスポンスを再取得し、対象、本文、コメント位置、`commit_id` が意図どおりか確認する。

## 手順

1. PR モードでは `pr.read` から対象と head の SHA を固定する。ローカルモードでは `git status` の結果、未ステージ・ステージ済み・ベースブランチとの差分、未追跡ファイルを対象に含める。
2. PR の説明、差分、コメント、既存レビュー、関連コード、型、設定、テストを必要な範囲で読む。レビュー開始時に、利用可能な変更目的、受け入れ条件、禁止される結果、維持すべき既存契約、変更の伝播先、実行済みテストと結果、人間の判断が必要な未決事項を先に整理する。PR の取得順と投稿上の注意は [posting-api.md](references/posting-api.md) に従う。
3. 整理した判断材料に [review-criteria.md](references/review-criteria.md) の仕様の優先順位を適用し、明示された要件を正本として、[review-lenses.md](references/review-lenses.md) から関係する観点だけを選ぶ。明示されていない「こうあるべき」を推測で補わず、仕様不足による重要な不確定を勝手に確定しない。
4. 候補を深掘りする前に [review-criteria.md](references/review-criteria.md) の Scope Gate を適用する。通過しない候補は Rejected として終了する。
5. Scope Gate を通過した候補は Concern として扱い、発生条件、失敗経路、影響、差分との因果関係を調べる。ガード、呼び出し元、型、仕様、テストによる反証を先に探し、具体的な根拠と第三者が確認できる再現または検証経路を確立できたものだけ Evidence に昇格させる。反証できないこと自体を Evidence とみなさない。
6. Evidence に昇格した候補だけを [review-criteria.md](references/review-criteria.md) の品質ゲートへ通す。通過したものだけを Finding として、原因に最も近い差分行へ付ける。差分行に置けない問題だけをレビュー本文に含める。
7. 関係する review lens を一巡し、Concern を Evidence / Rejected に分類し、Evidence の品質ゲートを確認し、未解決 Concern に追加調査できる具体的な手掛かりがなければ探索を終了する。「まだ何かあるかもしれない」ことや候補が反証されたことを理由に、代替の finding を探し続けない。
8. PR モードでは [output-templates.md](references/output-templates.md) から該当する状態のテンプレートを選んでペイロードを作り、`review/scripts/validate-review-payload.sh` を通してから投稿する。ローカルモードでは同じラベルと形式でチャットへ報告する。
9. 投稿内容の検証結果、PR の URL、指摘件数を簡潔に報告する。監査情報が必要な場合に限り、出力テンプレートの折りたたみを使う。
10. 再チェックでは [recheck.md](references/recheck.md) に従い、該当する返信とレビュー結果のテンプレートを使う。

## 参照先

- 観点の選択: [review-lenses.md](references/review-lenses.md)
- Scope Gate、候補の状態、品質ゲート、ラベル: [review-criteria.md](references/review-criteria.md)
- コメント、レビュー本文、再チェック返信: [output-templates.md](references/output-templates.md)
- GitHub の取得・投稿: [posting-api.md](references/posting-api.md)
- 再チェック: [recheck.md](references/recheck.md)
