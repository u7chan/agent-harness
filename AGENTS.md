# AGENTS.md

## Rules

- Direct push to `main` or `epic` is prohibited. Always create a branch and open a PR.
- When working on an `epic` branch, open the PR targeting the `epic` branch. Otherwise, target `main`.
- Branch names must use lowercase kebab-case with a type prefix, such as `feat/add-action-filter`.
- Commit messages must use an English Conventional Commit prefix, such as `feat(gh): add action filter`.
- PR descriptions must be written in Japanese and include `Issues`, `Why`, `Summary`, `Changes`, `Verification`, and `Rollout`. `Rollout` states whether the post-merge rollout procedure in [_docs/skill-distribution.md](_docs/skill-distribution.md) applies: `Rollout: 必要` when the PR changes any skill, otherwise `Rollout: 不要`.
- Write review and improvement skills in Japanese, and all other skills in English.
- When addressing PR feedback, reply to the relevant comment.
- Do not commit machine-specific paths (e.g. `/home/<user>/…`, `~/.pi/agent/git/…`); use placeholders like `<checkout>` in docs instead.
- Follow [_docs/architecture.md](_docs/architecture.md) for repository structure, responsibility boundaries, and design constraints.
- Skill installation, rollout, and rollback follow [_docs/skill-distribution.md](_docs/skill-distribution.md).
