---
name: herdr-issue-review
description: >
  合意済みの設計から Issue 本文を作り、別ペインのレビューで収束させてから起票・更新する。
  ユーザーが「この内容で Issue を作って」「ローカルでレビューして Issue を確定して」と依頼した時に使う。
  Requires Herdr: the reviewer runs in a separate Herdr pane, so pass HERDR_ENV=1.
---

# Issue ローカルレビューと確定

合意した設計を Issue 本文として書き、独立したレビュアーに当てて指摘を潰し、LGTM まで収束させてから起票する。
レビューはローカル（`/tmp`）で完結させ、**Issue 本文には経緯・版番号・レビュー記録を残さない**。

## 前提

- 設計は合意済みであること。未決定が残るなら、先に 1 問ずつ確認して潰す（[kabeuchi](../kabeuchi/SKILL.md)）
- Herdr 管理下であること（`HERDR_ENV=1`）。ペインと委譲の操作は [herdr](../herdr/SKILL.md) を正とする
- レビュアーの起動 spec は、実効プロファイルの `review` を土台にする（[Pi Development Profiles](../_docs/pi-development.md)）。ユーザーが明示指定した値はプロファイルより優先する
- GitHub の読み書きは [gh](../gh/SKILL.md) を正とする

## 開始前チェック

作業を始める前にここを通す。条件を満たさない、または確認が失敗・不明なら、**何も作らず・書かず・委譲せずに停止する**（不明を正常扱いしない）。

条件の正本は [herdr](../herdr/SKILL.md) の `Preflight` と `Caller pinning` とし、ここでは再定義しない。次のすべてを満たすこと。

- `HERDR_ENV=1` である
- `herdr` コマンドが利用できる
- `HERDR_WORKSPACE_ID` と `HERDR_PANE_ID` が設定され、形式が有効で、ペインの所属ワークスペースが親と整合している

1 つでも満たさない場合、または確認が失敗・不明な場合は、次を行う。

- 不足・失敗・不明の内容を理由として、会話言語で説明する
- 処理を開始していないこと、Issue 本文ファイルを作っていないこと、Issue の作成・更新をしていないことを伝える
- 自己レビューへの置き換え、別の委譲方式への自動切り替え、Herdr の自動インストールを行わない

このチェックを通るまで、`成果物ファイル` の作成、ペイン作成、エージェント起動、レビュー委譲、Issue の作成・更新へ進まない。

このチェックはエージェントへの操作指示であり、それ自体が実行経路の技術的な遮断になるわけではない（[技術的な委譲境界](../herdr/references/technical-delegation-boundary.md)）。

## 成果物ファイル

`/tmp/<topic>-issue.md` に、**Issue にそのまま載る本文だけ**を書く。
ローカルレビューの観点・依頼文・経緯・版番号はファイルへ入れず、委譲プロンプト側に置く（混入を構造で防ぐ）。[_docs/human-brief.md](../_docs/human-brief.md) の人間レビュー用サマリは、本文に載せる人間向けの要約であり、この禁止の対象外。

構成: 背景 / 方針 / やること / 非ゴール / 検証 / 実装時の注意 / 残る懸念。

事実には根拠（ファイルパスと該当箇所）を添え、レビュアーが実コードで裏取りできるようにする。

レビュー収束後、[_docs/human-brief.md](../_docs/human-brief.md) に従って `pi:human-brief` 節を先頭へ追加する。レビュアーはこの節を設計として読まない。

## 手順

### 1. レビュアーのペインと起動 spec を用意する

