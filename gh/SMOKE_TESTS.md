# GH Smoke Tests

## Prerequisites

```bash
command -v jq >/dev/null && command -v gh >/dev/null
```

## Disposable Test Setup

以下の手順で使い捨てのテスト用Issue/PRを作成し、テスト実行後に削除することを推奨する。

```bash
TEST_OWNER="anomalyco"
TEST_REPO="sandbox"
TEST_BRANCH="smoke-test-$(date +%s)"

# テスト用ブランチを作成
cd "$HOME/path/to/repo"
CURRENT_BRANCH=$(git branch --show-current)
git checkout -b "$TEST_BRANCH"
echo "// smoke $(date +%s)" > smoke-test.js
git add smoke-test.js && git commit -m "smoke test setup"
git push -u origin "$TEST_BRANCH"

# テスト用PRを作成
TEST_PR_RESULT=$(jq -n --arg head "$TEST_BRANCH" \
  '{"title":"smoke-test-pr","base":"main","head":$head,"grant":"write"}' \
  | bash gh/scripts/gh.sh pr.create)
echo "$TEST_PR_RESULT" | jq -e '.status == "ok"'
TEST_PR_NUMBER=$(echo "$TEST_PR_RESULT" | jq -r '.data.number')

# 動的にcommit SHAを取得
TEST_COMMIT_SHA=$(echo "{\"number\":$TEST_PR_NUMBER}" \
  | bash gh/scripts/gh.sh pr.commits.read \
  | jq -e '.status == "ok"' \
  | jq -r '.data[0].sha')

# 動的にreview comment IDを取得（既存のreview commentがなければ作成）
TEST_COMMENT_ID=$(echo "{\"number\":$TEST_PR_NUMBER}" \
  | bash gh/scripts/gh.sh review-comments.read \
  | jq -r '.data.items[0].id // empty')

# 動的にthread node IDを取得
THREAD_IDS=$(echo "{\"number\":$TEST_PR_NUMBER}" \
  | bash gh/scripts/gh.sh review-threads.read \
  | jq -r '.data.threads[0].thread_id // empty')

# テスト用Issueを作成
TEST_ISSUE_RESULT=$(echo '{"title":"smoke-test-issue","grant":"write"}' \
  | bash gh/scripts/gh.sh issue.create \
  | jq -e '.status == "ok"')
TEST_ISSUE_NUMBER=$(echo "$TEST_ISSUE_RESULT" | jq -r '.data.number')

echo "TEST_PR_NUMBER=$TEST_PR_NUMBER"
echo "TEST_COMMIT_SHA=$TEST_COMMIT_SHA"
echo "TEST_ISSUE_NUMBER=$TEST_ISSUE_NUMBER"
echo "TEST_COMMENT_ID=$TEST_COMMENT_ID"
echo "THREAD_IDS=$THREAD_IDS"
```

```bash
# テスト終了後はブランチを削除し、元のブランチに戻す
git checkout "$CURRENT_BRANCH"
git push origin --delete "$TEST_BRANCH" 2>/dev/null || true
# PR自体はAPI経由でclose（deleteはgh pr closeで）
echo "{\"number\":$TEST_PR_NUMBER, \"grant\": \"sensitive-write\"}" \
  | bash gh/scripts/gh.sh pr.close | jq -e '.status == "ok"'
```

## Catalog Actions

### actions.list

```bash
# Test: list all actions
bash gh/scripts/gh.sh actions.list | jq -e '.status == "ok" and (.data | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns action array | `.data \| type == "array"` |
| Contains `actions.list` | `.data[] \| select(.name == "actions.list") \| . != null` |
| Contains `actions.describe` | `.data[] \| select(.name == "actions.describe") \| . != null` |
| Permission is `read` for catalog | `.data[] \| select(.category == "catalog") \| .permission == "read"` |

### actions.describe

```bash
# Test: describe actions.list
echo '{"action":"actions.list"}' | bash gh/scripts/gh.sh actions.describe | jq -e '.status == "ok" and .data.name != null'

# Test: describe actions.describe
echo '{"action":"actions.describe"}' | bash gh/scripts/gh.sh actions.describe | jq -e '.status == "ok" and .data.input_schema != null'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` for valid action | `.status == "ok"` |
| Returns full action definition | `.data.name != null and .data.input_schema != null` |

## Validation

### Unknown action

```bash
# Test: unknown action should fail
bash gh/scripts/gh.sh unknown.action 2>&1 | jq -e '.status == "failed" and .error.code == "UNKNOWN_ACTION" and .error.retryable == false'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `UNKNOWN_ACTION` | `.error.code == "UNKNOWN_ACTION"` |
| retryable is false | `.error.retryable == false` |

### Unknown field

```bash
# Test: unknown field in input should fail
echo '{"unknown_field":"value"}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq -e '.status == "failed" and .error.code == "UNKNOWN_FIELDS"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `UNKNOWN_FIELDS` | `.error.code == "UNKNOWN_FIELDS"` |

### Missing required field

```bash
# Test: missing required field should fail
echo '{}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq -e '.status == "failed" and .error.code == "MISSING_INPUT"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `MISSING_INPUT` | `.error.code == "MISSING_INPUT"` |

