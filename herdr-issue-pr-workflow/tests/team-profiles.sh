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
    'pr_fix_shared_with_impl',
    'ハーネスと Claude の permission_mode を含む全フィールドを使う',
    '実行中に保存プロファイルを書き換えない',
    '保存済み `ui-tester` のハーネスが `claude` の場合は再利用しない',
    '`impl`、`review`、`pr-fix` の保存済みハーネスはそのまま再利用する',
):
    assert value in team, value
assert '同じチームに混ぜた構成は実機未検証' in text
assert 'まず単一ハーネスのチームを検証する' in text
for value in (
    'scripts/pi-development/team-record.sh resolve',
    '編成が明示されていれば再利用せず',
    '保存プロファイルを変更しない',
    '編成は実行限定であり',
    'それ以外は明示指示がある場合だけ',
    'team-record.sh write --profile default',
    '前回承認編成を使用: profile=<name> impl=<harness>:<...> review=<harness>:<...> pr-fix=<harness>:<...> [ui-tester=<harness>:<...>]',
    '保存済みのロールのハーネスと今回指定されたハーネスが異なる場合も再利用しない',
    '保存済み `ui-tester` が `harness=claude` の場合は再利用せず',
    '`対象 PR: 4/4`',
):
    assert value in gate, value
assert '--only-role' not in gate, 'the Issue workflow must still validate the full team'
# The orchestrator is stored in the profile but is not a team member: the team
# table, the approval, and the reuse line stay on team roles, and the kickoff
# gate never re-resolves the orchestrator's start-time specification.
assert 'orchestrator はチームメンバーではない' in text
assert 'チーム表・承認・再利用行の対象外' in text
assert 'launch:' in team
assert '| Role | Assignee | Harness | Provider | Model | Thinking/Effort | Permission | Selection reason |' in gate
assert '| Role | Assignee | Provider | Model | Thinking | Selection reason |' not in gate
assert 'Pi の Permission は `-`、Claude の Provider は `-`' in gate
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
assert 'PI_PROVIDER' not in template and 'PI_MODEL' not in template and 'PI_REASONING_LEVEL' not in template
assert 'Pi / Claude とも `$PI_*` を printf せず' in template
assert 'worktree-team-start.sh' in template
assert '`effective:` 行の `requested=` が `launch:` 行の `spec` と一致' in template
assert 'footer だけで一致とみなさない' in template
assert '.model.id' not in template and '.effort.level' not in template
assert '../../_docs/pi-development.md#launch-and-effective-lines' in template
assert '`spec_source=profile` のときだけ' in template
assert '明示 alias を一度限りで使った起動では canonical な `model`' in template
# Route 2 has no approved team from the starter, so the handoff enters the
# canonical gate instead of assuming one. Route 1 may start at Start the team
# only after confirming the approved composition.
def section(text, heading):
    return text.split(f'{heading}\n', 1)[1].split('\n## ', 1)[0]

procedure = section(template, '## Workflow procedure')
for value in ('Preflight', 'Kickoff gate', 'Start the team', '経路 1', '経路 2'):
    assert value in procedure, value
assert '承認済みまたは再利用したチーム' in procedure
assert '確認できない場合は経路 2' in procedure
assert '承認済みチームがあると仮定しない' in procedure
assert 'Kickoff gate' in procedure and 'を先に実行する' in procedure
worktree = (root.parent / 'herdr' / 'references' / 'worktree-workspace-teams.md').read_text()
orchestrator_first = section(worktree, '### Orchestrator-first')
route2 = [line for line in orchestrator_first.splitlines() if '**経路 2**' in line]
assert len(route2) == 1, route2
assert 'Preflight' in route2[0] and 'Kickoff gate' in route2[0]
# The gate remains team-only: the orchestrator handoff never weakens it.
assert '--only-role' not in gate
assert 'PR が存在し、Draft のままである' in text
assert 'PR を自動で Ready にしたり' in text
assert 'herdr-issue-pr-workflow/scripts/' not in text
assert '`herdr tab close` や `herdr workspace close` は使わない' in text
print('Issue workflow team/bootstrap/Draft contracts passed')
PY