- `herdr pane list --workspace "$HERDR_WORKSPACE_ID"` で空きの対話シェルを探し、あれば使う。無ければ `herdr pane split --pane "$HERDR_PANE_ID" --direction down --cwd "$PWD" --no-focus`（再利用するペインの cwd は親と同じとは限らないため、レビュアーへ渡すリポジトリのルートはプロンプト側で指定する）
- 実効プロファイルの `review` を土台にして起動 spec を合成する（[Pi Development Profiles](../_docs/pi-development.md)）。スクリプトのパスは対象リポジトリではなく、このスキルの親（パッケージルート）から解決する。
  1. `scripts/pi-development/team-record.sh resolve --only-role review` で実効プロファイルを解決し、`result=ok` なら `review=<harness>:<...>` を土台にする。正本の文字列は Pi が `pi:<provider>/<model>/<thinking>`、Claude が `claude:<model>/<effort>/<permission_mode>` である。
  2. ユーザー指定はハーネス別にだけ上書きする。Pi は provider / model / thinking、Claude は model / effort / permission_mode である。プロファイルが `result=ok` のときは、同じハーネスの範囲で指定されたフィールドだけを上書きし、指定されていない値はプロファイルから補う。ハーネスをまたぐ指定（Pi の provider と Claude の effort など）は停止する。プロファイルが使えない場合の部分的に揃った指定は、プロファイルや推測で埋めずに停止する。上書きは今回の実行だけに使い、プロファイルを自動で書き換えない。
  3. 合成後の完全な spec をハーネス別の形で `scripts/pi-development/resolve-model-spec.sh --harness <pi|claude> ...` に再検証する。Pi は `--provider <provider> --model <model> --thinking <thinking>` を渡し、`result=ok` と `verification=exact` の両方を確認する。Claude は `--model <model> --effort <effort> --permission-mode <permission_mode>` を渡し、`result=ok` と `verification=postlaunch` の両方を確認する。ユーザー指定が完全でも、再検証が `result=ok` でなければ停止する。
- `reason=migration-required` の場合は既定へのフォールバックに進まず、[設定移行](../_docs/pi-development-migration.md)のため停止する。
- プロファイルが `ok` でない場合（`result=missing` / `invalid` / `unresolved`）は、ユーザー指定の揃い方で決める。
  - Pi でユーザー指定が無ければ、実行環境の既定にフォールバックし、その旨を 1 行で出す。既定は、呼び出し元の Pi セッションが公開する `$PI_PROVIDER` / `$PI_MODEL` / `$PI_REASONING_LEVEL` を `pi:<provider>/<model>/<thinking>` として使う。3 値が揃わない場合はフォールバックせず停止する。
  - Claude は既定へフォールバックしない。model / effort / permission_mode がすべて明示されていない場合は停止して確認する。
  - ユーザー指定が部分的なら、不足をプロファイルや推測で埋めずに停止して確認する。
  - ユーザー指定が完全なら、`resolve-model-spec.sh` で検証し、`result=ok` のときだけ使う。
- フォールバックしたときの固定行は次の 1 行だけとする。この行は Pi 用であり、Claude では出さない。

  ```text
  review: 実効プロファイルを使わず実行環境の既定で起動（profile=<missing|invalid|unresolved>）
  ```

- ハーネスの preflight: Pi は `pi` が使えることを確認する。Claude は `claude` と `claude auth status` の `loggedIn=true` を確認し、`~/.claude/skills` からこのリポジトリのスキルをロードできることを確かめる。trust は共有ランチャーが読み取り専用で確認する。未承認なら次の固定行で停止する。

  ```text
  claude-trust: <path> が未承認です。そのディレクトリで claude を一度起動し、trust を承認してから再実行してください。
  ```

