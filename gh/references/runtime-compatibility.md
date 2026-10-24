# Runtime compatibility

## Policy and scope

Keep the existing Linux/WSL Bash and GNU-tool workflow. The dispatcher does not select an OS-specific Bash, package manager, or tool directory, and does not change PATH. Native Windows shells (PowerShell/cmd) are not supported; Windows usage still requires a Linux-compatible Bash environment such as WSL.

For the shared gh attachment path, support macOS system Bash 3.2 with the required GNU tools rather than require a newer Bash solely for empty arrays. Bash 3.2 treats an empty array expansion as unset under `set -u`; attachment duplicate checks and verification use a guarded expansion that preserves individual paths and produces zero arguments for an empty array. `set -u` remains enabled. Requiring a newer Bash would also avoid this particular failure, but adds an unnecessary runtime prerequisite and would exclude otherwise usable Bash environments. Bash 5 is not a new requirement.

This is a bounded compatibility change, not a claim that all scripts work with macOS's BSD tools or Bash 3.2. In particular, the developer-only `gh/scripts/check-actions.sh` uses `mapfile` and needs Bash 4 or newer. Other harnesses retain their existing prerequisites and verification scope.

## Prerequisites

The repository-wide command list remains in the [README](../../README.md#prerequisites). For gh attachments, ensure:

- GNU Bash; the macOS system Bash 3.2 attachment path is explicitly tested. Scripts use `#!/usr/bin/env bash`, and the dispatcher runs its action scripts with its own `$BASH`.
- `jq`, authenticated `gh` >= 2.99.0, the `github.com` host, and repository write permission. The request still needs an explicit write grant.
- GNU coreutils available under their **unprefixed** names on the harness process PATH: notably `stat -c%s`, `sort -V`, and `mktemp -p`. Installing only commands named `gstat` or `gsort` is not enough.
- GNU grep with `-P` for the shared authentication/host check, plus the other text tools listed in the README. A fixture that mocks authentication does not test this real prerequisite.

On macOS, install dependencies through the workstation's own configuration. If it provides a harness-specific launcher, use that launcher. Do not modify the installed skill package, switch the user's login shell, disable `set -u`, or prepend GNU tools to the global PATH.

For a development-only test process, this Homebrew example supplies GNU coreutils without changing the surrounding shell (dependencies must already be installed):

```bash
env PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH" \
  /bin/bash <checkout>/gh/tests/contract/attach.sh
```

`<checkout>` follows the [distribution notation](../../_docs/skill-distribution.md#notation). The test's mock authentication needs no GNU grep; a real dispatcher invocation does. MacPorts or another provider can supply the same interfaces in a process-local tool directory; no provider-specific path is embedded in the harness. Development tests run separately from the installed harness's launcher, following the [unmerged skill verification procedure](../../_docs/skill-testing.md).

## Failure behavior and unchanged contracts

Before attachment validation or an upload, the shared attachment gate checks version sorting and byte-size lookup. An unavailable or incompatible `sort -V` or `stat -c%s` yields a `failed` common JSON envelope with `error.code: "MISSING_DEPENDENCY"`, naming the required interface. A failed or malformed per-attachment size lookup yields `ATTACH_INVALID`, not a skipped size limit. A size lookup failure during read-back verification yields `unknown_outcome`, because the write may already have succeeded; it must not trigger an automatic resend.

The preflight is local to non-empty attachment requests; attachment-free operations keep their existing route. It does not replace authentication or the other runtime prerequisites. Permission and host checks, gh version/count limits, file/alt/size/duplicate validation, single-fire writes, and post-write identity/body verification keep their existing contracts. All five attachment actions share the same implementation: `issue.create`, `issue.update`, `pr.create`, `pr.update`, and `comments.create`.

## Verification boundaries

| Environment | Evidence and limits |
| --- | --- |
| Linux | The existing Ubuntu CI runs the complete gh contracts and the repository's other checks, without macOS-specific PATH changes. |
| WSL | Uses the unchanged Linux-compatible Bash/GNU-tool contract. No WSL real-machine run was performed for this change; Ubuntu CI is not a substitute for one. |
| macOS mock tests | A dedicated CI job uses `/bin/bash` and process-local GNU coreutils. The fixture explicitly keeps the dispatcher's interpreter equal to the test's `$BASH`, even if PATH contains another Bash. It uses no credentials, network, or real uploads. |
| macOS local regression | macOS 13.7.8 / x86_64, Bash 3.2.57, GNU coreutils 9.11: the original attachment suite reproduced 12 failures out of 23; the changed suite passes all 33 cases. Cases cover zero/one/multiple attachments, spaces and glob characters, duplicate paths with differing alt text, malformed inputs and tool output, all five write actions, URL rewriting/appending, and failed read-back without resending. |
| macOS real upload of this fix | [PR #277 evidence](https://github.com/u7chan/agent-harness/pull/277#issuecomment-6378454079): macOS 13.7.8 / x86_64, Bash 3.2.57, GNU coreutils 9.11, GNU grep 3.12, gh 2.103.0. A single valid PNG passed the shared attachment path through `comments.create` at commit `9195485cac510b1fe4c8fae701a3e99a6474e44f`; the write returned `status: "ok"`. An independent `comments.read` through the unchanged installed harness confirmed the image path was absent and a `https://github.com/user-attachments/assets/` URL was stored. Other attachment actions have mock coverage, not individual live-upload coverage in this run. |
| Earlier real upload | [Issue #276](https://github.com/u7chan/agent-harness/issues/276) records an actual upload with the prior installed revision on macOS using Bash 5.3.15 and gh 2.103.0. This is evidence for that environment only, not a real-upload test of this Bash 3.2 fix. |

The real-upload test read the development files directly: `<checkout>/gh/SKILL.md`, `<checkout>/gh/actions.json`, `<checkout>/gh/scripts/gh.sh`, `<checkout>/gh/scripts/actions/comments.create.sh`, and `<checkout>/gh/scripts/common/attach.sh`. Its new-code marker was `for prev in ${ATTACH_PATHS[@]+"${ATTACH_PATHS[@]}"}; do`. The checkout HEAD remained the recorded commit throughout the test, and the installed clone stayed pinned to `75cd0c53d18c8523eb0ae139ea64d7782e8cbca3`; no rollout or in-place package edit was performed. The generated test image remains only in the PR evidence, not in the repository.

Mock success alone does not establish real macOS upload support. For each new runtime configuration, retain real-machine evidence showing the tested checkout/revision, Bash/tool/gh versions, the write's common envelope, and an independent read-back with the local image path replaced by a GitHub attachment URL. Keep test assets outside the repository, agree where the uploaded evidence will remain, and follow the [unmerged skill verification procedure](../../_docs/skill-testing.md) without changing the operational installed revision. A required real upload that cannot be performed must be reported as outstanding, not counted as passed. After merge, use the normal [rollout gate and smoke test](../../_docs/skill-distribution.md#merge--rollout).
