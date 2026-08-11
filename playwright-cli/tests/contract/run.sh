#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

REQ1="11111111-1111-4111-8111-111111111111"
REQ2="22222222-2222-4222-8222-222222222222"
REQ3="33333333-3333-4333-8333-333333333333"
REQ4="44444444-4444-4444-8444-444444444444"
REQ5="55555555-5555-4555-8555-555555555555"
REQ6="66666666-6666-4666-8666-666666666666"
LIVE_DEMO='[{"name":"demo","version":"1.63.0-alpha-2026-08-05","compatible":true}]'

open_demo() {
  pw_run "$1" browser.open "{\"session\":\"demo\",\"request_id\":\"$2\",\"grant\":\"write\"}" 2>&1
}

fill_demo() {
  local ws="$1" req="$2" value="$3"
  pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$req\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":$value}" 2>&1
}

# ============================== Group A: validation =========================

test_unknown_action() {
  local ws
  ws="$(new_workspace)"
  local out rc
  out="$(pw_run "$ws" no.such.action '{}' 2>&1)"; rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$out" '.error.code' "UNKNOWN_ACTION" || return 1
  assert_json_eq "$out" '.error.phase' "validation" || return 1
  assert_json_eq "$out" '.status' "failed" || return 1
}

test_invalid_json() {
  local ws
  ws="$(new_workspace)"
  local out rc
  out="$(pw_run "$ws" browser.open 'not-json' 2>&1)"; rc=$?
  assert_eq "$rc" "1" || return 1
  assert_json_eq "$out" '.error.code' "INVALID_JSON" || return 1
}

test_unknown_field() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/","bogus":1}' 2>&1)"
  assert_json_eq "$out" '.error.code' "UNKNOWN_FIELD" || return 1
  assert_json_eq "$out" '.error.phase' "validation" || return 1
}

test_type_mismatch() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" tab.select '{"session":"demo","index":"not-a-number"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "TYPE_MISMATCH" || return 1
}

test_missing_request_id() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" page.fill '{"session":"demo","grant":"write","target":{"kind":"selector","value":"#a"},"value":"x"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "MISSING_REQUIRED_FIELD" || return 1
}

test_grant_insufficient() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "GRANT_INSUFFICIENT" || return 1
}

test_metacharacter_session_rejected() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" browser.open "{\"session\":\"-evil;rm -rf /\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "FORMAT_VIOLATION" || return 1
}

test_bad_url_rejected() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" page.goto '{"session":"demo","url":"javascript:alert(1)"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "FORMAT_VIOLATION" || return 1
}

test_discriminated_target_variant() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" page.click "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\",\"target\":{\"kind\":\"xpath\",\"value\":\"//a\"}}" 2>&1)"
  assert_json_eq "$out" '.error.code' "DISCRIMINATOR_VIOLATION" || return 1
}

test_oneof_violation() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"full_page\":true}" 2>&1)"
  assert_json_eq "$out" '.error.code' "ONE_OF_VIOLATION" || return 1
}

test_dependent_required_violation() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" tab.new "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\",\"activate\":true}" 2>&1)"
  assert_json_eq "$out" '.error.code' "DEPENDENT_REQUIRED_VIOLATION" || return 1
}

test_envelope_shape() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" actions.list '{"categories":["catalog"]}' 2>&1)"
  assert_json_eq "$out" '.schema_version' "1" || return 1
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.artifacts | type' "array" || return 1
  assert_json_true "$out" 'has("request_id") and has("permission") and has("session") and has("runtime") and has("error")' || return 1
}

test_internal_action_envelope_context() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" actions.list '{"categories":["catalog"],"grant":"read"}' 2>&1)"
  assert_json_eq "$out" '.action' "actions.list" || return 1
  assert_json_eq "$out" '.permission' "read" || return 1
  assert_json_eq "$out" '.session' "null" || return 1
  assert_json_eq "$out" '.request_id' "null" || return 1
  out="$(pw_run "$ws" recovery.observe '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.action' "recovery.observe" || return 1
  assert_json_eq "$out" '.permission' "read" || return 1
}

