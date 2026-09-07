# agent-harness

[![Bash](https://badgen.net/static/Shell/Bash/4EAA25)](https://www.gnu.org/software/bash/)
[![GitHub CLI](https://badgen.net/static/GitHub%20CLI/gh/181717?icon=github)](https://cli.github.com/)
[![jq](https://badgen.net/static/JSON/jq/0C7BDC)](https://jqlang.org/)
[![Herdr](https://badgen.net/static/Agent%20Runtime/Herdr/4A9EFF)](https://herdr.dev/)
[![Pi](https://badgen.net/static/Agent/Pi/6A9FCC)](https://pi.dev/)

Minimal, reusable skills and constrained tool harnesses for coding agents.

A skill may consist only of instructions or include a small, purpose-built harness for operations that need predictable validation or safety boundaries.

## Usage

Each top-level skill directory contains a `SKILL.md` file that describes when and how to use that skill.

## Install

Install as a pi package pinned to a merged revision:

```bash
pi install git:github.com/u7chan/agent-harness@<commit-sha>
```

Pi clones the repository and loads the skills declared in `package.json`. Revision confirmation, rollout, rollback, and migration from a symlink install are documented in [_docs/skill-distribution.md](_docs/skill-distribution.md).

## Uninstall

Remove the pi package:

```bash
pi remove git:github.com/u7chan/agent-harness
```

If you linked this repository into other harnesses' skill directories (see the per-harness links in [_docs/skill-distribution.md](_docs/skill-distribution.md)), remove only those `agent-harness` links. Keep `~/.agents/skills`, `~/.codex/skills`, and `~/.claude/skills` themselves and every other entry in them: the parent skill directories and parent symlinks may serve other skills and are not owned by this package.

```bash
# Remove only this package's own links; links that are already absent are skipped.
for link in ~/.agents/skills/agent-harness ~/.claude/skills/agent-harness; do
  if [ -L "$link" ]; then
    unlink "$link"
  fi
done
```

The `-L` guard limits removal to symlinks: a real skill directory is never unlinked. If one of the paths exists as a real directory instead (for example a plain clone from before the pi-package install), inspect it and remove it by hand. Extend the link list if you created links in other harness skill directories.