### Type mismatch

```bash
# Test: wrong type should fail
echo '{"action":123}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq -e '.status == "failed" and .error.code == "TYPE_MISMATCH"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `TYPE_MISMATCH` | `.error.code == "TYPE_MISMATCH"` |

### Invalid JSON

```bash
# Test: invalid JSON should fail
echo 'not json' | bash gh/scripts/gh.sh actions.list 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_JSON"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `INVALID_JSON` | `.error.code == "INVALID_JSON"` |

## Envelope Structure

```bash
# Test: envelope has required fields
bash gh/scripts/gh.sh actions.list | jq -e '.schema_version == 1 and .status != null and .action == "actions.list" and .actor == "user" and .target != null and .data != null'
```

| Check | Pass Condition |
|-------|---------------|
| Has `schema_version: 1` | `.schema_version == 1` |
| Has `status` | `.status != null` |
| Has `action` | `.action == "actions.list"` |
| Has `actor: "user"` | `.actor == "user"` |
| Has `target` | `.target != null` |
| Has `data` | `.data != null` |

## File Lifecycle

```bash
# Test: temp file creation and cleanup
TEMP_DIR=$(pwd)/.gh-tmp-smoke
GH_TEMP_DIR=$TEMP_DIR bash gh/scripts/gh.sh actions.list >/dev/null
ls "$TEMP_DIR" 2>/dev/null || echo "no temp dir"
rm -rf "$TEMP_DIR"
```

| Check | Pass Condition |
|-------|---------------|
| Temp directory is manageable | Temp dir exists or is cleaned up |

## Repository Actions

### repo.get

```bash
# Test: get current repository metadata
bash gh/scripts/gh.sh repo.get | jq -e '.status == "ok" and .data.full_name != null and .data.id != null and .data.default_branch != null'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns repository data | `.data.full_name != null` |
| Has expected fields | `.data.id and .data.name and .data.html_url and .data.default_branch` |

## Issue Actions

### issue.get

```bash
# Test: get a single issue
echo '{"number":10}' | bash gh/scripts/gh.sh issue.get | jq -e '.status == "ok" and .data.number == 10 and .data.title != null'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns issue data | `.data.number == 10` |
| Has expected fields | `.data.title and .data.state and .data.html_url` |
| Target has issue type | `.target.type == "issue"` |

### issue.list

```bash
# Test: list open issues
echo '{"state":"open"}' | bash gh/scripts/gh.sh issue.list | jq -e '.status == "ok" and (.data | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns issue array | `.data \| type == "array"` |
| Issues have no body | `.data[0].body == null` |
| Issues have number | `.data[0].number != null` |

## Validation

### Missing required input (issue.get without number)

```bash
# Test: missing required field should fail
echo '{}' | bash gh/scripts/gh.sh issue.get 2>&1 | jq -e '.status == "failed" and .error.code == "MISSING_INPUT"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `MISSING_INPUT` | `.error.code == "MISSING_INPUT"` |

## Write Actions

### issue.create

```bash
# Test: create issue
echo '{"title": "smoke-test-create", "grant": "write"}' | bash gh/scripts/gh.sh issue.create | jq -e '.status == "ok" and .data.number != null'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| issue created | `.data.number != null` |

### issue.update

```bash
# Test: update issue title
echo '{"number":1, "title": "smoke-test-update", "grant": "write"}' | bash gh/scripts/gh.sh issue.update | jq -e '.status == "ok" and .data.title == "smoke-test-update"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| title updated | `.data.title == "smoke-test-update"` |

### issue.close

```bash
# Test: close issue
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.close | jq -e '.status == "ok" and .data.state == "closed"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state closed | `.data.state == "closed"` |

### issue.reopen

```bash
# Test: reopen issue
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.reopen | jq -e '.status == "ok" and .data.state == "open"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state open | `.data.state == "open"` |

### labels.add

```bash
# Test: add labels
echo '{"number":1, "labels":["bug","enhancement"], "grant": "write"}' | bash gh/scripts/gh.sh labels.add | jq -e '.status == "ok" and (.data.labels | length > 0)'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| has labels | `.data.labels \| length > 0` |

### labels.remove

```bash
# Test: remove label
echo '{"number":1, "name":"bug", "grant": "sensitive-write"}' | bash gh/scripts/gh.sh labels.remove | jq -e '.status == "ok"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| label removed | `.data.labels \| any(. == "bug") \| not` |

### labels.set

```bash
# Test: set labels
echo '{"number":1, "labels":["documentation"], "grant": "sensitive-write"}' | bash gh/scripts/gh.sh labels.set | jq -e '.status == "ok" and .data.labels == ["documentation"]'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| labels replaced | `.data.labels == ["documentation"]` |

### assignees.add

```bash
# Test: add assignees
echo '{"number":1, "assignees":["octocat"], "grant": "write"}' | bash gh/scripts/gh.sh assignees.add | jq -e '.status == "ok" and (.data.assignees | length > 0)'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| has assignees | `.data.assignees \| length > 0` |

### assignees.remove