test_catalog_list_filters() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" actions.list '{"categories":["interaction"]}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '[.data[].category] | unique == ["interaction"]' "true" || return 1
  out="$(pw_run "$ws" actions.list '{"query":"open"}' 2>&1)"
  assert_json_true "$out" '.data | all(.[]; ((.name | ascii_downcase | contains("open")) or (.description | ascii_downcase | contains("open"))))' || return 1
  out="$(pw_run "$ws" actions.list '{"permissions":["write"]}' 2>&1)"
  assert_json_eq "$out" '[.data[].permission] | unique == ["write"]' "true" || return 1
}

test_actions_describe() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" actions.describe '{"action":"page.goto"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.name' "page.goto" || return 1
  assert_json_eq "$out" '.data.handler' "cli" || return 1
  assert_json_eq "$out" '.data.cli_command' "goto" || return 1
  out="$(pw_run "$ws" actions.describe '{"action":"nope.nothing"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "UNKNOWN_ACTION" || return 1
}

# ============================ Group B: runtime preflight ====================

test_runtime_check_ok() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(pw_run "$ws" runtime.check '{}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.compatible' "true" || return 1
  assert_json_eq "$out" '.data.package.name' "@playwright/cli" || return 1
  assert_json_eq "$out" '.data.cli_version_output' "0.1.18" || return 1
  assert_json_eq "$out" '.data.allowlist.runtime.cli_version' "0.1.18" || return 1
}

test_runtime_unresolved() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(cd "$ws" && PWCLI_BIN=/nonexistent/playwright-cli "$SCRIPT_DIR/../../scripts/playwright.sh" runtime.check '{}' 2>&1)"
  assert_json_eq "$out" '.error.code' "RUNTIME_UNRESOLVED" || return 1
}

test_unsupported_cli_version() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_VERSION=0.2.0 pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "UNSUPPORTED_RUNTIME_VERSION" || return 1
  assert_json_eq "$out" '.error.phase' "preflight" || return 1
}

test_unverified_versions() {
  local ws
  ws="$(new_workspace)"
  local pkg="$FIXTURE_DIR/package.json"
  mv "$pkg" "$pkg.bak"
  local out
  out="$(pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  mv "$pkg.bak" "$pkg"
  assert_json_eq "$out" '.error.code' "VERSION_UNVERIFIABLE" || return 1
}

test_fingerprint_mismatch_fails_closed() {
  local ws
  ws="$(new_workspace)"
  local original
  original="$(cat "$FIXTURE_DIR/actions.json")"
  jq '.compatibility.runtimes[.compatibility.default_runtime].help_fingerprint_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$FIXTURE_DIR/actions.json" > "$FIXTURE_DIR/actions.json.tmp"
  mv "$FIXTURE_DIR/actions.json.tmp" "$FIXTURE_DIR/actions.json"
  local out
  out="$(pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  printf '%s\n' "$original" > "$FIXTURE_DIR/actions.json"
  assert_json_eq "$out" '.error.code' "UNSUPPORTED_RUNTIME_VERSION" || return 1
}

test_session_incompatible() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS='[{"name":"demo","version":"9.9.9","compatible":false}]' pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_INCOMPATIBLE" || return 1
}

# ========================== Group C: browser lifecycle ======================

test_open_ok() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(open_demo "$ws" "$REQ1" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.action' "browser.open" || return 1
  assert_json_eq "$out" '.permission' "write" || return 1
  assert_json_eq "$out" '.session' "demo" || return 1
  assert_json_true "$out" '.runtime.cli_package_version == "0.1.18"' || return 1
  assert_json_eq "$out" '.error' "null" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "active" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ1")" "ok" || return 1
  [ -f "$ws/.playwright-cli/agent-harness/state/demo/ledger.json" ] || { echo "ledger missing"; return 1; }
}

test_open_replay() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local gen out
  gen="$(jq -r '.current_generation' "$ws/.playwright-cli/agent-harness/state/demo/owner.json")"
  out="$(open_demo "$ws" "$REQ1" 2>&1)"
  assert_json_eq "$out" '.status' "already_applied" || return 1
  assert_json_eq "$out" ".data.original_generation" "$gen" || return 1
}

test_open_already_live() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_ALREADY_LIVE" || return 1
}

test_open_ownerless_live() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_NOT_OWNED" || return 1
}

test_ownerless_external_rejected() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_NOT_OWNED" || return 1
}

test_close_ok() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "closed" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "ok" || return 1
}

test_close_not_live_owned_closed() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" >/dev/null 2>&1
  local out
  out="$(pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ3\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "already_applied" || return 1
}

