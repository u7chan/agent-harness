---
name: issue-review
description: >
  合意済みの設計から Issue 本文を作り、別ペインのレビューで収束させてから起票・更新する。
  ユーザーが「この内容で Issue を作って」「ローカルでレビューして Issue を確定して」と依頼した時に使う。
  Requires HERDR_ENV=1.
---

# Issue ローカルレビューと確定

合意した設計を Issue 本文として書き、独立したレビュアーに当てて指摘を潰し、LGTM まで収束させてから起票する。
レビューはローカル（`/tmp`）で完結させ、**Issue 本文には経緯・版番号・レビュー記録を残さない**。

## 前提

- 設計は合意済みであること。未決定が残るなら、先に 1 問ずつ確認して潰す（Pi なら [kabeuchi](../kabeuchi/SKILL.md)）
- Herdr 管理下であること（`HERDR_ENV=1`）。ペインと委譲の操作は [herdr](../herdr/SKILL.md) を正とする
- GitHub の読み書きは [gh](../gh/SKILL.md) を正とする

## 成果物ファイル

`/tmp/<topic>-issue.md` に、**Issue にそのまま載る本文だけ**を書く。
レビュー観点・依頼文・経緯・版番号はファイルへ入れず、委譲プロンプト側に置く（混入を構造で防ぐ）。

構成: 背景 / 方針 / やること / 非ゴール / 検証 / 実装時の注意 / 残る懸念。

事実には根拠（ファイルパスと該当箇所）を添え、レビュアーが実コードで裏取りできるようにする。

## 手順

### 1. レビュアーのペインを用意する

- `herdr pane list --workspace "$HERDR_WORKSPACE_ID"` で空きの対話シェルを探し、あれば使う。無ければ `herdr pane split --pane "$HERDR_PANE_ID" --direction down --cwd "$PWD" --no-focus`（再利用するペインの cwd は親と同じとは限らないため、レビュアーへ渡すリポジトリのルートはプロンプト側で指定する）
- `herdr agent start issue-review --kind pi --pane <pane-id>`（モデルと thinking は付けない = 実行環境の既定。ユーザーが指定した時だけ引数で渡す）
- 応答の `pane_id` を読み、`herdr pane rename <pane-id> issue-review` と `herdr pane get <pane-id>` で label を確認する
- 収束まで同じペインを使い回す（レビューのたびに増やさない）

### 2. 1 回目を委譲する

[herdr](../herdr/SKILL.md) の `scripts/parent-delegate-async.sh` を使う（親から子への委譲はこの経路だけ）。
`--wait` は使わず、委譲したらターンを終える（親が動いていると返信が処理されない）。

プロンプトに含めるもの:

- 作業リポジトリのルート（`git rev-parse --show-toplevel`）と、対象ファイルの絶対パス（起票済みを更新するなら Issue の URL も。レビュアーはこのルートの実コードで裏取りする）
- 検証: リポジトリの実コードと docs で、事実関係・契約・既存の作法を裏取りする
- 観点: 実装時に詰まる抜け / スコープの過剰・不足 / docs の更新漏れ / テスト方針との整合
- 形式: 指摘を 重大 / 中 / 軽 に分け、各指摘に根拠（ファイルパス + 該当箇所）を付ける。結論は OK / 条件付きOK / 要修正
- 制約: 読み取りのみ（ファイル変更・Issue 編集・コミットは禁止）。成果物本文にレビューの記録を足さない

### 3. 返信を反映する

- 指摘は鵜呑みにせず、こちらで実コードを確認してから採否を決める
- **設計判断が変わる指摘はその場で反映せず、ユーザーに確認する**
- 反映は成果物ファイルに行い、どの指摘を反映し、どれを反映しなかったか（理由付き）を会話側に残す

### 4. LGTM まで収束させる

- 2 回目以降は同じペインへ、**前回の指摘の解消判定と更新差分だけ**を確認させる（全体を再レビューさせない）
- 前回の指摘を列挙し、解消 / 未解消 / 別の形で残る を判定させる。併せて、新たな矛盾・スコープ増・レビュー記録の混入を確認させる
- 結論は LGTM / 残指摘（重大・中・軽）
- 打ち切りは既定 3 回（ユーザー指定があればその回数）。上限で止めたら、残った指摘と採否の理由を報告する

### 5. Issue を確定する

GitHub への書き込みは [gh](../gh/SKILL.md) の dispatcher を使う（対象リポジトリは実行ディレクトリから解決される）。

```bash
# 起票
jq -n --rawfile body /tmp/<topic>-issue.md \
  '{title:"<title>", body:$body, labels:["<label>"], grant:"write"}' > /tmp/<topic>-issue-create.json
gh/scripts/gh.sh issue.create /tmp/<topic>-issue-create.json

# 更新
jq -n --rawfile body /tmp/<topic>-issue.md \
  '{number:<number>, body:$body, grant:"write"}' > /tmp/<topic>-issue-update.json
gh/scripts/gh.sh issue.update /tmp/<topic>-issue-update.json
```

- タイトル・本文・ラベルは日本語。ラベルはリポジトリの既存のものを使う
- 確定後に本文を読み直し、「レビュー / 指摘 / 下書き / Ver」のような語が混入していないか確認する
- 報告: Issue の URL、タイトル、ラベル、往復回数、未反映の指摘

## 注意

- レビュアーのペインは、ユーザーが明示した時だけ閉じる
- 成果物ファイルは `/tmp` に置き、リポジトリへコミットしない