```bash
# Test: remove assignees
echo '{"number":1, "assignees":["octocat"], "grant": "sensitive-write"}' | bash gh/scripts/gh.sh assignees.remove | jq -e '.status == "ok"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| assignee removed | `.data.assignees \| any(. == "octocat") \| not` |

### milestone.set

```bash
# Test: set milestone
echo '{"number":1, "milestone":1, "grant": "write"}' | bash gh/scripts/gh.sh milestone.set | jq -e '.status == "ok" and .data.milestone != null'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| milestone set | `.data.milestone != null` |

### milestone.clear

```bash
# Test: clear milestone
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh milestone.clear | jq -e '.status == "ok"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| milestone cleared | `.data.milestone.title == null` |

### issue.subissues.add

```bash
# Test: add sub-issue
echo '{"number":1, "sub_issue_id":123, "grant": "write"}' | bash gh/scripts/gh.sh issue.subissues.add | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |

### issue.subissues.remove

```bash
# Test: remove sub-issue
echo '{"number":1, "sub_issue_id":123, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.subissues.remove | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |

### issue.subissues.reorder

```bash
# Test: reorder sub-issue
echo '{"number":1, "sub_issue_id":123, "after_id":456, "grant": "write"}' | bash gh/scripts/gh.sh issue.subissues.reorder | jq -e '.status == "ok"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |

### Already Applied (Idempotency)

```bash
# Test: close already closed issue returns already_applied
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.close | jq -e '.status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status already_applied | `.status == "already_applied"` |

### Grant Rejection

```bash
# Test: insufficient grant should fail
echo '{"title": "fail", "grant": "read"}' | bash gh/scripts/gh.sh issue.create 2>&1 | jq -e '.status == "failed" and .error.code == "GRANT_INSUFFICIENT"'
```

| Check | Filter |
|-------|--------|
| status failed | `.status == "failed"` |
| error code GRANT_INSUFFICIENT | `.error.code == "GRANT_INSUFFICIENT"` |

## PR Actions

### prs.list

```bash
# Test: list open PRs
bash gh/scripts/gh.sh prs.list | jq -e '.status == "ok" and (.data | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns PR array | `.data \| type == "array"` |
| PRs have number | `.data[0].number != null` |
| PRs have no body | `.data[0].body == null` |
| PRs have head branch | `.data[0].head.ref != null` |

### prs.search

```bash
# Test: search PRs in repository
echo '{"q":"is:open"}' | bash gh/scripts/gh.sh prs.search | jq -e '.status == "ok" and (.data.items | type == "array") and .data.total_count >= 0'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns items array | `.data.items \| type == "array"` |
| Has truncated flag | `.data.truncated == false` or `.data.truncated == true` |
| Has total_count | `.data.total_count >= 0` |

### pr.read

```bash
# Test: get a single PR by number
echo '{"number":12}' | bash gh/scripts/gh.sh pr.read | jq -e '.status == "ok" and .data.number == 12 and .data.title != null'

# Test: get PR from URL
echo '{"reference":"https://github.com/u7chan/agent-harness/pull/12"}' | bash gh/scripts/gh.sh pr.read | jq -e '.status == "ok" and .target.type == "pull_request"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns PR data | `.data.number == 12` |
| Has expected fields | `.data.title and .data.state and .data.html_url and .data.body` |
| Target has pull_request type | `.target.type == "pull_request"` |

### pr.diff.read

```bash
# Test: get PR diff
echo '{"number":12}' | bash gh/scripts/gh.sh pr.diff.read | jq -e '.status == "ok" and .data.output_file != null and .data.size_bytes > 0'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns output file | `.data.output_file != null` |
| File size is positive | `.data.size_bytes > 0` |

### pr.files.read

```bash
# Test: list PR files
echo '{"number":12}' | bash gh/scripts/gh.sh pr.files.read | jq -e '.status == "ok" and (.data | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns file array | `.data \| type == "array"` |
| Files have filename | `.data[0].filename != null` |
| Files have status | `.data[0].status != null` |

### pr.commits.read

```bash
# Test: list PR commits
echo '{"number":12}' | bash gh/scripts/gh.sh pr.commits.read | jq -e '.status == "ok" and (.data | type == "array") and .data[0].sha != null'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns commit array | `.data \| type == "array"` |
| Commits have sha | `.data[0].sha != null` |
| Commits have message | `.data[0].commit.message != null` |

### pr.checks.read

```bash
# Test: list PR check runs
echo '{"number":12}' | bash gh/scripts/gh.sh pr.checks.read | jq -e '.status == "ok" and (.data | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns check array | `.data \| type == "array"` |
| Checks have name | `(.data[0].name != null) or (.data \| length == 0)` |

### PR Target Resolution

```bash
# Test: resolve PR from current branch (if on a PR branch)
bash gh/scripts/gh.sh pr.read | jq -e '.status == "ok"'

# Test: ambiguous target should fail
echo '{"reference":"u7chan/agent-harness"}' | bash gh/scripts/gh.sh pr.read 2>&1 | jq -e '.status == "failed"'
```

| Check | Pass Condition |
|-------|---------------|
| Missing number with repo-only reference fails | `.status == "failed"` |

### PR Nonexistent