test_close_not_open_cli_owned() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_close=not-open pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ3\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "already_applied" || return 1
}

test_close_unowned() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_NOT_OWNED" || return 1
}

test_browser_list_sessionless() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.list '{}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.session' "null" || return 1
  assert_json_eq "$out" '.data.sessions[0].name' "demo" || return 1
}

test_request_id_conflict() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.click "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#b\"}}" 2>&1)"
  assert_json_eq "$out" '.error.code' "REQUEST_ID_CONFLICT" || return 1
  assert_json_eq "$out" '.error.phase' "dispatch" || return 1
}

test_request_id_retired() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local scenario_file
  scenario_file="$(mktemp /tmp/pwcli-scenario-XXXXXX)"
  printf 'tab-close=precondition\n' > "$scenario_file"
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_FILE="$scenario_file" pw_run "$ws" tab.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"index\":9}" >/dev/null 2>&1
  rm -f "$scenario_file"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" tab.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"index\":9}" 2>&1)"
  assert_json_eq "$out" '.error.code' "REQUEST_ID_RETIRED" || return 1
}

test_finalized_history_reopen() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" >/dev/null 2>&1
  local out
  out="$(open_demo "$ws" "$REQ3" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "active" || return 1
  local gen1 gen2
  gen1="$(jq -r '.generation' "$ws/.playwright-cli/agent-harness/state/demo/requests/$REQ1.json")"
  gen2="$(jq -r '.generation' "$ws/.playwright-cli/agent-harness/state/demo/requests/$REQ3.json")"
  if [ "$gen1" = "$gen2" ]; then
    echo "  generations should differ"
    return 1
  fi
}

test_cross_generation_replay() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" >/dev/null 2>&1
  open_demo "$ws" "$REQ3" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "already_applied" || return 1
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "already_applied" || return 1
}

test_lock_busy() {
  local ws
  ws="$(new_workspace)"
  local lock
  lock="$ws/.playwright-cli/agent-harness/state/demo/lock"
  mkdir -p "$(dirname "$lock")"
  touch "$lock"
  flock "$lock" sleep 3 &
  local holder=$!
  sleep 0.3
  local out
  out="$(open_demo "$ws" "$REQ1" 2>&1)"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  assert_json_eq "$out" '.error.code' "LOCK_BUSY" || return 1
  assert_json_eq "$out" '.error.phase' "lock" || return 1
}

# ============================ Group D: classification =======================

test_goto_ok() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.url' "https://example.com/" || return 1
  assert_json_true "$out" '.runtime.embedded_playwright_version == "1.63.0-alpha-2026-08-05"' || return 1
}

test_goto_not_live() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_NOT_LIVE" || return 1
}

test_shell_metacharacters_pass_through_argv() {
  local ws echo_file
  ws="$(new_workspace)"
  echo_file="$(mktemp /tmp/pwcli-echo-XXXXXX)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local value='$(rm -rf /); `id`; * ? [a-z] | & "quoted"'
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_ECHO_FILE="$echo_file" pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":$(jq -nc --arg v "$value" '$v')}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  local echoed
  echoed="$(cat "$echo_file")"
  assert_eq "$echoed" "$value" || return 1
  rm -f "$echo_file"
}

test_newline_value_pass_through_argv() {
  local ws echo_file
  ws="$(new_workspace)"
  echo_file="$(mktemp /tmp/pwcli-echo-XXXXXX)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local value=$'line1\nline2\ttabbed'
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_ECHO_FILE="$echo_file" pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":$(jq -nc --arg v "$value" '$v')}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(cat "$echo_file")" "$value" || return 1
  rm -f "$echo_file"
}

test_exit_code_normalization() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=error pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "execution" || return 1
  assert_json_eq "$out" '.error.code' "SCENARIO_ERROR" || return 1
}

test_empty_output_decode() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=empty pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "decode" || return 1
  assert_json_eq "$out" '.error.code' "EMPTY_OUTPUT" || return 1
}

test_broken_json_decode() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=broken pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.phase' "decode" || return 1
  assert_json_eq "$out" '.error.code' "INVALID_JSON_OUTPUT" || return 1
}

test_multi_json_decode() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=multi pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "INVALID_JSON_OUTPUT" || return 1
}

test_shape_mismatch_verification() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=shape pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "verification" || return 1
  assert_json_eq "$out" '.error.code' "SHAPE_MISMATCH" || return 1
}

