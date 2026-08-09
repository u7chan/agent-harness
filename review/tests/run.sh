#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/validate-review-payload.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
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

echo "PASS: $pass_count review payload validation cases"