```bash
# Test: nonexistent PR should fail
echo '{"number":999999}' | bash gh/scripts/gh.sh pr.read 2>&1 | jq -e '.status == "failed" and .error.code == "API_ERROR"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `API_ERROR` | `.error.code == "API_ERROR"` |

## Conversation Comment Actions

### comments.read

```bash
# Test: list comments on an issue/PR (collection, full pagination)
echo '{"number":12}' | bash gh/scripts/gh.sh comments.read | jq -e '.status == "ok" and (.data | type == "object") and (.data.items | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Data is an object with items array | `.data \| type == "object"` |
| Returns items array | `.data.items \| type == "array"` |
| Items have id | `.data.items[0].id != null` (if comments exist) |
| Items have body | `.data.items[0].body != null` (if comments exist) |
| Items have html_url | `.data.items[0].html_url != null` (if comments exist) |
| Target has correct type | `.target.type` in `("issue", "pull_request")` |

### comments.read (single)

```bash
# Test: get single comment by ID
echo '{"number":12, "comment_id":1}' | bash gh/scripts/gh.sh comments.read | jq -e '.status == "ok" or .status == "failed"'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` or `failed` (comment may not exist) | `.status` in `("ok", "failed")` |
| Data is an object with item field | (if ok) `.data.item \| type == "object"` |
| Single item has id | (if ok) `.data.item.id != null` |

### comments.read (parent mismatch)

```bash
# Test: comment_id does not belong to the given number
echo '{"number":999999, "comment_id":1}' | bash gh/scripts/gh.sh comments.read 2>&1 | jq -e '.status == "failed" and (.error.code == "PARENT_MISMATCH" or .error.code == "API_ERROR")'
```

| Check | Pass Condition |
|-------|---------------|
| status failed (parent mismatch or not found) | `.status == "failed"` |
| error is PARENT_MISMATCH or API_ERROR | `.error.code` in `("PARENT_MISMATCH", "API_ERROR")` |

### comments.read (per_page constraint)

```bash
# Test: invalid per_page should fail
echo '{"number":1, "per_page":200}' | bash gh/scripts/gh.sh comments.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### comments.read (per_page non-integer)

```bash
# Test: per_page=1.5 (non-integer) should fail
echo '{"number":1, "per_page":1.5}' | bash gh/scripts/gh.sh comments.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### comments.create

```bash
# Test: create comment (requires a test issue/PR)
echo '{"number":1, "body": "smoke-test-comment", "grant": "write"}' | bash gh/scripts/gh.sh comments.create | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok (or already_applied for dedup) | `.status` in `("ok", "already_applied")` |
| comment has id | `.data.id != null` |
| comment body matches | `.data.body == "smoke-test-comment"` |

### comments.create (trailing newline preservation)

```bash
# Test: create comment with trailing newlines should preserve them
echo '{"number":1, "body": "line1\nline2\n\n", "grant": "write"}' | bash gh/scripts/gh.sh comments.create | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok (or already_applied) | `.status` in `("ok", "already_applied")` |
| body ends with newlines | `.data.body \| endswith("\n\n")` |

### comments.reply

```bash
# Test: reply to a comment
echo '{"number":1, "reply_to":1, "body": "smoke-test-reply", "grant": "write"}' | bash gh/scripts/gh.sh comments.reply | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok (or already_applied for dedup) | `.status` in `("ok", "already_applied")` |
| reply has native_thread: false | `.data.native_thread == false` |
| reply has reply_to_url | `.data.reply_to_url != null` |
| body contains "> Re:" prefix | `.data.body \| test("> Re: ")` |

### comments.reply (reply mismatch)

```bash
# Test: reply_to comment does not belong to given number
echo '{"number":999999, "reply_to":1, "body": "reply fail", "grant": "write"}' | bash gh/scripts/gh.sh comments.reply 2>&1 | jq -e '.status == "failed" and (.error.code == "REPLY_MISMATCH" or .error.code == "API_ERROR")'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error is REPLY_MISMATCH or API_ERROR | `.error.code` in `("REPLY_MISMATCH", "API_ERROR")` |

### comments.update

```bash
# Test: update comment body
echo '{"comment_id":1, "body": "smoke-test-updated", "grant": "write"}' | bash gh/scripts/gh.sh comments.update | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok (or already_applied if body unchanged) | `.status` in `("ok", "already_applied")` |
| updated body matches | `.data.body == "smoke-test-updated"` |

### comments.delete

```bash
# Test: delete comment
echo '{"comment_id":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh comments.delete | jq -e '.status == "ok" or .status == "failed"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok (or failed if already deleted) | `.status` in `("ok", "failed")` |
| deleted flag is true (if ok) | (if ok) `.data.deleted == true` |

### Grant Rejection (comments.delete with read grant)