test_timeout_read_failed() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "timeout" || return 1
  assert_json_eq "$out" '.error.code' "CLI_TIMEOUT" || return 1
}

test_timeout_write_unknown() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "timeout" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "quarantined" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "unknown" || return 1
}

test_signal_classification() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=signal pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "signal" || return 1
  assert_json_eq "$out" '.error.code' "CLI_SIGNAL" || return 1
  assert_json_eq "$out" '.error.signal' "KILL" || return 1
}

test_timeout_surviving_child() {
  local ws child_pid_file
  ws="$(new_workspace)"
  child_pid_file="$(mktemp /tmp/pwcli-child-XXXXXX)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=hang FAKE_PWCLI_SURVIVING_CHILD=1 FAKE_PWCLI_CHILD_PID_FILE="$child_pid_file" PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "timeout" || return 1
  local child_pid
  child_pid="$(cat "$child_pid_file" 2>/dev/null || echo 0)"
  if [ "$child_pid" != "0" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  rm -f "$child_pid_file"
}

test_stderr_does_not_fail() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_goto=stderr pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
}

test_stderr_excerpt_on_failure() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=stderr-error pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_contains "$(jq -r '.error.stderr_excerpt' <<< "$out")" "diagnostic stderr noise" || return 1
}

test_harness_stderr_not_in_cli_excerpt() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=error pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  local excerpt
  excerpt="$(jq -r '.error.stderr_excerpt // ""' <<< "$out")"
  if [[ "$excerpt" == *"local:"* ]]; then
    echo "  harness stderr leaked into excerpt: $excerpt"
    return 1
  fi
}

test_sensitive_redaction() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local secret="SuperSecretPassword123"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=stderr-secret FAKE_PWCLI_SECRET="$secret" pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":$(jq -nc --arg v "$secret" '$v')}" 2>&1)"
  local excerpt
  excerpt="$(jq -r '.error.stderr_excerpt // ""' <<< "$out")"
  assert_contains "$excerpt" "[REDACTED]" || return 1
  if [[ "$excerpt" == *"$secret"* ]]; then
    echo "  secret leaked in stderr excerpt"
    return 1
  fi
}

test_write_uncertain_error() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=error pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "execution" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "quarantined" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "unknown" || return 1
}

test_precondition_error_definite() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  local scenario_file
  scenario_file="$(mktemp /tmp/pwcli-scenario-XXXXXX)"
  printf 'tab-close=precondition\n' > "$scenario_file"
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_FILE="$scenario_file" pw_run "$ws" tab.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"index\":9}" 2>&1)"
  rm -f "$scenario_file"
  assert_json_eq "$out" '.status' "failed" || return 1
  assert_json_eq "$out" '.error.phase' "execution" || return 1
  assert_json_eq "$out" '.error.code' "TAB_NOT_FOUND" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "failed" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "active" || return 1
}

test_large_snapshot_artifact() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_snapshot=large pw_run "$ws" page.snapshot '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_true "$out" '.data.artifact_ref != null' || return 1
  assert_json_eq "$out" '.artifacts[0].kind' "snapshot" || return 1
  assert_json_eq "$out" '.artifacts[0].sensitive' "true" || return 1
  assert_json_eq "$out" '.artifacts[0].retention' "caller-managed" || return 1
  assert_json_true "$out" '.artifacts[0].sha256 | test("^[0-9a-f]{64}$")' || return 1
  [ -f "$ws/.playwright-cli/agent-harness/artifacts/demo/read/001-snapshot.json" ] || { echo "artifact file missing"; return 1; }
}

test_screenshot_artifact() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.artifacts[0].kind' "screenshot" || return 1
  assert_json_eq "$out" '.artifacts[0].media_type' "image/png" || return 1
  assert_json_eq "$out" '.artifacts[0].sensitive' "true" || return 1
  assert_json_true "$out" '.data.artifact_ref != null' || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "ok" || return 1
}

test_screenshot_missing_artifact() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_screenshot=no-file pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "verification" || return 1
  assert_json_eq "$out" '.error.code' "ARTIFACT_MISSING" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ2")" "unknown" || return 1
}

test_artifacts_never_overwrite() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_snapshot=large pw_run "$ws" page.snapshot '{"session":"demo"}' >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_snapshot=large pw_run "$ws" page.snapshot '{"session":"demo"}' >/dev/null 2>&1
  local count
  count="$(ls "$ws/.playwright-cli/agent-harness/artifacts/demo/read/" | wc -l)"
  assert_eq "$count" "2" || return 1
}

