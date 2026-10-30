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
    'No Issue is required', 'The current agent',
    "Keep the current agent's provider, model, and thinking unchanged",
    'Do not start another coordinator, `impl`, `pr-fix`, or `ui-tester`',
    '../herdr/SKILL.md', '../gh/SKILL.md', '../review/SKILL.md',
    '../review/references/recheck.md', '../_docs/pi-development.md',
    'scripts/pi-development/team-record.sh resolve [--profile <name>] --only-role review',
    'Never silently fall back to runtime defaults or another model', 'migration-required',
    'Do not bootstrap', 'Startup arguments alone are not evidence',
    'parent-delegate-async.sh', 'child-return-result.sh', 'End the turn after delegation',
    'at most three rounds, including the initial review',
    'If a Blocker remains after Round 3', 'stop with the PR still Draft',
    'Classification replies alone cannot establish LGTM', 'workflow-context auto-resolve',
    '(thread_id, root_comment_id, reviewer_login, classification_reply_id)',
    'resolved=true', 'All required verification has passed on the current PR head',
    'grant: "sensitive-write"', 'draft=false', 'the same head',
    'never retry automatically', 'Keep the reviewer pane open',
):
    assert value in text, value
assert 'herdr-pi-issue-pr-workflow/' not in text, 'no dependency on the Issue workflow'
completion = text.split('## Completion and Ready\n', 1)[1]
assert completion.index('Immediately before Ready') < completion.index('5. Call the GH dispatcher')
assert completion.index('5. Call the GH dispatcher') < completion.index('Immediately after Ready')
assert 'A one-shot review request does not authorize Ready' in completion
assert 'a head matching the verification and LGTM' in completion
print('PR review workflow start, delegation, 3-round, Resolve and Ready contracts passed')
PY