```bash
# Test: insufficient grant should fail
echo '{"comment_id":1, "grant": "read"}' | bash gh/scripts/gh.sh comments.delete 2>&1 | jq -e '.status == "failed" and .error.code == "GRANT_INSUFFICIENT"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code GRANT_INSUFFICIENT | `.error.code == "GRANT_INSUFFICIENT"` |

## Review Comment Actions

### review-comments.read

```bash
# Test: list review comments on a PR (collection, full pagination)
echo "{\"number\":$TEST_PR_NUMBER}" | bash gh/scripts/gh.sh review-comments.read | jq -e '.status == "ok" and (.data | type == "object") and (.data.items | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Data is an object with items array | `.data \| type == "object"` |
| Returns items array | `.data.items \| type == "array"` |
| Items have id | `.data.items[0].id != null` (if comments exist) |
| Items have path | `.data.items[0].path != null` (if comments exist) |
| Target has correct type | `.target.type == "pull_request"` |

### review-comments.read (single)

```bash
# Test: get single review comment by ID (use dynamic comment ID if available)
if [ -n "$TEST_COMMENT_ID" ]; then
  echo "{\"number\":$TEST_PR_NUMBER, \"comment_id\":$TEST_COMMENT_ID}" | bash gh/scripts/gh.sh review-comments.read | jq -e '.status == "ok" or .status == "failed"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` or `failed` | `.status` in `("ok", "failed")` |
| Data has item field (if ok) | (if ok) `.data.item \| type == "object"` |
| Single item has id | (if ok) `.data.item.id != null` |

### review-comments.read (parent mismatch)

```bash
# Test: comment_id does not belong to the given PR
if [ -n "$TEST_COMMENT_ID" ]; then
  echo "{\"number\":999999, \"comment_id\":$TEST_COMMENT_ID}" | bash gh/scripts/gh.sh review-comments.read 2>&1 | jq -e '.status == "failed" and (.error.code == "PARENT_MISMATCH" or .error.code == "API_ERROR")'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error is PARENT_MISMATCH or API_ERROR | `.error.code` in `("PARENT_MISMATCH", "API_ERROR")` |

### review-comments.read (per_page constraint)

```bash
# Test: invalid per_page should fail
echo '{"number":1, "per_page":200}' | bash gh/scripts/gh.sh review-comments.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### review-comments.read (per_page non-integer)

```bash
# Test: per_page=1.5 (non-integer) should fail
echo '{"number":1, "per_page":1.5}' | bash gh/scripts/gh.sh review-comments.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### review-comments.create

```bash
# Test: create review comment (requires a test PR with known commit)
echo "{\"number\":$TEST_PR_NUMBER, \"body\": \"smoke-test-review-comment\", \"commit_id\": \"$TEST_COMMIT_SHA\", \"path\": \"smoke-test.js\", \"line\": 2, \"grant\": \"write\"}" | bash gh/scripts/gh.sh review-comments.create | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| comment has id | `.data.id != null` |
| comment body matches | `.data.body == "smoke-test-review-comment"` |

### review-comments.reply

```bash
# Test: reply to a review comment (use dynamic comment ID if available)
if [ -n "$TEST_COMMENT_ID" ]; then
  BASELINE_COMMENT_IDS=$(echo "{\"number\":$TEST_PR_NUMBER}" \
    | bash gh/scripts/gh.sh review-comments.read | jq -c '.data.items | map(.id)')
  jq -n --argjson ids "$BASELINE_COMMENT_IDS" \
    --argjson reply_to "$TEST_COMMENT_ID" \
    '{number: '$TEST_PR_NUMBER', reply_to: $reply_to, body: "smoke-test-review-reply", plan_fingerprint: "smoke-test-plan", baseline_comment_ids: $ids, grant: "write"}' \
    | bash gh/scripts/gh.sh review-comments.reply \
    | jq -e '.status == "ok" or .status == "already_applied"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| reply has in_reply_to_id | `.data.in_reply_to_id != null` |

### review-comments.reply (reply mismatch)

```bash
# Test: reply_to comment does not belong to given PR (operation identity is still required)
echo "{\"number\":999999, \"reply_to\":$TEST_COMMENT_ID, \"body\": \"reply fail\", \"plan_fingerprint\": \"smoke-test-plan\", \"baseline_comment_ids\": [], \"grant\": \"write\"}" | bash gh/scripts/gh.sh review-comments.reply 2>&1 | jq -e '.status == "failed"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error is REPLY_MISMATCH or API_ERROR | `.error.code` in `("REPLY_MISMATCH", "API_ERROR")` |

### review-comments.update

```bash
# Test: update review comment body (use dynamic comment ID if available)
if [ -n "$TEST_COMMENT_ID" ]; then
  echo "{\"comment_id\":$TEST_COMMENT_ID, \"body\": \"smoke-test-review-updated\", \"grant\": \"write\"}" | bash gh/scripts/gh.sh review-comments.update | jq -e '.status == "ok" or .status == "already_applied"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| updated body matches (if ok) | (if ok) `.data.body == "smoke-test-review-updated"` |

### review-comments.delete

```bash
# Test: delete review comment (use dynamic comment ID if available)
if [ -n "$TEST_COMMENT_ID" ]; then
  echo "{\"comment_id\":$TEST_COMMENT_ID, \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-comments.delete | jq -e '.status == "ok" or .status == "failed"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status ok or failed | `.status` in `("ok", "failed")` |
| deleted flag is true (if ok) | (if ok) `.data.deleted == true` |

## Review Actions

### reviews.read