test_full_page_screenshot() {
  local ws argv_file
  ws="$(new_workspace)"
  argv_file="$(mktemp /tmp/pwcli-argv-XXXXXX)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_ARGV_FILE="$argv_file" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"full_page\":true}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.artifacts[0].kind' "screenshot" || return 1
  assert_contains "$(cat "$argv_file")" "--full-page" || return 1
  rm -f "$argv_file"
}

test_screenshot_symlink_attack_rejected() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  # External file larger than the screenshot limit: a harness that trusts the
  # runtime path through a symlink would metadata the external file and remove
  # it on size overflow.
  ext="$(mktemp /tmp/pwcli-ext-XXXXXX)"
  truncate -s 62914560 "$ext"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_screenshot=symlink-attack FAKE_PWCLI_ATTACK_TARGET="$ext" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "verification" || return 1
  assert_json_eq "$out" '.error.code' "ARTIFACT_PATH_MISMATCH" || return 1
  [ -f "$ext" ] || { echo "external file was removed through symlink"; return 1; }
  rm -f "$ext"
}

test_screenshot_cli_path_not_trusted() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  ext="$(mktemp /tmp/pwcli-extpath-XXXXXX)"
  printf 'precious data' > "$ext"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_screenshot=bad-path FAKE_PWCLI_BAD_PATH="$ext" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.code' "ARTIFACT_PATH_MISMATCH" || return 1
  assert_eq "$(cat "$ext")" "precious data" || return 1
  rm -f "$ext"
}

test_artifact_dir_symlink_rejected() {
  local ws ext_dir
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  ext_dir="$(mktemp -d /tmp/pwcli-extdir-XXXXXX)"
  local artifacts_dir="$ws/.playwright-cli/agent-harness/artifacts"
  mkdir -p "$artifacts_dir"
  ln -s "$ext_dir" "$artifacts_dir/demo"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
  assert_json_eq "$out" '.error.phase' "recovery" || return 1
  [ -z "$(ls -A "$ext_dir")" ] || { echo "external dir was written through symlink"; return 1; }
  rm -rf "$ext_dir"
}

test_artifact_request_dir_symlink_rejected() {
  local ws ext_dir
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  ext_dir="$(mktemp -d /tmp/pwcli-extreq-XXXXXX)"
  local artifacts_dir="$ws/.playwright-cli/agent-harness/artifacts"
  mkdir -p "$artifacts_dir/demo"
  ln -s "$ext_dir" "$artifacts_dir/demo/$REQ2"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" artifact.screenshot "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"}}" 2>&1)"
  assert_json_eq "$out" '.error.code' "ARTIFACT_PATH_REJECTED" || return 1
  assert_json_eq "$out" '.error.phase' "dispatch" || return 1
  [ -z "$(ls -A "$ext_dir")" ] || { echo "external dir was written through symlink"; return 1; }
  rm -rf "$ext_dir"
}

# ============================ Group E: state & recovery =====================

test_prepared_ownerless_recovery() {
  local ws gen
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  seed_journal "$ws" demo "$REQ1" "$gen" prepared browser.open "$(test_digest x)"
  local out
  out="$(open_demo "$ws" "$REQ2" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ1")" "failed" || return 1
}

test_opening_prepared_recovery() {
  local ws gen
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  seed_owner "$ws" demo "$gen" opening "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" prepared browser.open "$(test_digest a)"
  local out
  out="$(open_demo "$ws" "$REQ2" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ1")" "failed" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "active" || return 1
}

test_opening_dispatched_recovery() {
  local ws gen
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  seed_owner "$ws" demo "$gen" opening "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" dispatched browser.open "$(test_digest b)"
  local out
  out="$(open_demo "$ws" "$REQ2" 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_QUARANTINED" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ1")" "unknown" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "quarantined" || return 1
  out="$(pw_run "$ws" recovery.observe '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.owner_phase' "quarantined" || return 1
}

test_opening_ok_recovery_active() {
  local ws gen
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  seed_owner "$ws" demo "$gen" opening "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" ok browser.open "$(test_digest c)"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.snapshot '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "active" || return 1
  assert_json_eq "$(cat "$ws/.playwright-cli/agent-harness/state/demo/ledger.json")" '.generation' "$gen" || return 1
}

