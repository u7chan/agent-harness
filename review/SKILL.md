---
name: review
description: >
  GitHub Pull Request またはコード変更をレビューし、根拠のある指摘を報告する。
  PR URL・番号の指定では GitHub へ投稿し、指定がない場合はローカルレビューを行う。
  「レビューして」「PRレビューして」で起動する。
---

# 概要

Pull Request またはコード変更をレビューし、根拠のある指摘を報告する。
PR が指定された場合は差分行へ投稿し、指定がない場合はローカルレビューとして結果をチャットで報告する。
指摘がない場合も、PR レビューでは COMMENT review を残し、ローカルレビューでは指摘なしを報告する。
再チェックでは以前の指摘の解消を検証し、PR レビューではスレッドへ返信する。

# Rules

- PR URL または PR 番号の指定がない場合は、ローカルレビュー（GitHub へ投稿せず結果をチャットで報告）を行うかユーザーに確認する。PR 指定がある場合は確認せず自動で投稿まで進める。
- 全操作は `gh/scripts/gh.sh` 経由で行い、GitHub コネクタは使わない。
- github.com のリポジトリのみ対象とする。
- APPROVE review は発行しない。常に COMMENT イベントを使う。
- merge や issue close は行わない。
- レビュー開始時に head commit SHA を固定する。各 write アクションの直前に `pr.read` で最新の head SHA と Draft 状態を再取得し、開始時から変更があれば投稿せずユーザーに報告する。
- 投稿後は API 応答または再取得で本文、ラベル、コメント位置を確認する。
- 投稿完了前に API 応答の decoded body を `rg` で検査し、リテラル `\n`（二文字のバックスラッシュ+n）、不完全な重要度ラベル、未置換変数パターンをチェックする。JSON ペイロード内の `\n` エスケープは正常なため除外する。
- 直接修正はタイポ、コードコメント、Markdown の修正に限る。コードロジック、設定、テスト、型定義の直接修正は不可。
- 再チェックは最大 3 ラウンド。3 ラウンド後も Blocker または Major が残存する場合は停止して報告する。
- PR が Draft 状態で Blocker または Major が残存する場合、ラウンドに関わらず停止する。

# Workflow

## 1. レビューモードを決定する

- PR URL または PR 番号が指定されている場合は PR レビューモードで自動進行する。
  - PR URL があれば `owner/repo` と PR 番号を読み取る。
  - PR 番号だけなら現在の remote からリポジトリを推定する。
  - 対象が確定したら `pr.read` で head commit SHA を取得し固定する。
- PR 指定がない場合は、ローカルレビューを行うかユーザーに確認する。
  - ローカルレビューでは `git diff` または指定されたファイル・範囲を対象に Steps 2-6 を実行し、Step 8 でチャット報告する。
  - ローカルレビューでは GitHub への投稿は行わない。

## 2. 根拠を収集する

PR レビューモード:
- `pr.read` で PR メタデータを取得する。
- `pr.diff.read` で差分を取得する。
- `pr.files.read` でファイル一覧を取得する。
- `comments.read` で Issue コメントを取得する。
- `reviews.read`、`review-comments.read`、`review-threads.read` で既存レビューを取得する。

ローカルレビューモード:
- `git diff` で差分を取得する。
- `git log` でコミット情報を取得する。
- 変更ファイルは `git diff --name-only` で特定する。

共通:
- 差分だけで判断せず、変更箇所の呼び出し元、型、設定、既存テスト、プロジェクト規約を必要な範囲で読む。
- PR レビューでは、同じ入力条件、失敗モード、影響、修正方針を扱う既存指摘は重複として除外する。

## 3. 目的と主張を抽出する

- PR の説明、差分、型、設定、利用側から、何を変えるか、何が変わらないべきか、どの契約が更新されるかを短く整理する。
- 説明やテストの主張は、実装、設定、呼び出し元まで追って確認する。
- PR が導入または悪化させていない既存問題は、原則として指摘しない。

## 4. 観点を選び、仮説を作る

- `references/review-lenses.md` から、目的、主張、変更の境界に関係する観点だけを選ぶ。
- 各候補について、差分との関係、発生条件、失敗経路、予想される影響を仮説として書き出す。
- 正しさ、仕様逸脱、セキュリティ、データ破壊、例外経路を優先し、その後に設計、一貫性、保守性、テスト不足を確認する。

## 5. 仮説を反証する

- 呼び出し元、既存ガード、型、設定、テスト、実行経路を調べ、仮説を打ち消す材料を先に探す。
- 外部仕様やライブラリ挙動が論拠なら、利用可能な公式仕様または一次資料で確認する。
- 反証済みの候補は投稿しない。確認に必要な事実が得られない候補も投稿しない。

## 6. 品質ゲートとコメント位置を決める

- `references/review-criteria.md` の品質ゲートを通過し、投稿可能と判定した候補だけを対象にする。
- 品質ゲートを通過しなかった候補（判断不能、反証済み）は投稿しない。
- 重要度は Blocker / Major / Minor / Nit の 4 段階で判定する。
- 原因または修正対象に最も近い差分行へ inline comment を付ける。
- 複数ファイルにまたがる問題、削除済み行、API 制約で紐づけられない問題だけ overall comment にする。

## 7. コメントを投稿する（PR レビューモードのみ）

- `references/posting-rules.md` に従い、各コメントへ重要度ラベルを付ける。
- 複数の inline comment は `reviews.create` の `comments` 配列にまとめる。
- 投稿 API と payload は `references/posting-api.md` を参照する。
- 指摘がない場合は inline comment を作らず、指摘なしの COMMENT review を `reviews.create` で投稿する。
- 投稿後に本文、コメント位置、改行が正しいことを再取得して確認する。
- ローカルレビューモードではこのステップをスキップする。

## 8. 報告する

PR レビューモード:
- PR URL、投稿件数、重要度別の内訳を簡潔に伝える。
- レビュー記録テンプレート（`references/posting-rules.md`）に従い、対象 commit、実行検証、指摘一覧、見送り理由を記録する。
- 指摘がない場合は、指摘なしの review を投稿したと伝える。

ローカルレビューモード:
- レビュー記録テンプレート形式で、対象範囲、指摘一覧、重要度、見送り理由をチャットで報告する。

## 9. 再チェックする（PR レビューモードのみ）

- 明示的な再チェック依頼があった場合のみ実行する。初回レビューで投稿した直後の指摘は対象外とする。
- `references/recheck.md` に従い、以前の会話で投稿した未解決指摘だけを対象にする。
- 最新差分と review threads を再取得する。
- 元コメントが示した失敗条件ごとに resolved、partial、unresolved、unknown を判定する。
- 返信の `reply_to` には `review-comments.read` の出力に含まれる数値 ID を使う。`review-threads.read` の GraphQL ノード ID は `reply_to` に使えない。
- 改善済みなら `review-comments.reply` で返信し、ユーザー確認後に `review-threads.resolve` で Resolve する（sensitive-write のため自動実行不可）。
- 未改善なら同じ thread へ残存条件を `review-comments.reply` で返信する。
- 判断材料が不足する場合は Resolve しない。

# References

- Step 4, 5: `references/review-lenses.md`
- Step 6: `references/review-criteria.md`
- Step 7: `references/posting-rules.md`
- Step 7 の API: `references/posting-api.md`
- Step 9: `references/recheck.md`
