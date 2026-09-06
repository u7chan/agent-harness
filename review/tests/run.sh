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

# Policy existence check: every keyword must appear in the document. Unlike
# expect_doc_contains this does not pin a full sentence, so paraphrasing a
# general explanation keeps passing while the policy terms stay required.
expect_doc_keywords() {
  local name="$1"
  local file="$2"
  shift 2
  local keyword
  for keyword in "$@"; do
    if ! grep -Fq -- "$keyword" "$file"; then
      echo "FAIL: $name is missing keyword '$keyword' in $file" >&2
      exit 1
    fi
  done
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

# --- 公開形式・契約トークンの厳密検査(完全一致) ---
# ラベル、分類 header、tuple 形式、API トークン、節見出しは公開契約なので完全一致で固定する。
expect_doc_contains recheck-full-head "$RECHECK_REFERENCE" '## 最新 head のフルレビュー'
expect_doc_contains recheck-unique-target "$RECHECK_REFERENCE" '(thread_id, root_comment_id, reviewer_login, classification_reply_id)'
expect_doc_contains recheck-keeps-nonresolved "$RECHECK_REFERENCE" '`Partial`、`Unresolved`、`Unknown`'
expect_doc_contains recheck-rejects-unknown "$RECHECK_REFERENCE" '`unknown_outcome`'
expect_doc_contains recheck-verifies-state "$RECHECK_REFERENCE" '`resolved=true`'
expect_doc_contains recheck-helper-contract "$RECHECK_REFERENCE" 'recheck-state.py'
expect_doc_contains recheck-operation-dedup "$POSTING_REFERENCE" '同 body・同 actor・同 root'
expect_doc_contains recheck-verified-outcomes "$RECHECK_REFERENCE" 'already-applied'
expect_doc_order recheck-order "$RECHECK_REFERENCE" '### 3. 検証済み LGTM' '## 明示指示による Resolve'
expect_doc_contains workflow-resolve-section "$RECHECK_REFERENCE" '## Workflow コンテキストの自動 Resolve'
expect_doc_contains skill-auto-resolve "$REVIEW_SKILL" '明示指示'
expect_doc_absent workflow-optional-recheck "$WORKFLOW_SKILL" 'If the agent also rechecks prior findings'
expect_doc_absent workflow-old-confirmation "$WORKFLOW_SKILL" 'requires user confirmation before resolving them'

# --- 安全方針の存在確認(キーワード) ---
# 安全方針の概念トークンが存在することだけを要求する。一般説明文の完全な文言は固定しない。
expect_doc_keywords recheck-verifies-lgtm-head "$RECHECK_REFERENCE" 'head SHA' '再確認'
expect_doc_keywords recheck-reports-head-change "$RECHECK_REFERENCE" '取得失敗' '成功として扱わず'
expect_doc_keywords workflow-resolve-trigger "$RECHECK_REFERENCE" '自動 Resolve' 'workflow コンテキスト' '明示的に指定'
expect_doc_keywords workflow-resolve-outside-scope "$RECHECK_REFERENCE" 'workflow 外' '手動フロー'
expect_doc_keywords workflow-resolve-reply-tail "$RECHECK_REFERENCE" 'tail' '`Resolved` 分類'
expect_doc_keywords workflow-resolve-anchor-forms "$RECHECK_REFERENCE" 'plan' '`reuse` anchor'
expect_doc_keywords workflow-resolve-two-points "$RECHECK_REFERENCE" '対象 PR' '未解決'
expect_doc_keywords workflow-resolve-tail-owner "$RECHECK_REFERENCE" 'tail の返信' '`Resolved` 分類'
expect_doc_keywords workflow-resolve-execution "$RECHECK_REFERENCE" '`review-threads.resolve`' '再取得' '`resolved=true`'
expect_doc_keywords workflow-resolve-no-state-restore "$RECHECK_REFERENCE" '廃止した機構' '再導入'
expect_doc_keywords workflow-resolve-closing-reply "$RECHECK_REFERENCE" '閉会コメント' '`Resolved` 分類返信'
expect_doc_keywords skill-verifies-lgtm-head "$REVIEW_SKILL" 'LGTM' '検証' 'head'
expect_doc_keywords skill-start-materials "$REVIEW_SKILL" '変更目的' '受け入れ条件' '禁止される結果' '維持すべき既存契約'
expect_doc_order skill-materials-before-lens "$REVIEW_SKILL" '維持すべき既存契約' '関係する観点'
expect_doc_keywords skill-anti-inference "$REVIEW_SKILL" 'こうあるべき' '推測'
expect_doc_keywords skill-verification-path "$REVIEW_SKILL" '第三者' '再現'
expect_doc_keywords skill-counter-evidence-first "$REVIEW_SKILL" '反証'
expect_doc_keywords skill-stopping-condition "$REVIEW_SKILL" '手掛かり' '探索を終了'
expect_doc_keywords criteria-authority-order "$REVIEW_CRITERIA" '優先順位' '正本'
expect_doc_order criteria-explicit-before-repository "$REVIEW_CRITERIA" '明示された受け入れ条件' 'リポジトリ内の仕様'
expect_doc_order criteria-repository-before-code "$REVIEW_CRITERIA" 'リポジトリ内の仕様' '既存コードから確認できる不変条件'
expect_doc_keywords criteria-no-inference "$REVIEW_CRITERIA" 'Blocker / Finding' '根拠にしない'
expect_doc_keywords criteria-bounded-review "$REVIEW_CRITERIA" '既存契約' '検証可能な範囲'
expect_doc_keywords criteria-no-invented-requirement "$REVIEW_CRITERIA" '受け入れ条件' '補完'
expect_doc_keywords criteria-indeterminate "$REVIEW_CRITERIA" '確認不能'
expect_doc_keywords criteria-no-scope-expansion "$REVIEW_CRITERIA" 'レビュー範囲' '無制限'
expect_doc_keywords criteria-verification-path "$REVIEW_CRITERIA" '再現' '検証経路'
expect_doc_keywords criteria-verification-inputs "$REVIEW_CRITERIA" '入力・状態'
expect_doc_keywords criteria-verification-test "$REVIEW_CRITERIA" 'テストケース'
expect_doc_keywords criteria-verification-code-path "$REVIEW_CRITERIA" 'コードパス'
expect_doc_keywords criteria-verification-contract "$REVIEW_CRITERIA" '不一致'
expect_doc_keywords criteria-verification-operations "$REVIEW_CRITERIA" 'コマンド'
expect_doc_keywords criteria-no-universal-runtime "$REVIEW_CRITERIA" 'runtime reproduction' 'failing test' '必須ではない'
expect_doc_keywords criteria-static-verification "$REVIEW_CRITERIA" '静的な経路'
expect_doc_keywords skill-preserves-scope-flow "$REVIEW_SKILL" 'Scope Gate' 'Rejected'
expect_doc_keywords criteria-scope-evidence-boundary "$REVIEW_CRITERIA" '失敗経路' '因果関係'
expect_doc_keywords criteria-counter-evidence "$REVIEW_CRITERIA" '反証できなかった' 'Evidence とみなしてはならない'
expect_doc_keywords criteria-preserves-rejected "$REVIEW_CRITERIA" 'Rejected' '正常なレビュー結果'
expect_doc_keywords criteria-preserves-zero-findings "$REVIEW_CRITERIA" '`0 findings`' 'LGTM'
expect_doc_keywords lens-not-checklist "$REVIEW_LENSES" 'チェックリスト' 'finding'
expect_doc_keywords lens-no-finding-per-lens "$REVIEW_LENSES" '一件ずつ' 'lens'
expect_doc_keywords skill-no-approve "$REVIEW_SKILL" 'マージ' 'クローズ' '`APPROVE`'
expect_doc_keywords workflow-requires-recheck "$WORKFLOW_SKILL" 'recheck all prior unresolved findings' 'full review'
expect_doc_keywords posting-order "$POSTING_REFERENCE" '再チェック返信' 'フルレビュー' 'LGTM' '順序'
expect_doc_keywords posting-verifies-lgtm-head "$POSTING_REFERENCE" '明示指示'
expect_doc_keywords workflow-resolve-explicit-manual "$WORKFLOW_SKILL" 'explicit instruction only'
expect_doc_keywords workflow-resolve-scoped-auto "$WORKFLOW_SKILL" 'auto-resolve' 'Resolved'
expect_doc_keywords workflow-resolve-reply-first "$WORKFLOW_SKILL" 'confirmation' 'resolve'

# --- 正本参照構造 ---
# Resolve 規則の全文は recheck.md にのみあり、他の文書は参照する。
expect_doc_keywords policy-canonical-reference "$RECHECK_REFERENCE" '正本'
expect_doc_keywords policy-skill-reference "$REVIEW_SKILL" 'recheck.md'
expect_doc_keywords policy-posting-reference "$POSTING_REFERENCE" 'recheck.md'
expect_doc_keywords policy-workflow-reference "$WORKFLOW_SKILL" 'references/recheck.md'

echo "PASS: $pass_count review payload and recheck contract cases"