```bash
# Test: list reviews on a PR
echo "{\"number\":$TEST_PR_NUMBER}" | bash gh/scripts/gh.sh reviews.read | jq -e '.status == "ok" and (.data | type == "object") and (.data.items | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Data is an object with items array | `.data \| type == "object"` |
| Returns items array | `.data.items \| type == "array"` |

### reviews.read (single)

```bash
# Test: get single review by ID (use dynamic review ID from collection if available)
TEST_REVIEW_ID=$(echo "{\"number\":$TEST_PR_NUMBER}" \
  | bash gh/scripts/gh.sh reviews.read \
  | jq -r '.data.items[0].id // empty')
if [ -n "$TEST_REVIEW_ID" ]; then
  echo "{\"number\":$TEST_PR_NUMBER, \"review_id\":$TEST_REVIEW_ID}" | bash gh/scripts/gh.sh reviews.read | jq -e '.status == "ok" or .status == "failed"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` or `failed` | `.status` in `("ok", "failed")` |
| Data has item field (if ok) | (if ok) `.data.item \| type == "object"` |

### reviews.read (per_page non-integer)

```bash
# Test: per_page=1.5 should fail as non-integer
echo '{"number":1, "per_page":1.5}' | bash gh/scripts/gh.sh reviews.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### reviews.create (COMMENT event)

```bash
# Test: create COMMENT review
echo "{\"number\":$TEST_PR_NUMBER, \"body\": \"smoke-test-review-body\", \"grant\": \"write\"}" | bash gh/scripts/gh.sh reviews.create | jq -e '.status == "ok"'
```

| Check | Pass Condition |
|-------|---------------|
| status ok | `.status` in `("ok")` |
| review has id | `.data.id != null` |
| state is not APPROVED/CHANGES_REQUESTED | `.data.state != "APPROVED"` and `.data.state != "CHANGES_REQUESTED"` |

### reviews.create (reject APPROVE event)

```bash
# Test: APPROVE event should be rejected
echo "{\"number\":$TEST_PR_NUMBER, \"body\": \"approval\", \"event\": \"APPROVE\", \"grant\": \"write\"}" | bash gh/scripts/gh.sh reviews.create 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### reviews.create (reject REQUEST_CHANGES event)

```bash
# Test: REQUEST_CHANGES event should be rejected
echo "{\"number\":$TEST_PR_NUMBER, \"body\": \"changes needed\", \"event\": \"REQUEST_CHANGES\", \"grant\": \"write\"}" | bash gh/scripts/gh.sh reviews.create 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### reviews.submit-comment

```bash
# Test: submit comment to pending review (create PENDING review first)
TEST_PENDING_RESULT=$(echo "{\"number\":$TEST_PR_NUMBER, \"body\": \"pending review body\", \"event\": \"PENDING\", \"grant\": \"write\"}" \
  | bash gh/scripts/gh.sh reviews.create)
# Verify pending review was created successfully
echo "$TEST_PENDING_RESULT" | jq -e '.status == "ok" and .data.id != null and .data.state == "PENDING"'
TEST_PENDING_REVIEW_ID=$(echo "$TEST_PENDING_RESULT" | jq -r '.data.id')
# Submit comment and verify result
echo "{\"number\":$TEST_PR_NUMBER, \"review_id\":$TEST_PENDING_REVIEW_ID, \"body\": \"smoke-test-submit-comment\", \"grant\": \"write\"}" \
  | bash gh/scripts/gh.sh reviews.submit-comment \
  | jq -e '.status == "ok" and .data.state == "COMMENTED" and .data.body == "smoke-test-submit-comment"'
```

| Check | Pass Condition |
|-------|---------------|
| pending review created | `.status` == `"ok"` |
| pending review has id | `.data.id != null` |
| pending review state is PENDING | `.data.state` == `"PENDING"` |
| submit-comment status ok | `.status` == `"ok"` |
| submitted review state is COMMENTED | `.data.state` == `"COMMENTED"` |
| submitted body matches expected | `.data.body` == `"smoke-test-submit-comment"` |

### reviews.submit-comment (reject non-COMMENT event)

```bash
# Test: APPROVE event in submit-comment should be rejected
echo "{\"number\":$TEST_PR_NUMBER, \"review_id\":1, \"body\": \"submit approval\", \"event\": \"APPROVE\", \"grant\": \"write\"}" | bash gh/scripts/gh.sh reviews.submit-comment 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

## Review Thread Actions

### review-threads.read

```bash
# Test: list review threads on a PR (use dynamically created PR number)
echo "{\"number\":$TEST_PR_NUMBER}" | bash gh/scripts/gh.sh review-threads.read | jq -e '.status == "ok" and (.data.threads | type == "array")'
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Data has threads array | `.data.threads \| type == "array"` |
| Threads have thread_id (string) | `.data.threads[0].thread_id \| type == "string"` (if threads exist) |
| Threads have comments | `.data.threads[0].comments \| type == "array"` (if threads exist) |
| Threads have resolved | `.data.threads[0].resolved \| type == "boolean"` (if threads exist) |

### review-threads.read (single thread)

```bash
# Test: get single thread by thread_id (GraphQL node ID, string)
# 動的取得した最初のthread IDを使用
if [ -n "$THREAD_IDS" ]; then
  echo "{\"number\":$TEST_PR_NUMBER, \"thread_id\":\"$THREAD_IDS\"}" | bash gh/scripts/gh.sh review-threads.read | jq -e '.status == "ok" and (.data.threads | length >= 0)'
