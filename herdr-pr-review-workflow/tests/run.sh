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
    'PR 作成経路では `draft=true` であることも確認する',
    'push 結果が不明なら停止する', '既に Ready の PR では `pr.ready` を実行しない',
    '右に分割できない場合は、別方向を推測せずユーザーに確認する',
    'Round 4/5', 'round_kind=polish',
    'Issue は必須ではない', '現在のエージェント',
    '現在のエージェントの起動仕様は変更しない',
    '別の coordinator、`impl`、`pr-fix`、`ui-tester` を起動しない',
    '../herdr/SKILL.md', '../gh/SKILL.md', '../review/SKILL.md',
    '../review/references/recheck.md', '../_docs/pi-development.md',
    '../_docs/skill-distribution.md#merge--rollout', '../_docs/human-brief.md',
    'pi:human-brief', '人間レビュー用サマリ',
    'scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review',
    'review=<harness>:<...>', 'pi:<provider>/<model>/<thinking>',
    'claude:<model>/<effort>/<permission_mode>',
    'herdr/scripts/start-agent.sh <pane-id> pr-review',
    '--spec <harness>:<...>', '--profile <name|-> --role review',
    '--spec-source <profile|explicit> --origin <explicit|active|default>',
    '`review` の spec をそのまま使う場合だけ `--spec-source profile` にする',
    '明示上書きを 1 つでも適用した場合',
    '`spec_source` と `origin` は別物',
    'プロファイルが `result=ok` のときは、同じハーネスの範囲で指定されたフィールドだけを上書きし、指定されていない値はプロファイルから補う',
    'ハーネスをまたぐフィールドの混在',
    'プロファイルと異なるハーネスを名指しした場合は、プロファイルを土台にせず',
    'Claude の permission_mode の省略は',
    'Pi の部分的に揃った指定は、プロファイルや推測で埋めずに停止する',
    'ユーザー指定が部分的に揃っている場合は、実行環境の既定で補わずに停止する',
    '土台のプロファイル `default` の `review` が Claude で、model と permission_mode が揃っている場合に限り',
    'ハーネスをまたぐフィールドの混在はこの形にできないため停止する',
    '--profile - --role review --spec-source explicit --origin explicit',
    '--profile default --role review --spec-source explicit --origin default',
    '--spec-source profile --origin default',
    '起動に使った pane ID をそのまま使い',
    '共有ランチャーは JSON を返さず',
    'resolve-model-spec.sh --harness pi', 'resolve-model-spec.sh --harness claude',
    'verification=exact', 'verification=postlaunch',
    'claude auth status', '~/.claude/skills',
    '../herdr/SKILL.md#claude-trust-approval',
    'Pi と Claude は、共有ランチャーが stderr に出す最後の `effective:` 行',
    'footer だけで一致とみなさない',
    'ランタイムのデフォルトや別モデルへ黙って切り替えない', 'migration-required',
    'プロファイルや `active` を自動作成・保存・変更しない', '起動引数だけでは証拠にならない',
    'parent-delegate-async.sh', 'child-return-result.sh', '委譲後はターンを終了',
    'draft: true', 'grant: "write"', 'references/evidence.md',
    'PR 本文の証跡節', '../_docs/pr-evidence.md', '本文の証跡節が現在 head を指し',
    '初回を含め、レビューは最大 3 ラウンドとする',
    'Round 3 後も Blocker があれば', 'Draft のまま停止',
    'polish', '最大 2 回', '通常ラウンドへ戻さず', 'polish は既定で実施せず',
    '受け入れ条件ごとの検証結果',
    '分類返信だけでは LGTM としない', 'workflow コンテキストの auto-resolve',
    '(thread_id, root_comment_id, reviewer_login, classification_reply_id)',
    'resolved=true', '現在の PR head で必須検証がすべて成功',
    'grant: "sensitive-write"', 'draft=false', '同じ head',
    '自動リトライしない', 'レビュアーペインは開いたままにする',
    'マージは行わない', '最終ゲートは人間', '別 Issue 候補',
):
    assert value in text, value