test_opening_ok_recovery_no_session() {
  local ws gen
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  seed_owner "$ws" demo "$gen" opening "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" ok browser.open "$(test_digest d)"
  local out
  out="$(pw_run "$ws" browser.close "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\"}" 2>&1)"
  assert_eq "$(owner_phase "$ws" demo)" "closed" || return 1
}

test_open_timeout_recovery_cycle() {
  local ws
  ws="$(new_workspace)"
  local out
  out="$(FAKE_PWCLI_SCENARIO_open=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" 2>&1)"
  assert_json_eq "$out" '.status' "unknown_outcome" || return 1
  assert_json_eq "$out" '.error.phase' "timeout" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "quarantined" || return 1
  local obs
  obs="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" recovery.observe '{"session":"demo"}' | jq -r '.data.observation_id')"
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" recovery.resolve "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"subject_request_id\":\"$REQ1\",\"observation_id\":\"$obs\",\"resolution\":\"applied\"}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.owner_phase' "active" || return 1
  assert_eq "$(journal_state "$ws" demo "$REQ1")" "resolved" || return 1
}

test_open_timeout_resolve_not_applied() {
  local ws
  ws="$(new_workspace)"
  FAKE_PWCLI_SCENARIO_open=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" >/dev/null 2>&1
  local obs
  obs="$(pw_run "$ws" recovery.observe '{"session":"demo"}' | jq -r '.data.observation_id')"
  local out
  out="$(pw_run "$ws" recovery.resolve "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"subject_request_id\":\"$REQ1\",\"observation_id\":\"$obs\",\"resolution\":\"not_applied\"}" 2>&1)"
  assert_json_eq "$out" '.data.owner_phase' "closed" || return 1
  out="$(open_demo "$ws" "$REQ3" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
}

test_resolve_indeterminate_stays_quarantined() {
  local ws
  ws="$(new_workspace)"
  FAKE_PWCLI_SCENARIO_open=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" >/dev/null 2>&1
  local obs
  obs="$(pw_run "$ws" recovery.observe '{"session":"demo"}' | jq -r '.data.observation_id')"
  local out
  out="$(pw_run "$ws" recovery.resolve "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"subject_request_id\":\"$REQ1\",\"observation_id\":\"$obs\",\"resolution\":\"indeterminate\"}" 2>&1)"
  assert_json_eq "$out" '.data.owner_phase' "quarantined" || return 1
  assert_eq "$(owner_phase "$ws" demo)" "quarantined" || return 1
}

test_stale_evidence_rejected() {
  local ws
  ws="$(new_workspace)"
  FAKE_PWCLI_SCENARIO_open=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" browser.open "{\"session\":\"demo\",\"request_id\":\"$REQ1\",\"grant\":\"write\"}" >/dev/null 2>&1
  local out
  out="$(pw_run "$ws" recovery.resolve "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"subject_request_id\":\"$REQ1\",\"observation_id\":\"11111111-1111-4111-8111-111111111111\",\"resolution\":\"applied\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "STALE_EVIDENCE" || return 1
}

test_unknown_outcome_blocks_writes_snapshot_allowed() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  FAKE_PWCLI_SESSIONS="$LIVE_DEMO" FAKE_PWCLI_SCENARIO_fill=hang PWCLI_TIMEOUT_SECONDS=1 pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"x\"}" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.fill "{\"session\":\"demo\",\"request_id\":\"$REQ3\",\"grant\":\"write\",\"target\":{\"kind\":\"selector\",\"value\":\"#a\"},\"value\":\"y\"}" 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_QUARANTINED" || return 1
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "SESSION_QUARANTINED" || return 1
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.snapshot '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
}

test_state_corrupt_blocks_and_observe_ok() {
  local ws
  ws="$(new_workspace)"
  local dir="$ws/.playwright-cli/agent-harness/state/demo"
  mkdir -p -m 0700 "$dir"
  printf '{broken json' > "$dir/owner.json"
  chmod 0600 "$dir/owner.json"
  local out
  out="$(open_demo "$ws" "$REQ1" 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
  assert_json_eq "$out" '.error.phase' "recovery" || return 1
  out="$(pw_run "$ws" recovery.observe '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
  assert_json_eq "$out" '.data.state_corrupt' "true" || return 1
}

