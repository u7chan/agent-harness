# GH Smoke Tests

## Prerequisites

```bash
command -v jq >/dev/null && command -v gh >/dev/null
```

## Catalog Actions

### actions.list

```bash
# Test: list all actions
bash gh/scripts/gh.sh actions.list | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` | `.status == "ok"` |
| Returns action array | `.data | type == "array"` |
| Contains `actions.list` | `.data[] | select(.name == "actions.list")` |
| Contains `actions.describe` | `.data[] | select(.name == "actions.describe")` |
| Permission is `read` for catalog | `.data[] | select(.category == "catalog") | .permission == "read"` |

### actions.describe

```bash
# Test: describe actions.list
echo '{"action":"actions.list"}' | bash gh/scripts/gh.sh actions.describe | jq .

# Test: describe actions.describe
echo '{"action":"actions.describe"}' | bash gh/scripts/gh.sh actions.describe | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `ok` for valid action | `.status == "ok"` |
| Returns full action definition | `.data.name != null and .data.input_schema != null` |

## Validation

### Unknown action

```bash
# Test: unknown action should fail
bash gh/scripts/gh.sh unknown.action 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `UNKNOWN_ACTION` | `.error.code == "UNKNOWN_ACTION"` |
| retryable is false | `.error.retryable == false` |

### Unknown field

```bash
# Test: unknown field in input should fail
echo '{"unknown_field":"value"}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `UNKNOWN_FIELDS` | `.error.code == "UNKNOWN_FIELDS"` |

### Missing required field

```bash
# Test: missing required field should fail
echo '{}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `MISSING_INPUT` | `.error.code == "MISSING_INPUT"` |

### Type mismatch

```bash
# Test: wrong type should fail
echo '{"action":123}' | bash gh/scripts/gh.sh actions.describe 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `TYPE_MISMATCH` | `.error.code == "TYPE_MISMATCH"` |

### Invalid JSON

```bash
# Test: invalid JSON should fail
echo 'not json' | bash gh/scripts/gh.sh actions.list 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `INVALID_JSON` | `.error.code == "INVALID_JSON"` |

## Envelope Structure

```bash
# Test: envelope has required fields
bash gh/scripts/gh.sh actions.list | jq .
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
bash gh/scripts/gh.sh repo.get | jq .
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
echo '{"number":10}' | bash gh/scripts/gh.sh issue.get | jq .
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
echo '{"state":"open"}' | bash gh/scripts/gh.sh issue.list | jq .
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
echo '{}' | bash gh/scripts/gh.sh issue.get 2>&1 | jq .
```

| Check | Pass Condition |
|-------|---------------|
| Status is `failed` | `.status == "failed"` |
| Error code is `MISSING_INPUT` | `.error.code == "MISSING_INPUT"` |

## Write Actions

### issue.create

```bash
# Test: create issue
echo '{"title": "smoke-test-create", "grant": "write"}' | bash gh/scripts/gh.sh issue.create | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| issue created | `.data.number != null` |

### issue.update

```bash
# Test: update issue title
echo '{"number":1, "title": "smoke-test-update", "grant": "write"}' | bash gh/scripts/gh.sh issue.update | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| title updated | `.data.title == "smoke-test-update"` |

### issue.close

```bash
# Test: close issue
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.close | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state closed | `.data.state == "closed"` |

### issue.reopen

```bash
# Test: reopen issue
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.reopen | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| state open | `.data.state == "open"` |

### labels.add

```bash
# Test: add labels
echo '{"number":1, "labels":["bug","enhancement"], "grant": "write"}' | bash gh/scripts/gh.sh labels.add | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| has labels | `.data.labels | length > 0` |

### labels.remove

```bash
# Test: remove label
echo '{"number":1, "name":"bug", "grant": "sensitive-write"}' | bash gh/scripts/gh.sh labels.remove | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| label removed | `.data.labels | any(. == "bug") | not` |

### labels.set

```bash
# Test: set labels
echo '{"number":1, "labels":["documentation"], "grant": "sensitive-write"}' | bash gh/scripts/gh.sh labels.set | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| labels replaced | `.data.labels == ["documentation"]` |

### assignees.add

```bash
# Test: add assignees
echo '{"number":1, "assignees":["octocat"], "grant": "write"}' | bash gh/scripts/gh.sh assignees.add | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| has assignees | `.data.assignees | length > 0` |

### assignees.remove

```bash
# Test: remove assignees
echo '{"number":1, "assignees":["octocat"], "grant": "sensitive-write"}' | bash gh/scripts/gh.sh assignees.remove | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| assignee removed | `.data.assignees | any(. == "octocat") | not` |

### milestone.set

```bash
# Test: set milestone
echo '{"number":1, "milestone":1, "grant": "write"}' | bash gh/scripts/gh.sh milestone.set | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| milestone set | `.data.milestone != null` |

### milestone.clear

```bash
# Test: clear milestone
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh milestone.clear | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |
| milestone cleared | `.data.milestone.title == null` |

### issue.subissues.add

```bash
# Test: add sub-issue
echo '{"number":1, "sub_issue_id":123, "grant": "write"}' | bash gh/scripts/gh.sh issue.subissues.add | jq .
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |

### issue.subissues.remove

```bash
# Test: remove sub-issue
echo '{"number":1, "sub_issue_id":123, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.subissues.remove | jq .
```

| Check | Filter |
|-------|--------|
| status ok or already_applied | `.status` in `("ok", "already_applied")` |

### issue.subissues.reorder

```bash
# Test: reorder sub-issue
echo '{"number":1, "sub_issue_id":123, "after_id":456, "grant": "write"}' | bash gh/scripts/gh.sh issue.subissues.reorder | jq .
```

| Check | Filter |
|-------|--------|
| status ok | `.status == "ok"` |

### Already Applied (Idempotency)

```bash
# Test: close already closed issue returns already_applied
echo '{"number":1, "grant": "sensitive-write"}' | bash gh/scripts/gh.sh issue.close | jq .
```

| Check | Filter |
|-------|--------|
| status already_applied | `.status == "already_applied"` |

### Grant Rejection

```bash
# Test: insufficient grant should fail
echo '{"title": "fail", "grant": "read"}' | bash gh/scripts/gh.sh issue.create 2>&1 | jq .
```

| Check | Filter |
|-------|--------|
| status failed | `.status == "failed"` |
| error code GRANT_INSUFFICIENT | `.error.code == "GRANT_INSUFFICIENT"` |

## Repository Cleanliness

```bash
# After all smoke tests, the repo should be clean
git status --porcelain
```

| Check | Pass Condition |
|-------|---------------|
| No dirty files in git | `git status --porcelain` is empty |