assert "printf 'effective:" not in text, 'the agent does not print the effective line'
assert 'herdr-issue-pr-workflow/' not in text, 'no dependency on the Issue workflow'
evidence = (skill.parent / 'references' / 'evidence.md').read_text()
for value in (
    '_docs/pr-evidence.md', 'PR 本文の証跡節', 'pr.create', 'pr.update',
    '10 MB', '変更箇所の印', 'playwright/references/evidence.md',
    'After だけを撮る場合も', '現在 head', '再利用',
):
    assert value in evidence, value
for value in ('PR 本文には入れない', 'pi-pr-review-workflow:ui-evidence', 'comments.create'):
    assert value not in evidence, value
pr_evidence = (root / '_docs' / 'pr-evidence.md').read_text()
for value in (
    'pi:ui-evidence:start', 'pi:ui-evidence:end', '## UI Evidence',
    'pr.create', 'pr.update', 'attachments', 'grant: "write"', '再利用',
    '2 列まで', '3 列以上にしない', '<img width="<px>">', 'unknown_outcome',
    '130px', '現在 head', 'ローカルパス', 'Draft のまま停止',
    '視覚的な確認記録', '機能要件の検証結果の代替にはならない',
):
    assert value in pr_evidence, value
for value in ('PR 本文には入れない', 'comments.create', 'comments.update'):
    assert value not in pr_evidence, value
human_brief = (root / '_docs' / 'human-brief.md').read_text()
for value in (
    'pi:human-brief:start', 'pi:human-brief:end', '## 人間レビュー用サマリ',
    'GIF', 'MP4', 'attachments', 'pr.update', 'issue.get', '10 MB',
    'AI', '正本', 'UI Evidence', 'この節は証跡ではなく', 'head',
    '行頭の HTML コメント', 'コード Span',
):
    assert value in human_brief, value
assert '本文の `pi:human-brief` 範囲は除く' in text
assert 'PR 本文の `pi:human-brief` 範囲は読まないことも伝える' in text
# The workflow is harness-neutral: the reviewer is whichever harness the
# profile or the explicit override selects, and it starts only through the
# shared launcher.
assert 'Pi レビュアー' not in text
assert 'Pi の起動' not in text
assert '`pi` も必須とする' not in text
assert '--kind pi' not in text
assert 'herdr agent start' not in text
assert 'JSON 応答' not in text
reviewer = text.split('## Reviewer Setup\n', 1)[1].split('## Review and Fixes', 1)[0]
assert 'herdr/scripts/start-agent.sh' in reviewer
assert '--role review' in reviewer
assert 'herdr pane rename <pane-id> pr-review' in reviewer
assert '起動に使った pane ID をそのまま使い' in reviewer
assert '共有ランチャーは JSON を返さず' in reviewer
assert 'effective:' in reviewer
preflight = text.split('## Preflight\n', 1)[1].split('## Reviewer Setup', 1)[0]
assert 'レビュアーに使うハーネスの CLI も必須とする' in preflight
assert 'claude auth status' in preflight
assert '../herdr/SKILL.md#claude-trust-approval' in preflight
assert 'claude-trust:' not in preflight
assert '人間レビュー用サマリが必要な場合' in text
assert '行頭の HTML コメントのマーカーが 1 対だけ' in text
assert '証跡の代わりにならない' in evidence
gh_skill = (root / 'gh' / 'SKILL.md').read_text()
assert 'pi:human-brief' in gh_skill
assert 'not a requirement' in gh_skill
assert 'Treat only HTML comment lines as markers' in gh_skill
assert 'skip the range' in gh_skill
assert 'content outside the markers as authoritative' in gh_skill
review = (root / 'review' / 'SKILL.md').read_text()
assert 'PR 作成、別ペインのレビュアー、修正ループ、Ready まで含む依頼には使わない' in review
assert '`pi:human-brief` 範囲は読まず' in review
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
pi_development = (root / '_docs' / 'pi-development.md').read_text()
assert 'resolve [--profile <name>] --only-role review' in pi_development
assert 'resolve [--profile <name>] --only-role orchestrator' in pi_development
print('PR review workflow trigger, PR creation, evidence, 3+2-round, Resolve, Ready and human-merge contracts passed')
PY
