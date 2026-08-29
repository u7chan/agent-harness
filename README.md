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

Remove the package and any links created for other harnesses:

```bash
pi remove git:github.com/u7chan/agent-harness
unlink ~/.codex/skills
unlink ~/.claude/skills
```