- 起動は共有ランチャー `herdr/scripts/start-agent.sh` を使う。共有ランチャー以外の起動経路を使わない。ランチャーは引数検証、認証と trust の preflight、起動、実効値確認、`launch:` / `effective:` 行を所有する。

  ```bash
  herdr/scripts/start-agent.sh <pane-id> herdr-issue-review \
    --spec <harness>:<...> \
    --profile <name|-> --role review \
    --spec-source <profile|explicit> --origin <explicit|active|default>
  ```

  プロファイルの `review` を土台にした場合は、`team-record.sh resolve` が返した profile と source を `--profile` と `--origin` に渡す。`--spec-source` は spec の由来を示し、`review` の spec をそのまま使う場合だけ `--spec-source profile` にする。

  明示上書きを 1 つでも適用した場合と、完全な明示 spec（Pi の実行環境既定を含む）を使う場合は `--spec-source explicit` にする。

  `--profile` は土台にしたプロファイル名（完全な明示 spec なら `-`）、`--origin` は resolve が返した source（明示 spec なら `explicit`）を監査用に渡す。`spec_source` と `origin` は別物であり、上書きしても `origin` は土台の由来のままにする。

  例: 土台のプロファイル `default` の `review` が Claude で、model と permission_mode が揃っている場合に限り、effort だけを上書きして `--profile default --role review --spec-source explicit --origin default` にできる。ハーネスをまたぐ指定はこの形にできないため停止する。spec 全体がプロファイル由来のままなら `--spec-source profile --origin default` にする。
- 起動確認:
  - Pi は、レビュアーへ渡すタスク文面に次のコマンドを含め、`effective:` 行を出させる。`launch:` 行と照合し、`requested=` が起動した `spec` と一致することを確認する。footer（`herdr agent read <pane-id> --source visible`）は補助に留め、footer だけで一致とみなさない。

    ```bash
    printf 'effective: harness=pi provider=%s model=%s effort=- thinking=%s permission_requested=- requested=pi:%s/%s/%s\n' \
      "$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL" \
      "$PI_PROVIDER" "$PI_MODEL" "$PI_REASONING_LEVEL"
    ```

  - Claude は共有ランチャーが stderr に出す最後の `effective:` 行を正本とし、`requested=` が `launch:` 行の `spec` と一致することを確認する。起動引数だけを証拠にしない。
  - `effective:` 行が得られない、または `launch:` 行と一致しない場合は、レビュー結果を採用せずに停止する。
- 起動に使った pane ID をそのまま使い、`herdr pane rename <pane-id> herdr-issue-review` と `herdr pane get <pane-id>` で label を確認する。共有ランチャーは JSON を返さず、`launch:` 行（Claude は `probe:` と `effective:` も）を stderr に出す。
- 収束まで同じペインを使い回す（レビューのたびに増やさない）

### 2. 1 回目を委譲する

[herdr](../herdr/SKILL.md) の `scripts/parent-delegate-async.sh` を使う（親から子への委譲はこの経路だけ）。
`--wait` は使わず、委譲したらターンを終える（親が動いていると返信が処理されない）。

プロンプトに含めるもの:

- 作業リポジトリのルート（`git rev-parse --show-toplevel`）と、対象ファイルの絶対パス（起票済みを更新するなら Issue の URL も。レビュアーはこのルートの実コードで裏取りする）
- 検証: リポジトリの実コードと docs で、事実関係・契約・既存の作法を裏取りする
- 観点: 実装時に詰まる抜け / スコープの過剰・不足 / docs の更新漏れ / テスト方針との整合
- 形式: 指摘を 重大 / 中 / 軽 に分け、各指摘に根拠（ファイルパス + 該当箇所）を付ける。結論は OK / 条件付きOK / 要修正
- 読み取り範囲: Issue 本文の `pi:human-brief` 範囲は読まない。範囲外の本文だけを設計としてレビューする
- 起動確認: Pi の場合は「1. レビュアーのペインと起動 spec を用意する」の `effective:` 行のコマンドを最初に実行させ、その出力を返信に含めさせる
- 制約: 読み取りのみ（ファイル変更・Issue 編集・コミットは禁止）。成果物本文にレビューの記録を足さない

### 3. 返信を反映する

- 指摘は鵜呑みにせず、こちらで実コードを確認してから採否を決める
- **設計判断が変わる指摘はその場で反映せず、ユーザーに確認する**
- 反映は成果物ファイルに行い、どの指摘を反映し、どれを反映しなかったか（理由付き）を会話側に残す

### 4. LGTM まで収束させる

