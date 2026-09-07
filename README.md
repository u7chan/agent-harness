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

## Prerequisites

Verified scope: Linux. The measurements in [_docs/skill-distribution.md](_docs/skill-distribution.md) were taken on the reference machine (Linux), and the repository's CI workflow ([contract-tests](.github/workflows/contract-tests.yml)) runs on `ubuntu-latest`. macOS and other operating systems are not verified and are not supported: the harnesses assume GNU Bash and GNU command-line tools, so BSD and other toolchains are out of scope.

Commands used by the harnesses and by this repository's documented procedures:

| Command | Used for | Required by |
| --- | --- | --- |
| GNU Bash | running every harness script (`#!/usr/bin/env bash` with `set -euo pipefail`) | every scripted harness (gh, herdr, review) |
| git | the rollout gate, revision confirmation, rollback, and smoke procedures; pi clones git packages with it | the distribution procedures in `_docs/skill-distribution.md` |
| jq | JSON parsing and validation | the gh and review harness scripts and the smoke test's manifest check |
| gh CLI | GitHub API access (`gh api`, `gh auth status`) | the gh skill dispatcher; version 2.99.0 or later for attachments |
| pi | agent runtime and package management (`pi install`, `pi remove`, `pi list`) | every skill and procedure in this repository |
| herdr | delegating prompts to other panes (`herdr agent prompt`) | the herdr skill scripts |
| python3 | the review skill's recheck harness (`review/scripts/recheck-state.sh`); optional for the herdr delegation scripts, which use it only for a cosmetic pane label and fall back gracefully without it | the review skill; optional for the herdr skill |
| GNU coreutils and text tools (`sed`, `grep`, `head`, `cat`, `mktemp`, `sleep`, `ln`, `unlink`, `readlink`, ...) | shared plumbing across scripts; `ln`/`unlink`/`readlink` also appear in the link-removal procedure under Uninstall | every scripted harness |

`curl` is not a dependency: no script in this repository invokes it. The gh dispatcher talks to the GitHub API through the gh CLI, and the only `curl` occurrence in harness code is a retry-classification pattern in `gh/scripts/common/http.sh` that matches gh CLI error text.

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

If you linked this repository into other harnesses' skill directories (see the per-harness links in [_docs/skill-distribution.md](_docs/skill-distribution.md)), remove only those `agent-harness` links. Keep `~/.agents/skills`, `~/.codex/skills`, and `~/.claude/skills` themselves and every other entry in them: these are the harnesses' standard per-user skill directories (conventions that read the same on every machine, not machine-specific paths), and the parent skill directories and parent symlinks may serve other skills and are not owned by this package.

```bash
# Remove only this package's own links; links that are already absent are skipped.
for link in ~/.agents/skills/agent-harness ~/.claude/skills/agent-harness; do
  if [ -L "$link" ]; then
    unlink "$link"
  fi
done
```

The `-L` guard limits removal to symlinks: a real skill directory is never unlinked. If one of the paths exists as a real directory instead (for example a plain clone from before the pi-package install), inspect it and remove it by hand. Extend the link list if you created links in other harness skill directories.
