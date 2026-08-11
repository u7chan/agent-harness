#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ACTIONS_JSON="$PW_ROOT/actions.json"
ACTIONS_DIR="$PW_ROOT/scripts/actions"
FAKE_CLI="$PW_ROOT/tests/contract/fake-pwcli.sh"
META_PROGRAM="$(cat "$SCRIPT_DIR/common/meta-validator.jq")"
failed=0

CANONICAL_COMMANDS="open
list
close
goto
go-back
go-forward
reload
snapshot
find
tab-list
tab-new
tab-select
tab-close
console
click
fill
select
check
uncheck
hover
screenshot"

CANONICAL_MATRIX='{
  "actions.list": ["forbidden", "read", "none"],
  "actions.describe": ["forbidden", "read", "none"],
  "runtime.check": ["forbidden", "read", "none"],
  "browser.list": ["forbidden", "read", "none"],
  "browser.open": ["required", "write", "write"],
  "browser.close": ["required", "write", "write"],
  "page.goto": ["required", "read", "none"],
  "page.back": ["required", "read", "none"],
  "page.forward": ["required", "read", "none"],
  "page.reload": ["required", "read", "none"],
  "page.snapshot": ["required", "read", "none"],
  "page.find": ["required", "read", "none"],
  "tab.list": ["required", "read", "none"],
  "tab.new": ["required", "write", "write"],
  "tab.select": ["required", "read", "none"],
  "tab.close": ["required", "write", "write"],
  "debug.console": ["required", "read", "none"],
  "page.click": ["required", "write", "write"],
  "page.fill": ["required", "write", "write"],
  "page.select": ["required", "write", "write"],
  "page.check": ["required", "write", "write"],
  "page.uncheck": ["required", "write", "write"],
  "page.hover": ["required", "write", "write"],
  "artifact.screenshot": ["required", "write", "write"],
  "recovery.observe": ["required", "read", "none"],
  "recovery.resolve": ["required", "write", "write"]
}'

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  shift
  while (($# > 0)); do
    printf '       %s\n' "$1"
    shift
  done
  failed=1
}

check() {
  local description="$1"
  shift
  local details=()
  local arg
  for arg in "$@"; do
    [ -n "$arg" ] || continue
    details+=("$arg")
  done
  if [ "${#details[@]}" -gt 0 ]; then
    fail "$description" "${details[@]}"
  else
    pass "$description"
  fi
}

if [ ! -f "$ACTIONS_JSON" ]; then
  fail 'actions.json is present' "missing: $ACTIONS_JSON"
  exit 1
fi

if ! jq empty "$ACTIONS_JSON" 2>/dev/null; then
  fail 'actions.json is valid JSON'
  exit 1
fi

# --- top-level structure -----------------------------------------------------
check 'top-level schema_version and limits' \
  "$(jq -r 'if .schema_version != 1 then "schema_version must be 1" else empty end' "$ACTIONS_JSON")" \
  "$(jq -r 'if .limits.inline_bytes != 32768 then "limits.inline_bytes must be 32768" else empty end' "$ACTIONS_JSON")" \
  "$(jq -r 'if .limits.snapshot_bytes != 10485760 then "limits.snapshot_bytes must be 10485760" else empty end' "$ACTIONS_JSON")" \
  "$(jq -r 'if .limits.screenshot_bytes != 52428800 then "limits.screenshot_bytes must be 52428800" else empty end' "$ACTIONS_JSON")"

# --- compatibility allowlist -------------------------------------------------
check 'compatibility.default_runtime exists in runtimes' \
  "$(jq -r 'if (.compatibility.runtimes[.compatibility.default_runtime] == null) then "default_runtime not found in runtimes" else empty end' "$ACTIONS_JSON")"

check 'allowlist runtime entries have complete provenance' \
  "$(jq -r '
    .compatibility.runtimes | to_entries[] |
    . as $entry |
    (["cli_package", "cli_version", "embedded_playwright_version", "embedded_playwright_core_version",
      "upstream_repository", "upstream_commit", "npm_integrity", "help_fingerprint_sha256", "help_fingerprint_commands"] |
     map(select(. as $k | (($entry.value[$k] // "") | tostring | length) == 0 or ($entry.value[$k] | type) == "array" and ($entry.value[$k] | length) == 0))) as $missing |
    if ($missing | length) > 0 then "\($entry.key): missing \($missing | join(","))" else empty end
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .compatibility.runtimes | to_entries[] |
    select((.value.cli_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+.*$")) | not) |
    "\(.key): cli_version not semver-like"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .compatibility.runtimes | to_entries[] |
    select((.value.upstream_commit | test("^[0-9a-f]{40}$")) | not) |
    "\(.key): upstream_commit must be a 40-char hex sha"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .compatibility.runtimes | to_entries[] |
    select((.value.npm_integrity | startswith("sha512-")) | not) |
    "\(.key): npm_integrity must start with sha512-"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .compatibility.runtimes | to_entries[] |
    select((.value.help_fingerprint_sha256 | test("^[0-9a-f]{64}$")) | not) |
    "\(.key): help_fingerprint_sha256 must be a 64-char hex sha"
  ' "$ACTIONS_JSON")"

if [ "$(printf '%s\n' "$CANONICAL_COMMANDS")" != "$(jq -r '.compatibility.runtimes[.compatibility.default_runtime].help_fingerprint_commands[]' "$ACTIONS_JSON")" ]; then
  check 'help_fingerprint_commands match the canonical 21 commands' 'catalog command list differs from the canonical 21 commands'
else
  check 'help_fingerprint_commands match the canonical 21 commands'
fi

# --- action catalog ----------------------------------------------------------
check 'action names are unique' \
  "$(jq -r '
    [.actions | group_by(.name)[] | select(length > 1) | .[0].name] | unique[] |
    "duplicate action: \(.)"
  ' "$ACTIONS_JSON")"

check 'action required fields are present' \
  "$(jq -r '
    .actions | to_entries[] |
    . as $entry |
    ["name", "description", "category", "permission", "session", "grant", "handler", "compatibility_id"] |
    map(select(. as $k | (($entry.value[$k] // "") | tostring | length) == 0)) |
    select(length > 0) |
    "\($entry.key + 1): \($entry.value.name // "<unnamed>") missing=\(join(", "))"
  ' "$ACTIONS_JSON")"

check 'action enums are valid' \
  "$(jq -r '
    .actions[] |
    select(.permission != "read" and .permission != "write" and .permission != "sensitive-write") |
    "\(.name): permission=\(.permission)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] |
    select(.session != "forbidden" and .session != "required") |
    "\(.name): session=\(.session)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] |
    select(.grant != "none" and .grant != "write") |
    "\(.name): grant=\(.grant)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] |
    select(.handler != "internal" and .handler != "cli") |
    "\(.name): handler=\(.handler)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    . as $catalog |
    .actions[] |
    select(.compatibility_id == null or .compatibility_id == "" or ($catalog.compatibility.runtimes[.compatibility_id] == null)) |
    "\(.name): unknown compatibility_id"
  ' "$ACTIONS_JSON")"

check 'action matrix matches the authoritative table' \
  "$(jq -r --argjson matrix "$CANONICAL_MATRIX" '
    (($matrix | keys) - [.actions[].name])[] | "missing from catalog: \(.)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r --argjson matrix "$CANONICAL_MATRIX" '
    .actions[] |
    select($matrix[.name] != null and $matrix[.name] != [.session, .permission, .grant]) |
    "\(.name): expected \($matrix[.name] | join("/")), got \(.session)/\(.permission)/\(.grant)"
  ' "$ACTIONS_JSON")" \
  "$(jq -r --argjson matrix "$CANONICAL_MATRIX" '
    .actions[] |
    select($matrix[.name] == null) |
    "\(.name): not in the authoritative matrix"
  ' "$ACTIONS_JSON")"

# --- cli mapping -------------------------------------------------------------
check 'cli actions map to canonical commands and valid flags' \
  "$(jq -r '
    .actions[] | select(.handler == "cli") |
    select(.cli_command == null or .cli_command == "") |
    "\(.name): missing cli_command"
  ' "$ACTIONS_JSON")" \
  "$(jq -r --argjson commands "$(jq -c '.compatibility.runtimes[.compatibility.default_runtime].help_fingerprint_commands' "$ACTIONS_JSON")" '
    .actions[] | select(.handler == "cli") |
    select(. as $a | $a.cli_command != null and ($commands | index($a.cli_command) == null)) |
    "\(.name): cli_command \(.cli_command) not in the canonical 21 commands"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] | select(.handler == "cli") |
    . as $a |
    .cli_arguments[]? |
    select((.flag | type) != "string" or ((.flag | startswith("--")) | not)) |
    "\($a.name): invalid cli argument flag"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] | select(.handler == "cli") |
    . as $a |
    .cli_flags[]? |
    select((. | type) != "string" or ((. | startswith("--")) | not)) |
    "\($a.name): invalid cli flag"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] | select(.handler == "cli") |
    select(.output_adapter.kind == null or (.output_adapter.kind | IN("list", "open", "close", "tool-result", "snapshot", "screenshot") | not)) |
    "\(.name): unsupported output adapter"
  ' "$ACTIONS_JSON")" \
  "$(jq -r '
    .actions[] | select(.handler == "internal") |
    select(.cli_command != null) |
    "\(.name): internal handler must not fake a cli_command"
  ' "$ACTIONS_JSON")"

# --- schema subset meta-validation ------------------------------------------
check 'input schemas use only the supported keyword subset' \
  "$(jq -c "$META_PROGRAM"' [.actions[] as $a | pw_meta_validate($a.input_schema) as $errors | [$errors[] | "\($a.name): \(.path): \(.message)"] | select(length > 0)] | .[]' "$ACTIONS_JSON")"

check 'input schemas are top-level objects' \
  "$(jq -r '.actions[] | select(.input_schema.type != "object") | "\(.name): input_schema must be an object"' "$ACTIONS_JSON")"

# --- implementation sync -----------------------------------------------------
MISSING_SCRIPTS=()
for action_name in $(jq -r '.actions[] | select(.handler == "internal") | .name' "$ACTIONS_JSON"); do
  if [ ! -f "$ACTIONS_DIR/$action_name.sh" ]; then
    MISSING_SCRIPTS+=("missing script: $action_name.sh")
  fi
done

ORPHAN_SCRIPTS=()
if [ -d "$ACTIONS_DIR" ]; then
  shopt -s nullglob
  for script_path in "$ACTIONS_DIR"/*.sh; do
    script_name="$(basename "$script_path" .sh)"
    if ! jq -e --arg name "$script_name" '.actions[] | select(.name == $name and .handler == "internal")' "$ACTIONS_JSON" >/dev/null; then
      ORPHAN_SCRIPTS+=("orphan script: $script_name.sh")
    fi
  done
fi

check 'internal action implementations are in sync with the catalog' \
  "${MISSING_SCRIPTS[@]}" "${ORPHAN_SCRIPTS[@]}"

if [ -f "$FAKE_CLI" ]; then
  FAKE_CLI_MISSING=()
  while read -r cmd; do
      if ! grep -qE "^[[:space:]]*([a-z-]+\|)*${cmd}\\)" "$FAKE_CLI"; then
      FAKE_CLI_MISSING+=("missing fake CLI command: $cmd")
    fi
  done < <(jq -r '.actions[] | select(.handler == "cli") | .cli_command' "$ACTIONS_JSON")
  check 'fake CLI fixture implements every catalog cli_command' "${FAKE_CLI_MISSING[@]}"
else
  check 'fake CLI fixture implements every catalog cli_command' "missing: $FAKE_CLI"
fi

# --- sensitive fields and precondition codes ---------------------------------
check 'sensitive_fields reference declared input fields' \
  "$(jq -r '
    .actions[] |
    . as $a |
    (.sensitive_fields[]? |
     select(. as $f | (($a.input_schema.properties // {}) | has($f)) | not) |
     "\($a.name): sensitive field \(.) not in input_schema") // empty
  ' "$ACTIONS_JSON")"

check 'precondition_error_codes are non-empty strings' \
  "$(jq -r '
    .actions[] |
    . as $a |
    (.precondition_error_codes[]? |
     select((. | type) != "string" or (. | length) == 0) |
     "\($a.name): invalid precondition error code") // empty
  ' "$ACTIONS_JSON")"

exit "$failed"
