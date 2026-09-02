# PR 段階のスキル検証ナレッジ

- ステータス: 運用ナレッジ(実測: 2026-09-02)
- 対象: 未マージ(PR 段階)のスキル変更をマージ前に検証する手順
- 関連: [_docs/skill-distribution.md](skill-distribution.md)(配布・ロールアウト手順)

## なぜこのナレッジが必要か

スキルの操作セットは**ピン留めクローン** `~/.pi/agent/git/github.com/u7chan/agent-harness@<sha>`(pi install 経由)であり、
開発チェックアウト・worktree はスキャンパスにない(_docs/skill-distribution.md 参照)。

つまりブランチ上のスキル変更は、別ペインの pi を普通に起動しても**見えない**。
`--attach` 対応(PR #145)の実機検証で確立した、未マージ変更を検証する方法を記録する。

## 検証方法

### 方法1: `--skill` によるセッション限定ロード(衝突あり)

```bash
pi --provider opencode-go --model deepseek-v4-flash --thinking max \
  --skill /home/u7dev/workspace/agent-harness/gh/SKILL.md
```

- pi の仕様: 同名スキルは**最初に見つかったものを保持**(docs/skills.md "Name collisions ... keep the first skill found")
- 実測(2026-09-02): インストール済み gh スキル(git:...@da12c84)が優先され、明示パスは
  `✗ ~/workspace/agent-harness/gh/SKILL.md (skipped)` となった(ロードされない)
- 回避案(未実測・docs より): `--no-skills` で discovery を無効化すると `--skill` のみ additive に
  ロードされる。ただし**全スキル無効化**なので herdr 等他スキルも消える。要実測

### 方法2: 絶対パス直読み(実践済み・推奨)

スキルの本質は「SKILL.md の指示をプロンプトに注入する」だけ。実行実体はスクリプトなので、
ロードに頼らずに直接読ませる方式。`--skill` の衝突が起きず、旧スキルとの混線もない。

1. テスト用 pi を別ペインに通常起動(`--skill` 指定は不要・むしろ衝突する)
2. プロンプトで以下を明示する:
   - **ロード済みの同名スキル(旧版)は使わない**こと
   - 検証対象の絶対パス: `SKILL.md` / `actions.json` / 実行ディスパッチャー / 参考スクリプト
   - 実行実体はすべて作業チェックアウトのものを使用すること
3. 例(gh スキル):

```text
スキルの読み方: ロード済みの旧 gh スキルは使わず、以下を直接読んで手順を把握すること:
- /home/u7dev/workspace/agent-harness/gh/SKILL.md
- /home/u7dev/workspace/agent-harness/gh/actions.json
- /home/u7dev/workspace/agent-harness/gh/scripts/gh.sh(引数: <アクション名> <入力JSONファイル>)
```

## 実機テストの運用ルール

- テスト資産(画像・動画)は**リポジトリ外**(`/tmp/…` 等)に置き、リポジトリへコミットしない
- パスは絶対パスで統一。body 内の参照文字列とアクション引数(`attachments` 等)は
  **完全に同一文字列**にする(gh は文字列一致で参照置換する)
- 書き込み結果はハーネスの envelope(status / 書き込み後検証)で判定し、
  読み取りアクションで再取得して実体(URL 等)を裏取りする
- テスト痕跡(本文・コメントへの画像埋め込み)は「残す(検証証跡)」か「戻す」かを事前に決める
- マージ後も、配布手順([_docs/skill-distribution.md](skill-distribution.md))が最終確認
  (gate チェック → pi install → 全セッション /reload → スモーク)
- 注意: 「コメントへの --attach は NG」という情報が流布しているが、gh 2.99.0 では
  issue コメント・PR コメントとも実機で成功した(2026-09-02 実測)。外部情報を鵜呑みにせず
  実機で確認すること