fi
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns single thread | `.data.threads \| length == 1` |

### review-threads.read (per_page non-integer)

```bash
# Test: per_page=1.5 should fail
echo '{"number":1, "per_page":1.5}' | bash gh/scripts/gh.sh review-threads.read 2>&1 | jq -e '.status == "failed" and .error.code == "INVALID_PARAMETER"'
```

| Check | Pass Condition |
|-------|---------------|
| status failed | `.status == "failed"` |
| error code INVALID_PARAMETER | `.error.code == "INVALID_PARAMETER"` |

### review-threads.resolve

```bash
# Test: resolve a review thread (thread_id is GraphQL node ID string)
# 動的取得した最初のthread IDを使用
if [ -n "$THREAD_IDS" ]; then
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.resolve | jq -e '.status == "ok" or .status == "already_applied"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| resolved is true | `.data.resolved == true` |

### review-threads.resolve (already_applied)

```bash
# Test: resolve already resolved thread returns already_applied
if [ -n "$THREAD_IDS" ]; then
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.resolve | jq -e '.status == "already_applied" and .data.resolved == true'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status already_applied | `.status == "already_applied"` |
| resolved stays true | `.data.resolved == true` |

### review-threads.unresolve

```bash
# Test: unresolve a review thread
if [ -n "$THREAD_IDS" ]; then
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.unresolve | jq -e '.status == "ok" or .status == "already_applied"'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| resolved is false | `.data.resolved == false` |

### review-threads.unresolve (already_applied)

```bash
# Test: unresolve already unresolved thread returns already_applied
if [ -n "$THREAD_IDS" ]; then
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.unresolve | jq -e '.status == "already_applied" and .data.resolved == false'
fi
```

| Check | Pass Condition |
|-------|---------------|
| status already_applied | `.status == "already_applied"` |
| resolved stays false | `.data.resolved == false` |

### review-threads resolve/unresolve state transition

```bash
# Test: full state transition cycle
# 動的取得したthread IDを使用
if [ -n "$THREAD_IDS" ]; then
  # 1. resolve → ok
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.resolve | jq -e '.status == "ok" and .data.resolved == true'

  # 2. re-resolve → already_applied
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.resolve | jq -e '.status == "already_applied"'

  # 3. unresolve → ok
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.unresolve | jq -e '.status == "ok" and .data.resolved == false'

  # 4. re-unresolve → already_applied
  echo "{\"thread_id\":\"$THREAD_IDS\", \"grant\": \"sensitive-write\"}" | bash gh/scripts/gh.sh review-threads.unresolve | jq -e '.status == "already_applied"'
fi
```

## PR Lifecycle Actions

### pr.create

```bash
# Test: create PR from current branch to main
jq -n --arg head "$(git branch --show-current)" '{"title": "smoke-test-pr-create", "base": "main", "head": $head, "grant": "write"}' | bash gh/scripts/gh.sh pr.create | jq -e '.status == "ok" and .data.number != null and .data.title == "smoke-test-pr-create"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| PR created | `.data.number != null` |
| title matches | `.data.title == "smoke-test-pr-create"` |

### pr.update

```bash
# Test: update PR title
echo '{"number":12, "title": "smoke-test-pr-update", "grant": "write"}' | bash gh/scripts/gh.sh pr.update | jq -e '.status == "ok" and .data.title == "smoke-test-pr-update"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| title updated | `.data.title == "smoke-test-pr-update"` |

### pr.draft

```bash
# Test: convert PR to draft
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.draft | jq -e '.status == "ok" and .data.draft == true'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| draft true | `.data.draft == true` |

### pr.ready

```bash
# Test: mark PR as ready
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.ready | jq -e '.status == "ok" and .data.draft == false'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| draft false | `.data.draft == false` |

### pr.close

```bash
# Test: close PR
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.close | jq -e '.status == "ok" and .data.state == "closed"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state closed | `.data.state == "closed"` |

### pr.reopen

```bash
# Test: reopen PR
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.reopen | jq -e '.status == "ok" and .data.state == "open"'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state open | `.data.state == "open"` |

### reviewers.read

```bash
# Test: read requested reviewers
echo '{"number":12}' | bash gh/scripts/gh.sh reviewers.read | jq -e '.status == "ok" and (.data.users | type == "array") and (.data.teams | type == "array")'
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| has users array | `.data.users \| type == "array"` |
| has teams array | `.data.teams \| type == "array"` |

### reviewers.request

```bash
# Test: request reviewers
echo '{"number":12, "reviewers":["octocat"], "grant": "write"}' | bash gh/scripts/gh.sh reviewers.request | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| has users | `.data.users \| length > 0` |

### reviewers.remove

```bash
# Test: remove requested reviewers
echo '{"number":12, "reviewers":["octocat"], "grant": "sensitive-write"}' | bash gh/scripts/gh.sh reviewers.remove | jq -e '.status == "ok" or .status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |
| reviewer removed | `.data.users \| any(.login == "octocat") \| not` |

