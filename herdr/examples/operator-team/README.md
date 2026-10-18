# Operator team example

The generalized shape of a standing composition
([Operator team roles](../../references/operator-team-roles.md)): the label
file, one role document per role, and the companion scripts. It is extracted
from a private setup, so every value is a placeholder — a path, a plugin id, an
agent name, and a role display name — and the scripts show the split of
responsibility rather than a supported harness. Nothing here is installed,
executed, or tested by this repository.

```text
operator-team/
  panes.conf              label literals, read by every script
  roles/
    orchestrator.md       request window and judgement
    advisor.md            read-only investigation and drafts
    scribe.md             records and prose
    controller.md         run watch, merge gate, and cleanup
  bin/
    restore-session.sh    rebuild the panes from the labels
    sync.sh               fast-forward the standing checkouts
    size-check.sh         report records over their limit
    runs.sh               list live workspaces by display name
```
