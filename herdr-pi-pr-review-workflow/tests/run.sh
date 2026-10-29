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
    'Issueは不要', '現在のエージェント', '窓口のprovider / model / thinkingは変更しない',
    '`impl`、`pr-fix`、`ui-tester`は起動しない',
    '../herdr/SKILL.md', '../gh/SKILL.md', '../review/SKILL.md',
    '../review/references/recheck.md', '../_docs/pi-development.md',
    'scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review',
    '環境既定や別モデルへ黙ってフォールバックしない', 'migration-required',
    'bootstrapも行わず', '起動引数だけを証拠にしない',
    'parent-delegate-async.sh', 'child-return-result.sh', '委譲したらターンを終える',
    '初回を含め最大3ラウンド', 'Round 3後もBlockerがあれば', 'Draftのまま停止',
    '分類返信だけではLGTMにならない', 'workflowコンテキストの自動Resolve',
    '(thread_id, root_comment_id, reviewer_login, classification_reply_id)',
    'resolved=true', '必須検証が現在のPR headですべて成功',
    'grant: "sensitive-write"', 'draft=false', '同じhead',
    '自動再試行しない', 'ペインは開いたまま',
):
    assert value in text, value
assert 'herdr-pi-issue-pr-workflow/' not in text, 'no dependency on the Issue workflow'
completion = text.split('## 完了とDraft解除\n', 1)[1]
assert completion.index('Draft解除の直前') < completion.index('5. GH dispatcherの`pr.ready`')
assert completion.index('5. GH dispatcherの`pr.ready`') < completion.index('Draft解除の直後')
assert '単発レビュー依頼をその承認に読み替えない' in completion
assert 'headが検証とLGTMの対象に一致' in completion
print('PR review workflow start, delegation, 3-round, Resolve and Ready contracts passed')
PY