### PR Idempotency

```bash
# Test: close already closed PR returns already_applied
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.close | jq -e '.status == "already_applied"'

# Test: draft already draft PR returns already_applied
echo '{"number":12, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh pr.draft | jq -e '.status == "already_applied"'
```

| Check | Filter |
|-------|--------|
| status already_applied | `.status == "already_applied"` |

## Verification Points

Additional verification points for review without destructive side effects:

### Comment body safety
- Create/reply/update must never pass body through shell variable or command substitution.
- Trailing newline sequences in body must survive round-trip (create → read).
- Dedup comparison must use file-based body equality (`jq -j` + `cmp`).

### Comment target & parent
- Single read must verify `comment.issue_url` == parent `url`; return `PARENT_MISMATCH` on mismatch.
- Reply must verify `reply_to.issue_url` == parent issue/PR `url`; return `REPLY_MISMATCH` on mismatch.
- Both Issue and PR conversation comments use the same `/issues/{n}/comments` endpoint.

### Delete verification
- Only explicit `HTTP 404` in re-fetch stderr after DELETE confirms successful deletion.
- Auth errors, network errors, 5xx responses must result in `unknown_outcome`.

### Write verification
- create/reply must verify POST response id/url against refetched id/url.
- create/reply must verify POST response body == refetched body == expected body (file-based cmp).
- update must verify PATCH response id/url against refetched id/url.
- update must verify that the body has actually changed (before/after differ) AND refetched body == expected body.

### Pagination
- `comments.read` collection uses `call_gh_api_paginated` for full pagination.
- `per_page` must be an integer in [1, 100]; non-integer (e.g. 1.5) or out-of-range → `INVALID_PARAMETER`.
- Verify 101+ comments are all fetched (observation: smoke tests use disposable per_page=100).

### Review comment parent verification
- Single review comment read must verify `comment.pull_request_url` == parent PR `url`; return `PARENT_MISMATCH` on mismatch.
- Reply must verify `reply_to.pull_request_url` == parent PR `url`; return `REPLY_MISMATCH` on mismatch.
- Review comment API endpoints use `/pulls/{n}/comments` and `/pulls/comments/{id}` (separate from conversation comments).

### Root comment resolution (review-comments.reply)
- Reply tracks the `in_reply_to_id` chain through a visited set to detect circular references.
- Root resolution must have a max depth guard (50 hops) to prevent infinite loops.
- Reply inherits `path` and `commit_id` from the root comment.

### Review event restriction
- `reviews.create` allows `event=COMMENT` (default, immediate submit) or `event=PENDING` (create pending review for later submission).
- `reviews.submit-comment` only allows `event=COMMENT`.
- `APPROVE` and `REQUEST_CHANGES` events must be rejected with `INVALID_PARAMETER`.

### Review comment dedup (review-comments.create)
- Dedup checks: actor, body, path, commit_id, line, side, start_line, start_side, subject_type.
- Same body on different file/line must NOT match.

### Review comment dedup (review-comments.reply)
- Dedup is operation-scoped: pass `plan_fingerprint` and the complete `baseline_comment_ids`.
- A baseline exact-body reply is not reused just because its actor/body/root match; only one baseline-outside expected direct reply may be returned as `already_applied`.
- A nonmatching comment, multiple effects, edit/delete, or an unexpected post-write delta must return `PRECONDITION_CHANGED` without creating a success target.

### Thread state verification
- `review-threads.resolve` and `review-threads.unresolve` use GraphQL mutations.
- `thread_id` is a GraphQL node ID (string), not a numeric root comment ID.
- Before-state check uses GraphQL `node(id)` query to verify current `isResolved`.
- After mutation, re-queries to confirm state change.
- Already-resolved threads must return `already_applied` on re-resolve.
- Already-unresolved threads must return `already_applied` on re-unresolve.

### Nested pagination (review-threads.read)
- reviewThreads fetched via GraphQL cursor pagination.
- Each thread includes its comments connection.
- thread_id is the GraphQL PullRequestReviewThread node ID (string).
- Each thread outputs: `thread_id` (string), `resolved` (boolean), `comments` (array).

### Review submit-comment body verification
- POST response body compares against refetched body and expected body.
- refetched `state` is verified to be `COMMENTED`.
- If review is already submitted (not PENDING) with matching body, returns `already_applied`.

## Repository Cleanliness

```bash
# After all smoke tests, the repo should be clean
git status --porcelain
```

| Check | Pass Condition |
|-------|---------------|
| No dirty files in git | `git status --porcelain` is empty |

## Disposable Test Cleanup

テスト終了後は以下のコマンドでクリーンアップする。

```bash
# テスト用ブランチを削除し元のブランチに戻す
git checkout "$CURRENT_BRANCH"
git branch -D "$TEST_BRANCH" 2>/dev/null || true
git push origin --delete "$TEST_BRANCH" 2>/dev/null || true

# PRをclose
echo "{\"number\":$TEST_PR_NUMBER, \"grant\": \"sensitive-write\"}" \
  | bash gh/scripts/gh.sh pr.close | jq -e '.status == "ok"'
```
