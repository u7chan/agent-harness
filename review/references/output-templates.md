# Output Templates

このファイルを GitHub に投稿するコメント、review body、再チェック返信の正本とする。本文は PR と同じ言語で書き、判別できない場合は日本語を使う。波括弧の変数は投稿前にすべて置換する。

## Inline finding

一つの原因と修正方針だけを扱い、原因または修正対象に最も近い差分行へ付ける。ラベルへ補助表記を加えない。

```markdown
**{Blocker|Nit|Consider|FYI}**: {問題と根拠}。{発生条件と影響}。{必要な場合だけ修正案}
```

## Review result

未解決 Blocker がなければ先頭を `LGTM` にする。Nit、Consider、FYI は LGTM と併存できる。必須確認事項を判断できなければ投稿せず、ユーザーへ理由を報告する。

### 指摘なし

```markdown
**LGTM**

確認した範囲に指摘はありません。
```

### 任意指摘のみ

```markdown
**LGTM**

{Nit|Consider|FYI}を{件数}件コメントしました。
```

### Blocker あり

```markdown
**Blocker: {件数}件**

マージ前に確認が必要な指摘をコメントしました。
```

### 再チェック合格

```markdown
**LGTM**

前回指摘の解消を確認しました。
```

## Recheck replies

```markdown
**Resolved**: {解消を確認できた根拠}
```

```markdown
**Partial** (**{元のラベル}**): {残っている条件と影響}
```

```markdown
**Unresolved** (**{元のラベル}**): {残っている条件と影響}
```

```markdown
**Unknown**: {判定できない理由}
```

## Review details

監査情報が必要な場合だけ review result の末尾へ追加する。確認不能な重要制約は Scope に含め、それ以外の見送った候補や取得手段は記録しない。

```markdown
<details>
<summary>Review details</summary>

- Commit: `{full SHA}`
- Round: `{n}/3`
- Scope: {意味で要約した確認範囲}

</details>
```
