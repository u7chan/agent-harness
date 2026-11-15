#!/usr/bin/env bash
# Keep the Issue workflow's team approval/bootstrap and Draft completion rules
# separate from the shared storage/validation tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
python3 - "$SKILL_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
text = (root / 'SKILL.md').read_text()
team = text.split('## Team profiles\n', 1)[1].split('\n## ', 1)[0]
gate = text.split('## Kickoff gate\n', 1)[1].split('\n## ', 1)[0]
for value in (
    '../_docs/pi-development.md',
    'result=missing', 'reason=no-profiles', 'profiles_present=false', 'source=default',
    'となるため初期化しない', 'migration-required',
):
    assert value in team, value
for value in (
    'scripts/pi-development/team-record.sh resolve',
    '編成が明示されていれば再利用せず',
    '保存プロファイルを変更しない',
    '編成は実行限定であり',
    'それ以外は明示指示がある場合だけ',
    'team-record.sh write --profile default',
    '前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]',
):
    assert value in gate, value
assert '--only-role' not in gate, 'the Issue workflow must still validate the full team'
# The orchestrator is stored in the profile but is not a team member: the team
# table, the approval, and the reuse line stay on team roles, and the kickoff
# gate never re-resolves the orchestrator's start-time specification.
assert 'orchestrator はチームメンバーではない' in text
assert 'チーム表・承認・再利用行の対象外' in text
assert 'launch:' in team
assert '| Role | Assignee | Provider | Model | Thinking | Selection reason |' in gate
assert 'orchestrator=' not in gate, 'the reuse line stays on team roles'
assert '| orchestrator |' not in gate, 'the team table stays on team roles'
template = (root / 'references' / 'kickoff-task-template.md').read_text()
assert '起動元（starter）が orchestrator に渡すタスク文面' in template
assert 'role: orchestrator' in template
for value in ('provider: <provider>', 'model: <model>', 'thinking: <level>'):
    assert value not in template, value
assert '親は同じ 3 つの値を' not in template
assert '--role orchestrator' in template
assert 'launch:' in template
assert 'PI_PROVIDER' in template and 'PI_MODEL' in template and 'PI_REASONING_LEVEL' in template
assert '`PI_*`' in template
assert 'PR が存在し、Draft のままである' in text
assert 'PR を自動で Ready にしたり' in text
assert 'herdr-pi-issue-pr-workflow/scripts/' not in text
assert '`herdr tab close` や `herdr workspace close` は使わない' in text
print('Issue workflow team/bootstrap/Draft contracts passed')
PY