- 2 回目以降は同じペインへ、**前回の指摘の解消判定と更新差分だけ**を確認させる（全体を再レビューさせない）
- 前回の指摘を列挙し、解消 / 未解消 / 別の形で残る を判定させる。併せて、新たな矛盾・スコープ増・レビュー記録の混入を確認させる
- 結論は LGTM / 残指摘（重大・中・軽）
- 再レビューで `pi:human-brief` 節があっても、設計の正本は範囲外の本文だけとする
- 打ち切りは既定 3 回（ユーザー指定があればその回数）。上限で止めたら、残った指摘と採否の理由を報告する

### 5. 人間レビュー用サマリを付ける

[_docs/human-brief.md](../_docs/human-brief.md) に従う。大きな変更では自動で付け、ユーザーが明示的に指示した場合は規模に関係なく付ける。軽微な変更で省略する場合は、理由を会話側に残す。

1. 収束した本文から、3〜6 行の要約と確認観点を書く。本文にない主張を足さない。
2. 動きが説明に必要な場合は [explain-video](../explain-video/SKILL.md) で GIF または MP4 を作る。HTML は編集用で、Issue には添付しない。
3. 本文の先頭に `pi:human-brief` の節を挿入する。開始・終了マーカーは行頭の HTML コメントにし、Issue の開始マーカーには `head` を付けない。
4. 成果物は `/tmp` に置く。GIF は alt 付き、MP4 は alt なしで参照し、同じパスを `attachments` に入れる。
5. FFmpeg または Playwright が使えない場合は、テキストだけの節にして理由を書く。生成できたことにしない。

### 6. Issue を確定する

GitHub への書き込みは [gh](../gh/SKILL.md) の dispatcher を使う（対象リポジトリは実行ディレクトリから解決される）。

```bash
# 起票（GIF を添付する例）
jq -n --rawfile body /tmp/<topic>-issue.md \
  --arg media /tmp/<topic>-brief.gif \
  '{title:"<title>", body:$body, labels:["<label>"],
    attachments:[$media + "#変更の流れ"], grant:"write"}' > /tmp/<topic>-issue-create.json
gh/scripts/gh.sh issue.create /tmp/<topic>-issue-create.json

# 更新（GIF を添付する例）
jq -n --rawfile body /tmp/<topic>-issue.md \
  --arg media /tmp/<topic>-brief.gif \
  '{number:<number>, body:$body,
    attachments:[$media + "#変更の流れ"], grant:"write"}' > /tmp/<topic>-issue-update.json
gh/scripts/gh.sh issue.update /tmp/<topic>-issue-update.json

# 読み直し
jq -n '{number:<number>}' > /tmp/<topic>-issue-get.json
gh/scripts/gh.sh issue.get /tmp/<topic>-issue-get.json
```

- MP4 は alt を付けず、本文では `![](<absolute path>)` の単独段落にし、`attachments:[$media]` にする。メディアを付けない場合は `attachments` を省略する
- タイトル・本文・ラベルは日本語。ラベルはリポジトリの既存のものを使う
- 既存 Issue を更新する場合は、更新直前に `issue.get` で本文を読み、行頭のマーカー間だけを差し替える
- `issue.get` で本文を読み直し、行頭の HTML コメントの開始と終了マーカーが 1 対だけであること、コード Span や引用はマーカーとして数えないこと、参照したメディアのローカルパスが本文に残っていないことを確認する
- 人間レビュー用サマリの固定見出しと確認観点を除き、「レビュー / 指摘 / 下書き / Ver」のような語が混入していないか確認する
- 報告: Issue の URL、タイトル、ラベル、往復回数、未反映の指摘、サマリの形式（GIF / MP4 / テキスト）とサイズ

## 注意

- レビュアーのペインは、ユーザーが明示した時だけ閉じる
- 成果物ファイルとサマリ用の GIF / MP4 は `/tmp` に置き、リポジトリへコミットしない
- サマリは証跡ではない。UI 変更の証跡が必要な場合は、別の契約に従う
