# agent-harness

Minimal skills and constrained tool harnesses for coding agents.

## Purpose

Coding Agent 向けの最小 Skill と、危険または複雑な CLI / API 操作を制約付きで提供する実行 Harness を管理する。

```
User intent
    ↓
SKILL.md
    ↓
Action catalog / schema
    ↓
Dispatcher / validation
    ↓
CLI / API
```

すべての Skill が Harness を必要とするわけではない。

自然言語による判断や既存 CLI の直接利用で十分な場合は `SKILL.md` のみに留め、入力検証、権限管理、API 操作、再実行制御など、結果をぶらしてはいけない処理だけをコード化する。

## Principles

- Skill は短く保ち、Agent の判断と手順を記述する
- 決定論的な制約は Shell、schema、test で実装する
- 同じ定義を複数箇所で管理しない
- 生の CLI / API より、小さく制約された Action を優先する
- 不明な実行結果を成功または失敗と推測しない
- 必要性が証明されるまで独自 Runtime や状態管理を作らない
- 自動化可能な範囲ではなく、持続可能な範囲を実装する

## Structure

```
<skill>/
  SKILL.md

<skill>/
  SKILL.md
  actions.json
  scripts/
  tests/
  references/
```

- Prompt-only Skill: 自然言語判断と既存 CLI の直接利用
- Tool Harness: schema、権限、dispatcher、検証が必要な CLI / API 操作

## Boundary

`SKILL.md` に置くもの:

- タスク分解
- Action / Agent の選択
- 状況依存の継続・停止判断
- レビュー観点
- ワークフロー

コードに置くもの:

- 入力 schema
- 権限判定
- CLI / API 引数の構築
- pagination
- timeout と再実行条件
- write 後の検証
- 共通出力形式
- 二重実行や誤操作の防止

原則として持たないもの:

- 汎用 Agent Runtime
- 独自 multiplexer
- 必要性のない永続状態
- Agent の判断を置き換える巨大な dispatcher
- 複数箇所で重複する Action 定義

## Install

```bash
git clone https://github.com/u7chan/agent-harness.git
cd agent-harness
mkdir -p ~/.agents/skills
ln -s "$(pwd)" ~/.agents/skills/agent-harness
```

```bash
ln -s ~/.agents/skills ~/.codex/skills
ln -s ~/.agents/skills ~/.claude/skills
```

## Uninstall

```bash
unlink ~/.codex/skills
unlink ~/.claude/skills
unlink ~/.agents/skills/agent-harness
```
