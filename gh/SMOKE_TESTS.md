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

## Repository Cleanliness

```bash
# After all smoke tests, the repo should be clean
git status --porcelain
```

| Check | Pass Condition |
|-------|---------------|
| No dirty files in git | `git status --porcelain` is empty |
