#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-review-payload.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
REVIEW_SKILL="$SCRIPT_DIR/../SKILL.md"
RECHECK_REFERENCE="$SCRIPT_DIR/../references/recheck.md"
POSTING_REFERENCE="$SCRIPT_DIR/../references/posting-api.md"
WORKFLOW_SKILL="$SCRIPT_DIR/../../pi-issue-pr-workflow/SKILL.md"
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
expect_doc_contains recheck-unique-target "$RECHECK_REFERENCE" '(thread_id, root_comment_id, reviewer_login, recheck_reply_id)'
expect_doc_contains recheck-keeps-nonresolved "$RECHECK_REFERENCE" '`Partial`、`Unresolved`、`Unknown`'
expect_doc_contains recheck-rejects-unknown "$RECHECK_REFERENCE" '`unknown_outcome`'
expect_doc_contains recheck-verifies-state "$RECHECK_REFERENCE" '`resolved=true`'
expect_doc_order recheck-order "$RECHECK_REFERENCE" '### 3. 検証済み LGTM' '### 4. 個別 Resolve と再取得'
expect_doc_contains skill-auto-resolve "$REVIEW_SKILL" '検証済み LGTM の後に自動 Resolve'
expect_doc_contains posting-order "$POSTING_REFERENCE" '再チェック返信、最新 head のフルレビュー、最終 LGTM、スレッドの Resolve はこの順序'
expect_doc_contains workflow-delegates-resolution "$WORKFLOW_SKILL" 'Conversation resolution is delegated to the Review skill.'
expect_doc_absent workflow-old-confirmation "$WORKFLOW_SKILL" 'requires user confirmation before resolving them'

echo "PASS: $pass_count review payload and recheck contract cases"
