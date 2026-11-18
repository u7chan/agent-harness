# agent-harness

[![Bash](https://badgen.net/static/Shell/Bash/4EAA25)](https://www.gnu.org/software/bash/)
[![git](https://badgen.net/static/VCS/git/F05032?icon=git)](https://git-scm.com/)
[![GitHub CLI](https://badgen.net/static/GitHub%20CLI/gh/181717?icon=github)](https://cli.github.com/)
[![jq](https://badgen.net/static/JSON/jq/0C7BDC)](https://jqlang.org/)
[![Python 3](https://badgen.net/static/Language/Python%203/3776AB?icon=python)](https://www.python.org/)
[![Playwright](https://badgen.net/static/Browser/Playwright/2EAD33)](https://playwright.dev/)
[![Herdr](https://badgen.net/static/Agent%20Runtime/Herdr/4A9EFF)](https://herdr.dev/)
[![Pi](https://badgen.net/static/Agent/Pi/6A9FCC)](https://pi.dev/)

Minimal, reusable skills and constrained tool harnesses for coding agents.

A skill may consist only of instructions or include a small, purpose-built harness for operations that need predictable validation or safety boundaries.

## Usage

Each top-level skill directory contains a `SKILL.md` file that describes when and how to use that skill.

- [Issue-to-PR workflow](herdr-pi-issue-pr-workflow/SKILL.md): delegate a defined
  Issue to an implementation team; finish with a reviewed Draft PR.
- [PR review workflow](herdr-pi-pr-review-workflow/SKILL.md): create a Draft PR
  when the request includes it, keep the current agent as developer, add only a
  Pi Reviewer, and review/fix for at most three rounds plus up to two polish
  rounds before verified LGTM, eligible Resolve, and Ready. Merge remains a
  human decision. Triggered by "PR作ったらレビューおねがい".

Both use the user-owned [development profiles](_docs/pi-development.md) under
`pi-development/`; the shared helpers do not belong to either skill. Existing
users migrate with [the backed-up procedure](_docs/pi-development-migration.md)
as part of rollout, not by installing unmerged skill changes.

UI evidence for both workflows follows [PR body evidence](_docs/pr-evidence.md):
the evidence belongs in the PR body, not in PR comments.

Long Issue and PR bodies can carry a human review brief defined by
[human review brief](_docs/human-brief.md): a marked summary with a GIF or MP4
at the top. Agents skip the marked section; it is not evidence.

## Prerequisites

Linux remains the full CI baseline: the measurements in [_docs/skill-distribution.md](_docs/skill-distribution.md) were taken on Linux, and the existing [contract-tests](.github/workflows/contract-tests.yml) job runs on `ubuntu-latest`. Linux and WSL keep their existing Bash/GNU-tool invocation and PATH; there is no automatic macOS setup applied to other platforms. WSL has not been separately real-machine tested for this change, and native Windows shells (PowerShell/cmd) are outside the support scope.

The gh shared attachment path additionally accommodates macOS system Bash 3.2 when the required GNU tools are supplied to the harness process. Its [runtime compatibility notes](gh/references/runtime-compatibility.md) distinguish macOS mock CI, real upload evidence, and remaining verification limits. This is not blanket macOS support for every harness or for a BSD-only toolchain.

Commands used by the harnesses and by this repository's documented procedures:

| Command | Used for | Required by |
| --- | --- | --- |
| GNU Bash | running every harness script (`#!/usr/bin/env bash` with `set -euo pipefail`); the gh attachment path handles Bash 3.2 empty arrays without requiring Bash 5; developer checks may need newer Bash | every scripted harness (gh, herdr, review) |
| git | fetching, gating, exporting, and switching the served revision; the merge checks | the distribution command in `scripts/skill-distribution/` and the procedures in `_docs/skill-distribution.md` |
| jq | JSON parsing and validation | the gh and review harness scripts, the skill manifest check, and the distribution command |
| gh CLI | GitHub API access (`gh api`, `gh auth status`) | the gh skill dispatcher; version 2.99.0 or later for attachments |
| pi | agent runtime (`pi remove`, `pi list`) | the Pi runtime and the Pi-only workflows; the distribution command never calls it |
| herdr | delegating prompts to other panes (`herdr agent prompt`) | the herdr skill scripts |
| python3 | the review skill's recheck harness (`review/scripts/recheck-state.sh`); optional for the herdr delegation scripts, which use it only for a cosmetic pane label and fall back gracefully without it | the review skill; optional for the herdr skill |
| playwright-cli | browser automation for the playwright skill through its `scripts/pw.sh` wrapper (installed separately, e.g. `npm install -g @playwright/cli`; `PW_BIN` can point at an equivalent binary such as `npx @playwright/cli`) | the playwright skill |
| GNU coreutils and text tools (`stat -c%s`, `sort -V`, `mktemp -p`, GNU `grep -P`, `sed`, `head`, `cat`, `sleep`, `unlink`, `ln`, ...) | shared plumbing across scripts; GNU tools must be available under the unprefixed command names within the harness process; the distribution command creates and removes the per-skill links with `ln -s` and `unlink`, and the Uninstall block below removes them with `unlink` | every scripted harness |

`curl` is not a dependency: no script in this repository invokes it. The gh dispatcher talks to the GitHub API through the gh CLI, and the only `curl` occurrence in harness code is a retry-classification pattern in `gh/scripts/common/http.sh` that matches gh CLI error text.

The shared development profile/model helpers require Node.js.
[explain-video](explain-video/SKILL.md#prerequisites) additionally requires
Node.js, FFmpeg/ffprobe, the Playwright/Chromium environment, and fonts covering
the caption language. FFmpeg remains optional for other workflows; it is not a
repository-wide prerequisite.

## Install

The skills are distributed from a pinned git tree by `scripts/skill-distribution/dist.sh`. No harness CLI is required, and the command refuses a revision that is not reachable from `origin/main`. On a new machine, clone this repository at a merged revision once and run the command from that clone:

```bash
scripts/skill-distribution/dist.sh update --sha <commit-sha> --pr <PR URL>
```

The command fetches the revision into the account's distribution root (`${AGENT_HARNESS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness}`), exports and verifies an immutable release, switches the `current` symlink atomically, links every skill in [skills.json](skills.json) into `~/.agents/skills`, and appends the rollout record. Repeat `--link-dir` for other harness skill directories. Without `--sha`, the command serves the current `origin/main`. Revision confirmation, rollout, rollback, and migration from the pi package install are documented in [_docs/skill-distribution.md](_docs/skill-distribution.md).

## Uninstall

Remove only the per-skill links this package created, then the legacy `agent-harness` leaf link if one remains; the release trees and the rollout record under the distribution root are kept.

```bash
# Remove only the links that point into this package's distribution root.
ROOT="${AGENT_HARNESS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/agent-harness}"
for dir in ~/.agents/skills ~/.claude/skills ~/.codex/skills; do
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      "$ROOT/current/"*) unlink "$link" ;;
    esac
  done
  if [ -L "$dir/agent-harness" ]; then
    unlink "$dir/agent-harness"
  fi
done
```

The `-L` guard limits removal to symlinks: a real skill directory is never unlinked. Keep `~/.agents/skills`, `~/.codex/skills`, and `~/.claude/skills` themselves and every other entry in them: these are the harnesses' standard per-user skill directories (conventions that read the same on every machine, not machine-specific paths), and the parent skill directories and parent symlinks may serve other skills and are not owned by this package. If a link position holds a real directory instead (for example a plain clone from before this layout), inspect it and remove it by hand. Extend the link list if you created links in other harness skill directories.

If a legacy pi package registration is still present, remove it in a separate step so the two links above stay independent of Pi: `pi remove git:github.com/u7chan/agent-harness`. Delete the distribution root by hand when its release trees and record are no longer needed.
