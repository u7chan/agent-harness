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
    '編成は実行限定であり',
    'それ以外は明示指示がある場合だけ',
    'team-record.sh write --profile default',
    '前回承認編成を使用: profile=<name> impl=<provider>/<model>/<thinking> review=<provider>/<model>/<thinking> pr-fix=<provider>/<model>/<thinking> [ui-tester=<provider>/<model>/<thinking>]',
):
    assert value in gate, value
assert '--only-role' not in gate, 'the Issue workflow must still validate the full team'
assert 'PR が存在し、Draft のままである' in text
assert 'PR を自動で Ready にしたり' in text
assert 'herdr-pi-issue-pr-workflow/scripts/' not in text
assert '`herdr tab close` や `herdr workspace close` は使わない' in text
print('Issue workflow team/bootstrap/Draft contracts passed')
PY
