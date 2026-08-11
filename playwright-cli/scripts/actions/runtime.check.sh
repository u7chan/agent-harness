#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ACTIONS_JSON="${PW_ACTIONS_JSON:-$PW_ROOT/actions.json}"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/runtime.sh"

main() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    input='{}'
  fi

  pw_resolve_diagnostics || {
    pw_envelope_fail "preflight" "$PW_PREFLIGHT_CODE" "$PW_PREFLIGHT_MESSAGE" false
    exit 1
  }

  local allowlist
  allowlist="$(pw_runtime_allowlist)"
  local expected_fingerprint
  expected_fingerprint="$(jq -r '.help_fingerprint_sha256' <<< "$allowlist")"

  local compatible="false"
  if [ "$PW_CLI_PACKAGE_NAME" = "$(jq -r '.cli_package' <<< "$allowlist")" ] \
    && [ "$PW_CLI_PACKAGE_VERSION" = "$(jq -r '.cli_version' <<< "$allowlist")" ] \
    && [ "$PW_CLI_VERSION_OUT" = "$(jq -r '.cli_version' <<< "$allowlist")" ] \
    && [ "$PW_CLI_EMBEDDED_VERSION" = "$(jq -r '.embedded_playwright_version' <<< "$allowlist")" ] \
    && [ "$PW_CLI_CORE_VERSION" = "$(jq -r '.embedded_playwright_core_version' <<< "$allowlist")" ] \
    && [ "$PW_HELP_FINGERPRINT_SHA256" = "$expected_fingerprint" ]; then
    compatible="true"
  fi

  local data
  data="$(jq -cn \
    --arg executable "${PW_CLI_PATH:-null}" \
    --arg package "${PW_CLI_PACKAGE_NAME:-null}" \
    --arg cli_version "${PW_CLI_PACKAGE_VERSION:-null}" \
    --arg version_out "${PW_CLI_VERSION_OUT:-null}" \
    --arg embedded "${PW_CLI_EMBEDDED_VERSION:-null}" \
    --arg core "${PW_CLI_CORE_VERSION:-null}" \
    --argjson sessions "$PW_SESSIONS" \
    --arg default_runtime "$(pw_default_runtime_id)" \
    --argjson allowlist "$(jq -c '{cli_package, cli_version, embedded_playwright_version, embedded_playwright_core_version, upstream_repository, upstream_commit, npm_integrity, help_fingerprint_sha256}' <<< "$allowlist")" \
    --arg fingerprint "${PW_HELP_FINGERPRINT_SHA256:-null}" \
    --arg compatible "$compatible" \
    '{
      executable: $executable,
      package: {name: $package, version: $cli_version},
      cli_version_output: $version_out,
      embedded_playwright: {version: $embedded},
      embedded_playwright_core: {version: $core},
      sessions: $sessions,
      allowlist: {default_runtime: $default_runtime, runtime: $allowlist},
      help_fingerprint_sha256: $fingerprint,
      compatible: ($compatible == "true")
    }')"

  pw_envelope_ok "$data" "[]" "null"
}

main "$@"
