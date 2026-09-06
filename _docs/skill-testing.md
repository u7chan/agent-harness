# PR 段階のスキル検証ナレッジ

- ステータス: 運用ナレッジ(実測: 2026-09-02)
- 対象: 未マージ(PR 段階)のスキル変更をマージ前に検証する手順
- 位置づけ: 未マージ skill 検証手順の**正本**。[_docs/skill-distribution.md](skill-distribution.md) の Development 節はこの文書へリンクする(手順はここだけに書く)
- 関連: [_docs/skill-distribution.md](skill-distribution.md)(配布・ロールアウト手順)

## なぜこのナレッジが必要か

スキルの操作セットは**ピン留めクローン**(pi install が配置する固定 SHA のクローン。
配置先パスについては [_docs/skill-distribution.md](skill-distribution.md) 参照)であり、
開発チェックアウト・worktree はスキャンパスにない(_docs/skill-distribution.md 参照)。

つまりブランチ上のスキル変更は、別ペインの pi を普通に起動しても**見えない**。
`--attach` 対応(PR #145)の実機検証で確立した、未マージ変更を検証する方法を記録する。

## 検証方法

### どの方法を使うか

前提: ピン留め版がインストール済みの通常環境。**この環境では方法2 を使う。** 方法1 は同名の
インストール済みスキルとの衝突で明示パスがロードされない(下記実測)ため、通常環境の検証には
使えない。方法1 の記録は `--skill` 衝突挙動の観察用として残す。

両方法ともセッション限定であり、global の配布先(ピン留めクローン、`~/.agents/skills/` 等)や
project の skill 配置を書き換えない。ピン留めクローンの更新(`pi install` / `pi update`)も行わない。

### 方法1: `--skill` によるセッション限定ロード(衝突あり)

```bash
pi --provider opencode-go --model deepseek-v4-flash --thinking max \
  --skill <checkout>/gh/SKILL.md
```

(`<checkout>` はこのリポジトリの開発チェックアウトの絶対パス)

- pi の仕様: 同名スキルは**最初に見つかったものを保持**(docs/skills.md "Name collisions ... keep the first skill found")
- 実測(2026-09-02): インストール済み gh スキル(git:...@da12c84)が優先され、明示パスは
  `✗ <checkout>/gh/SKILL.md (skipped)` となった(ロードされない)
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
(実行時は <checkout> を開発チェックアウトの絶対パスへ置換してエージェントに渡す。この文書内では実パスを記載しない)
- <checkout>/gh/SKILL.md
- <checkout>/gh/actions.json
- <checkout>/gh/scripts/gh.sh(引数: <アクション名> <入力JSONファイル>)
```
4. 検証の完了条件に「対象版の確認(証跡)」を含める(下記)。実際に読むパスと revision を
   確認せずに検証完了としない

### 対象版の確認(証跡)(未実測・設計)

2026-09-02 の実測には含まない。pi の挙動(docs/skills.md: 同名スキルは最初に見つかったものを保持、
SKILL.md 本文は on-demand で読む)に基づく設計であり、方法2 と併用する。要実測。

準備(テスト開始前に検証者が実施):

```bash
git -C <checkout> rev-parse HEAD   # 想定 revision を記録。テスト中は checkout を切り替えない
```

- 旧版に無い目印(マーカー)を 1 つ決める。選定元は skill ディレクトリ全体の差分
  `git diff <installed-sha>..<対象 revision> -- <skill>/`(SKILL.md に限らない)の追加行から、
  応答の引用として現れやすい断片を選ぶ。SKILL.md に追加行がない変更(スクリプトや actions.json
  のみの修正)では、変更のあったファイルの追加行を選ぶ

完了条件(テスト終了時に確認):

1. テストエージェントの報告に、実際に読んだファイルの絶対パス(SKILL.md・actions.json・
   実行ディスパッチャー・references)が列挙されていること
2. 報告にマーカーを含む行の引用があること(旧版の内容からは出せない応答であること)
3. テスト終了時にも `git -C <checkout> rev-parse HEAD` が準備で記録した revision と一致すること
   (skill-distribution.md の検証済み事実: on-demand 読み取りは checkout の working tree の現在内容に
   従う。テスト中に checkout が動くと一致は崩れる)

任意(未実測): テストセッションの JSONL を後検証し、read ツール呼び出しの絶対パスが `<checkout>`
配下を指していることを確認する。設計根拠: pi はセッション JSONL にツール呼び出しを記録する。要実測。

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