test_state_owner_symlink_rejected() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local dir="$ws/.playwright-cli/agent-harness/state/demo"
  ext="$(mktemp /tmp/pwcli-extowner-XXXXXX)"
  cp "$dir/owner.json" "$ext"
  rm "$dir/owner.json"
  ln -s "$ext" "$dir/owner.json"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
  assert_json_eq "$out" '.error.phase' "recovery" || return 1
  rm -f "$ext" "$dir/owner.json"
}

test_state_ledger_symlink_rejected() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local dir="$ws/.playwright-cli/agent-harness/state/demo"
  ext="$(mktemp /tmp/pwcli-extledger-XXXXXX)"
  cp "$dir/ledger.json" "$ext"
  rm "$dir/ledger.json"
  ln -s "$ext" "$dir/ledger.json"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
  assert_json_eq "$out" '.error.phase' "recovery" || return 1
  rm -f "$ext" "$dir/ledger.json"
}

test_state_journal_symlink_rejected() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local jdir="$ws/.playwright-cli/agent-harness/state/demo/requests"
  ext="$(mktemp /tmp/pwcli-extjournal-XXXXXX)"
  cp "$jdir/$REQ1.json" "$ext"
  rm "$jdir/$REQ1.json"
  ln -s "$ext" "$jdir/$REQ1.json"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
  assert_json_eq "$out" '.error.phase' "recovery" || return 1
  rm -f "$ext" "$jdir/$REQ1.json"
}

test_state_lock_symlink_rejected() {
  local ws ext
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local dir="$ws/.playwright-cli/agent-harness/state/demo"
  ext="$(mktemp /tmp/pwcli-extlock-XXXXXX)"
  printf 'precious lock target' > "$ext"
  rm "$dir/lock"
  ln -s "$ext" "$dir/lock"
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.goto '{"session":"demo","url":"https://example.com/"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "LOCK_BUSY" || return 1
  assert_json_eq "$out" '.error.phase' "lock" || return 1
  assert_eq "$(cat "$ext")" "precious lock target" || return 1
  rm -f "$ext" "$dir/lock"
}

test_recovery_not_required() {
  local ws
  ws="$(new_workspace)"
  open_demo "$ws" "$REQ1" >/dev/null 2>&1
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" recovery.observe '{"session":"demo"}' 2>&1)"
  assert_json_eq "$out" '.error.code' "RECOVERY_NOT_REQUIRED" || return 1
}

test_unresolved_history_blocks_new_generation() {
  local ws gen_old gen_new
  ws="$(new_workspace)"
  gen_old="$(cat /proc/sys/kernel/random/uuid)"
  gen_new="$(cat /proc/sys/kernel/random/uuid)"
  seed_owner "$ws" demo "$gen_new" closed "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen_old" ok browser.open "$(test_digest e)"
  seed_journal "$ws" demo "$REQ2" "$gen_old" unknown page.click "$(test_digest f)"
  local out
  out="$(open_demo "$ws" "$REQ3" 2>&1)"
  assert_json_eq "$out" '.error.code' "STATE_CORRUPT" || return 1
}

test_stale_reference_rejected() {
  local ws gen obs_id_known ref_value
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  obs_id_known="$(cat /proc/sys/kernel/random/uuid)"
  ref_value="ref:$(printf 'a%.0s' $(seq 1 64))"
  seed_owner "$ws" demo "$gen" active "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" ok browser.open "$(test_digest a)" null
  seed_ledger "$ws" demo "$gen" "\"$obs_id_known\""
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.click "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"ref\",\"value\":\"$ref_value\",\"observation_id\":\"11111111-1111-4111-8111-111111111111\"}}" 2>&1)"
  assert_json_eq "$out" '.error.code' "STALE_REFERENCE" || return 1
  assert_json_eq "$out" '.error.phase' "preflight" || return 1
}

