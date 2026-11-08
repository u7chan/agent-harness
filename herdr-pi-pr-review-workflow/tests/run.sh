#!/usr/bin/env bash
# Instruction-only workflow contracts: no Herdr, Pi, network, or user settings.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../SKILL.md" <<'PY'
import json
import pathlib
import sys

skill = pathlib.Path(sys.argv[1]).resolve()
text = skill.read_text()
root = skill.parent.parent
assert skill.parent.name in json.loads((root / 'package.json').read_text())['pi']['skills']
for value in (
    'PR作ったらレビューおねがい', 'PR作ってレビューして',
    'PR がまだない場合', 'PR 作成を含まない依頼で PR を勝手に作らない',
    'Draft でない既存 PR は Draft 化しない', 'base はリポジトリの指示とブランチの親から決める',
    'push 結果が不明なら停止する', '既に Ready の PR では `pr.ready` を実行しない',
    '右に分割できない場合は、別方向を推測せずユーザーに確認する',
    'Round 4/5', 'round_kind=polish',
    'Issue は必須ではない', '現在のエージェント',
    'provider、model、thinking は変更しない',
    '別の coordinator、`impl`、`pr-fix`、`ui-tester` を起動しない',
    '../herdr/SKILL.md', '../gh/SKILL.md', '../review/SKILL.md',
    '../review/references/recheck.md', '../_docs/pi-development.md',
    'scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review',
    'ランタイムのデフォルトや別モデルへ黙って切り替えない', 'migration-required',
    'プロファイルや `active` を自動作成・保存・変更しない', '起動引数だけでは証拠にならない',
    'parent-delegate-async.sh', 'child-return-result.sh', '委譲後はターンを終了',
    'draft: true', 'grant: "write"', 'references/evidence.md',
    '初回を含め、レビューは最大 3 ラウンドとする',
    'Round 3 後も Blocker があれば', 'Draft のまま停止',
    'polish', '最大 2 回', '通常ラウンドへ戻さず',
    '分類返信だけでは LGTM としない', 'workflow コンテキストの auto-resolve',
    '(thread_id, root_comment_id, reviewer_login, classification_reply_id)',
    'resolved=true', '現在の PR head で必須検証がすべて成功',
    'grant: "sensitive-write"', 'draft=false', '同じ head',
    '自動リトライしない', 'レビュアーペインは開いたままにする',
    'マージは行わない', '最終ゲートは人間', '別 Issue 候補',
):
    assert value in text, value
assert 'herdr-pi-issue-pr-workflow/' not in text, 'no dependency on the Issue workflow'
evidence = (skill.parent / 'references' / 'evidence.md').read_text()
for value in (
    'pi-pr-review-workflow:ui-evidence', 'PR 本文には入れない',
    '10 MB', 'attachments', 'grant: "write"', '同じ head',
):
    assert value in evidence, value
review = (root / 'review' / 'SKILL.md').read_text()
assert 'PR 作成、別ペインのレビュアー、修正ループ、Ready まで含む依頼には使わない' in review
recheck = (root / 'review' / 'references' / 'recheck.md').read_text()
assert 'round_kind=polish' in recheck
assert 'polish_round=<1|2>' in recheck
templates = (root / 'review' / 'references' / 'output-templates.md').read_text()
assert '{n}/{cap}' in templates
preflight = text.split('## Preflight\n', 1)[1].split('## Reviewer Setup', 1)[0]
assert preflight.index('対象 PR を 1 件特定する') < preflight.index('push 済み HEAD が PR の head に一致する')
completion = text.split('## Completion and Ready\n', 1)[1]
assert completion.index('Ready の直前') < completion.index('5. GH ディスパッチャー')
assert completion.index('5. GH ディスパッチャー') < completion.index('Ready の直後')
assert '単発レビューの依頼では Ready を許可しない' in completion
assert 'head が検証結果と LGTM の対象に一致する' in completion
assert 'マージは行わない' in completion
assert 'Draft でなければ `pr.ready` を実行せず、手順 6 へ進む' in completion
assert '既に Ready だった場合は手順 4 の後' in completion
print('PR review workflow trigger, PR creation, evidence, 3+2-round, Resolve, Ready and human-merge contracts passed')
PY
