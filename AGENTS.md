# AGENTS.md

## Rules

- Direct push to `main` or `epic` is prohibited. Always create a branch and open a PR.
- When working on an `epic` branch, open the PR targeting the `epic` branch. Otherwise, target `main`.
- Branch names must use lowercase kebab-case with a type prefix, such as `feat/add-action-filter`.
- Commit messages must use an English Conventional Commit prefix, such as `feat(gh): add action filter`.
- PR descriptions must be written in Japanese and include `Issues`, `Why`, `Summary`, `Changes`, and `Verification`.
- レビュー・改善系のスキルは日本語で、それ以外のスキルは英語で記述する。
- When addressing PR feedback, reply to the relevant comment.
- Keep `SKILL.md` minimal. Put deterministic validation and tool constraints in scripts or schemas.
- Do not duplicate definitions. Keep one authoritative source and derive or validate everything else from it.
- Do not build a custom runtime, state machine, or abstraction unless the Issue explicitly requires it.
- Prefer the smallest change that preserves the existing contracts.