test_stale_reference_ok() {
  local ws gen obs_id_known ref_value
  ws="$(new_workspace)"
  gen="$(cat /proc/sys/kernel/random/uuid)"
  obs_id_known="$(cat /proc/sys/kernel/random/uuid)"
  ref_value="ref:$(printf 'b%.0s' $(seq 1 64))"
  seed_owner "$ws" demo "$gen" active "$REQ1"
  seed_journal "$ws" demo "$REQ1" "$gen" ok browser.open "$(test_digest a)" null
  seed_ledger "$ws" demo "$gen" "\"$obs_id_known\""
  local out
  out="$(FAKE_PWCLI_SESSIONS="$LIVE_DEMO" pw_run "$ws" page.click "{\"session\":\"demo\",\"request_id\":\"$REQ2\",\"grant\":\"write\",\"target\":{\"kind\":\"ref\",\"value\":\"$ref_value\",\"observation_id\":\"$obs_id_known\"}}" 2>&1)"
  assert_json_eq "$out" '.status' "ok" || return 1
}

main() {
  echo "=== playwright-cli dispatcher contract tests ==="
  echo

  setup_fixture
  trap teardown_fixture EXIT

  # Group A: validation and catalog
  run_test test_unknown_action
  run_test test_invalid_json
  run_test test_unknown_field
  run_test test_type_mismatch
  run_test test_missing_request_id
  run_test test_grant_insufficient
  run_test test_metacharacter_session_rejected
  run_test test_bad_url_rejected
  run_test test_discriminated_target_variant
  run_test test_oneof_violation
  run_test test_dependent_required_violation
  run_test test_envelope_shape
  run_test test_internal_action_envelope_context
  run_test test_catalog_list_filters
  run_test test_actions_describe

  # Group B: runtime preflight
  run_test test_runtime_check_ok
  run_test test_runtime_unresolved
  run_test test_unsupported_cli_version
  run_test test_unverified_versions
  run_test test_fingerprint_mismatch_fails_closed
  run_test test_session_incompatible

  # Group C: browser lifecycle
  run_test test_open_ok
  run_test test_open_replay
  run_test test_open_already_live
  run_test test_open_ownerless_live
  run_test test_ownerless_external_rejected
  run_test test_close_ok
  run_test test_close_not_live_owned_closed
  run_test test_close_not_open_cli_owned
  run_test test_close_unowned
  run_test test_browser_list_sessionless
  run_test test_request_id_conflict
  run_test test_request_id_retired
  run_test test_finalized_history_reopen
  run_test test_cross_generation_replay
  run_test test_lock_busy

  # Group D: classification and artifacts
  run_test test_goto_ok
  run_test test_goto_not_live
  run_test test_shell_metacharacters_pass_through_argv
  run_test test_newline_value_pass_through_argv
  run_test test_exit_code_normalization
  run_test test_empty_output_decode
  run_test test_broken_json_decode
  run_test test_multi_json_decode
  run_test test_shape_mismatch_verification
  run_test test_timeout_read_failed
  run_test test_timeout_write_unknown
  run_test test_signal_classification
  run_test test_timeout_surviving_child
  run_test test_stderr_does_not_fail
  run_test test_stderr_excerpt_on_failure
  run_test test_harness_stderr_not_in_cli_excerpt
  run_test test_sensitive_redaction
  run_test test_write_uncertain_error
  run_test test_precondition_error_definite
  run_test test_large_snapshot_artifact
  run_test test_screenshot_artifact
  run_test test_screenshot_missing_artifact
  run_test test_screenshot_symlink_attack_rejected
  run_test test_screenshot_cli_path_not_trusted
  run_test test_artifact_dir_symlink_rejected
  run_test test_artifact_request_dir_symlink_rejected
  run_test test_artifacts_never_overwrite
  run_test test_full_page_screenshot

  # Group E: state and recovery
  run_test test_prepared_ownerless_recovery
  run_test test_opening_prepared_recovery
  run_test test_opening_dispatched_recovery
  run_test test_opening_ok_recovery_active
  run_test test_opening_ok_recovery_no_session
  run_test test_open_timeout_recovery_cycle
  run_test test_open_timeout_resolve_not_applied
  run_test test_resolve_indeterminate_stays_quarantined
  run_test test_stale_evidence_rejected
  run_test test_unknown_outcome_blocks_writes_snapshot_allowed
  run_test test_state_corrupt_blocks_and_observe_ok
  run_test test_state_owner_symlink_rejected
  run_test test_state_ledger_symlink_rejected
  run_test test_state_journal_symlink_rejected
  run_test test_state_lock_symlink_rejected
  run_test test_recovery_not_required
  run_test test_unresolved_history_blocks_new_generation
  run_test test_stale_reference_rejected
  run_test test_stale_reference_ok

  teardown_fixture
  trap - EXIT

  print_summary
}

main
