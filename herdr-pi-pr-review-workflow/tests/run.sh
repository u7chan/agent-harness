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
    'Issue は必須ではない', '現在のエージェント',
    'provider、model、thinking は変更しない',
    '別の coordinator、`impl`、`pr-fix`、`ui-tester` を起動しない',
    '../herdr/SKILL.md', '../gh/SKILL.md', '../review/SKILL.md',
    '../review/references/recheck.md', '../_docs/pi-development.md',
    'scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review',
    'ランタイムのデフォルトや別モデルへ黙って切り替えない', 'migration-required',
    'プロファイルや `active` を自動作成・保存・変更しない', '起動引数だけでは証拠にならない',
    'parent-delegate-async.sh', 'child-return-result.sh', '委譲後はターンを終了',
    '最大 3 ラウンド',
    'Round 3 後も Blocker があれば', 'Draft のまま停止',
    '分類返信だけでは LGTM としない', 'workflow コンテキストの auto-resolve',
    '(thread_id, root_comment_id, reviewer_login, classification_reply_id)',
    'resolved=true', '現在の PR head で必須検証がすべて成功',
    'grant: "sensitive-write"', 'draft=false', '同じ head',
    '自動リトライしない', 'レビュアーペインは開いたままにする',
):
    assert value in text, value
assert 'herdr-pi-issue-pr-workflow/' not in text, 'no dependency on the Issue workflow'
completion = text.split('## Completion and Ready\n', 1)[1]
assert completion.index('Ready の直前') < completion.index('5. GH ディスパッチャー')
assert completion.index('5. GH ディスパッチャー') < completion.index('Ready の直後')
assert '単発レビューの依頼では Ready を許可しない' in completion
assert 'head が検証結果と LGTM の対象に一致する' in completion
print('PR review workflow start, delegation, 3-round, Resolve and Ready contracts passed')
PY
