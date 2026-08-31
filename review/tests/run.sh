#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-review-payload.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
REVIEW_SKILL="$SCRIPT_DIR/../SKILL.md"
REVIEW_CRITERIA="$SCRIPT_DIR/../references/review-criteria.md"
REVIEW_LENSES="$SCRIPT_DIR/../references/review-lenses.md"
RECHECK_REFERENCE="$SCRIPT_DIR/../references/recheck.md"
POSTING_REFERENCE="$SCRIPT_DIR/../references/posting-api.md"
WORKFLOW_SKILL="$SCRIPT_DIR/../../pi-issue-pr-workflow/SKILL.md"
RECHECK_STATE_TEST="$SCRIPT_DIR/recheck-state-tests.sh"
TEST_TMP="$(mktemp -d /tmp/review-validator-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass_count=0

expect_valid() {
  local action="$1"
  local fixture="$2"

  "$VALIDATOR" "$action" "$fixture" >/dev/null
  pass_count=$((pass_count + 1))
}

expect_invalid() {
  local name="$1"
  local action="$2"
  local filter="$3"
  local source="$4"
  local candidate="$TEST_TMP/$name.json"

  jq "$filter" "$source" > "$candidate"
  if "$VALIDATOR" "$action" "$candidate" >/dev/null 2>&1; then
    echo "FAIL: $name was accepted" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_doc_contains() {
  local name="$1"
  local file="$2"
  local text="$3"

  if ! grep -Fq -- "$text" "$file"; then
    echo "FAIL: $name is missing from $file" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_doc_absent() {
  local name="$1"
  local file="$2"
  local text="$3"

  if grep -Fq -- "$text" "$file"; then
    echo "FAIL: $name is still present in $file" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_doc_order() {
  local name="$1"
  local file="$2"
  local first="$3"
  local second="$4"
  local first_line second_line

  first_line="$(awk -v needle="$first" 'index($0, needle) { print NR; exit }' "$file")"
  second_line="$(awk -v needle="$second" 'index($0, needle) { print NR; exit }' "$file")"
  if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
    echo "FAIL: $name has the wrong order in $file" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

expect_valid reviews.create "$FIXTURES/no-findings.json"
expect_valid reviews.create "$FIXTURES/nit-only.json"
expect_valid reviews.create "$FIXTURES/blocker.json"
expect_valid review-comments.reply "$FIXTURES/recheck-resolved.json"
expect_valid review-comments.reply "$FIXTURES/recheck-unresolved.json"
jq '.body = "**Partial** (**Blocker**): 一部の入力経路に失敗条件が残っています。"' \
  "$FIXTURES/recheck-unresolved.json" > "$TEST_TMP/recheck-partial.json"
expect_valid review-comments.reply "$TEST_TMP/recheck-partial.json"
jq '.body = "**Unknown**: 実行時条件を確認できないため判定できません。"' \
  "$FIXTURES/recheck-resolved.json" > "$TEST_TMP/recheck-unknown.json"
expect_valid review-comments.reply "$TEST_TMP/recheck-unknown.json"

if ! "$RECHECK_STATE_TEST" >/dev/null; then
  echo "FAIL: recheck state helper executable tests" >&2
  exit 1
fi
pass_count=$((pass_count + 1))

expect_invalid label-supplement reviews.create \
  '.comments[0].body = ("**Nit (" + "Optional)**: 表記が揺れています。")' \
  "$FIXTURES/nit-only.json"
expect_invalid required-label-supplement reviews.create \
  '.comments[0].body = ("**Blocker (" + "Required)**: 失敗条件が残っています。")' \
  "$FIXTURES/blocker.json"
expect_invalid japanese-optional-supplement reviews.create \
  '.comments[0].body = ("**Consider（" + "任意）**: 別案を検討できます。")' \
  "$FIXTURES/nit-only.json"
expect_invalid japanese-required-supplement reviews.create \
  '.comments[0].body = ("**Blocker（" + "必須）**: 失敗条件が残っています。")' \
  "$FIXTURES/blocker.json"
expect_invalid lgtm-blocker-conflict reviews.create \
  '.comments[0].body = "**Blocker**: 失敗条件が残っています。"' \
  "$FIXTURES/nit-only.json"
expect_invalid lgtm-overall-blocker-conflict reviews.create \
  '.body += "\n\n**Blocker**: 失敗条件が残っています。" | del(.comments)' \
  "$FIXTURES/nit-only.json"
expect_invalid unresolved-variable reviews.create \
  '.body += "\n\n{件数}"' \
  "$FIXTURES/no-findings.json"
expect_invalid unresolved-scope-variable reviews.create \
  '.body += "\n\n{確認範囲の要約}"' \
  "$FIXTURES/no-findings.json"
expect_invalid unresolved-legacy-scope-variable reviews.create \
  '.body += "\n\n{意味で要約した確認範囲}"' \
  "$FIXTURES/no-findings.json"
expect_invalid literal-backslash-n reviews.create \
  '.body += "\\\\n壊れた改行"' \
  "$FIXTURES/no-findings.json"
expect_invalid non-comment-event reviews.create \
  '.event = "PENDING"' \
  "$FIXTURES/no-findings.json"
expect_invalid missing-commit-id reviews.create \
  'del(.commit_id)' \
  "$FIXTURES/no-findings.json"
expect_invalid short-commit-id reviews.create \
  '.commit_id = "0123456"' \
  "$FIXTURES/no-findings.json"
expect_invalid raw-action-name reviews.create \
  '.body += "\n\npr.read を実行しました。"' \
  "$FIXTURES/no-findings.json"
expect_invalid zero-severity reviews.create \
  '.body += "\n\nNit: 0件"' \
  "$FIXTURES/no-findings.json"
expect_invalid invalid-recheck-label review-comments.reply \
  '.body = ("**Unresolved** (**Blocker (" + "Required)**): 失敗条件が残っています。")' \
  "$FIXTURES/recheck-unresolved.json"

expect_doc_contains recheck-full-head "$RECHECK_REFERENCE" '## 最新 head のフルレビュー'
expect_doc_contains recheck-unique-target "$RECHECK_REFERENCE" '(thread_id, root_comment_id, reviewer_login, classification_reply_id)'
expect_doc_contains recheck-keeps-nonresolved "$RECHECK_REFERENCE" '`Partial`、`Unresolved`、`Unknown`'
expect_doc_contains recheck-rejects-unknown "$RECHECK_REFERENCE" '`unknown_outcome`'
expect_doc_contains recheck-verifies-state "$RECHECK_REFERENCE" '`resolved=true`'
expect_doc_contains recheck-verifies-lgtm-head "$RECHECK_REFERENCE" 'head SHA を再確認'
expect_doc_contains recheck-reports-head-change "$RECHECK_REFERENCE" '取得失敗、状態不一致は成功として扱わず'
expect_doc_contains recheck-helper-contract "$RECHECK_REFERENCE" 'recheck-state.py'
expect_doc_contains recheck-operation-dedup "$POSTING_REFERENCE" '同 body・同 actor・同 root'
expect_doc_contains recheck-verified-outcomes "$RECHECK_REFERENCE" 'already-applied'
expect_doc_order recheck-order "$RECHECK_REFERENCE" '### 3. 検証済み LGTM' '## 明示指示による Resolve'
expect_doc_contains skill-auto-resolve "$REVIEW_SKILL" '明示指示'
expect_doc_contains skill-verifies-lgtm-head "$REVIEW_SKILL" 'LGTM の投稿と本文・head の検証が成功して初めて'
expect_doc_contains skill-start-materials "$REVIEW_SKILL" '利用可能な変更目的、受け入れ条件、禁止される結果、維持すべき既存契約、変更の伝播先、実行済みテストと結果、人間の判断が必要な未決事項'
expect_doc_order skill-materials-before-lens "$REVIEW_SKILL" '人間の判断が必要な未決事項' '関係する観点だけを選ぶ'
expect_doc_contains skill-anti-inference "$REVIEW_SKILL" '明示されていない「こうあるべき」を推測で補わず'
expect_doc_contains skill-verification-path "$REVIEW_SKILL" '第三者が確認できる再現または検証経路'
expect_doc_contains skill-counter-evidence-first "$REVIEW_SKILL" '反証を先に探し'
expect_doc_contains skill-stopping-condition "$REVIEW_SKILL" '未解決 Concern に追加調査できる具体的な手掛かりがなければ探索を終了'
expect_doc_contains criteria-authority-order "$REVIEW_CRITERIA" '次の優先順位で正本として扱う'
expect_doc_order criteria-explicit-before-repository "$REVIEW_CRITERIA" 'Issue / PR に明示された受け入れ条件・禁止される結果' 'リポジトリ内の仕様、公開契約、型、設定、テスト'
expect_doc_order criteria-repository-before-code "$REVIEW_CRITERIA" 'リポジトリ内の仕様、公開契約、型、設定、テスト' '既存コードから確認できる不変条件・互換性'
expect_doc_contains criteria-no-inference "$REVIEW_CRITERIA" '単独では Blocker / Finding の根拠にしない'
expect_doc_contains criteria-bounded-review "$REVIEW_CRITERIA" '既存契約から検証可能な範囲はレビューしてよい'
expect_doc_contains criteria-no-invented-requirement "$REVIEW_CRITERIA" '新しい受け入れ条件として補完し'
expect_doc_contains criteria-indeterminate "$REVIEW_CRITERIA" '確認不能として報告する'
expect_doc_contains criteria-no-scope-expansion "$REVIEW_CRITERIA" 'レビュー範囲を無制限に広げない'
expect_doc_contains criteria-verification-path "$REVIEW_CRITERIA" '第三者が確認できる再現または検証経路'
expect_doc_contains criteria-verification-inputs "$REVIEW_CRITERIA" '具体的な入力・状態・権限・実行順序'
expect_doc_contains criteria-verification-test "$REVIEW_CRITERIA" '失敗する既存または追加可能なテストケース'
expect_doc_contains criteria-verification-code-path "$REVIEW_CRITERIA" '呼び出し経路とガード条件を追えるコードパス'
expect_doc_contains criteria-verification-contract "$REVIEW_CRITERIA" '仕様 / 型 / 設定との決定的な不一致'
expect_doc_contains criteria-verification-operations "$REVIEW_CRITERIA" '再現可能なコマンドや操作手順'
expect_doc_contains criteria-no-universal-runtime "$REVIEW_CRITERIA" 'runtime reproduction や failing test は全 Finding に一律必須ではない'
expect_doc_contains criteria-static-verification "$REVIEW_CRITERIA" 'コードと契約を追える静的な経路で検証できればよい'
expect_doc_contains skill-preserves-scope-flow "$REVIEW_SKILL" 'Scope Gate を適用する。通過しない候補は Rejected'
expect_doc_contains criteria-scope-evidence-boundary "$REVIEW_CRITERIA" '発生条件、失敗経路、因果関係の立証までは要求しない'
expect_doc_contains criteria-counter-evidence "$REVIEW_CRITERIA" '反証できなかった'
expect_doc_contains criteria-preserves-rejected "$REVIEW_CRITERIA" 'Rejected は正常なレビュー結果'
expect_doc_contains criteria-preserves-zero-findings "$REVIEW_CRITERIA" '`0 findings` / LGTM を正常終了'
expect_doc_contains lens-not-checklist "$REVIEW_LENSES" 'review lens は finding を作るためのチェックリストではなく'
expect_doc_contains lens-no-finding-per-lens "$REVIEW_LENSES" '各 lens から一件ずつ指摘を作ろうとしてはならない'
expect_doc_contains skill-no-approve "$REVIEW_SKILL" 'マージ、Issue のクローズ、`APPROVE` レビューは行わない'
expect_doc_contains workflow-requires-recheck "$WORKFLOW_SKILL" 'explicitly to recheck all prior unresolved findings and, in that same task, perform a full review of the latest head'
expect_doc_absent workflow-optional-recheck "$WORKFLOW_SKILL" 'If the agent also rechecks prior findings'
expect_doc_contains posting-order "$POSTING_REFERENCE" '再チェック返信、最新 head のフルレビュー、最終 LGTM はこの順序'
expect_doc_contains posting-verifies-lgtm-head "$POSTING_REFERENCE" '明示指示があった thread だけを対象に'
expect_doc_contains workflow-delegates-resolution "$WORKFLOW_SKILL" 'Conversation resolution is explicit instruction only.'
expect_doc_absent workflow-old-confirmation "$WORKFLOW_SKILL" 'requires user confirmation before resolving them'

echo "PASS: $pass_count review payload and recheck contract cases"
