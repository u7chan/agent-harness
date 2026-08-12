#!/usr/bin/env bash
set -u

CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_SKILL_DIR="$(cd "$CONTRACT_DIR/../.." && pwd)"

setup_fixture() {
  FIXTURE_DIR="$(mktemp -d /tmp/pwcli-fixture-XXXXXX)"
  mkdir -p "$FIXTURE_DIR/bin"

  cp "$PW_SKILL_DIR/tests/contract/fake-pwcli.sh" "$FIXTURE_DIR/bin/playwright-cli"
  chmod +x "$FIXTURE_DIR/bin/playwright-cli"

  cat > "$FIXTURE_DIR/package.json" <<'EOF'
{
  "name": "@playwright/cli",
  "version": "0.1.18",
  "dependencies": {
    "playwright": "1.63.0-alpha-2026-08-05",
    "playwright-core": "1.63.0-alpha-2026-08-05"
  }
}
EOF

  cp "$PW_SKILL_DIR/actions.json" "$FIXTURE_DIR/actions.json"

  export PWCLI_BIN="$FIXTURE_DIR/bin/playwright-cli"
  export PW_ACTIONS_JSON="$FIXTURE_DIR/actions.json"
  export PWCLI_CACHE_DIR="$FIXTURE_DIR/cache"
  export FAKE_PWCLI_REAL_FIXTURE="$PW_SKILL_DIR/tests/contract/real-cli-fixture.json"

  # The fake help payload is captured from the pinned real package and must
  # produce the catalog fingerprint without rewriting the allowlist.
  local fake_fingerprint
  fake_fingerprint="$(source "$PW_SKILL_DIR/scripts/common/runtime.sh" 2>/dev/null; pw_help_fingerprint_sha256 "$PWCLI_BIN")"
  local expected_fingerprint
  expected_fingerprint="$(jq -r '.compatibility.runtimes[.compatibility.default_runtime].help_fingerprint_sha256' "$FIXTURE_DIR/actions.json")"
  if [ "$fake_fingerprint" != "$expected_fingerprint" ]; then
    printf 'fake CLI fingerprint mismatch: expected=%s got=%s\n' "$expected_fingerprint" "$fake_fingerprint" >&2
    return 1
  fi
}

teardown_fixture() {
  rm -rf "${FIXTURE_DIR:-}"
  unset PWCLI_BIN PW_ACTIONS_JSON PWCLI_CACHE_DIR FAKE_PWCLI_REAL_FIXTURE
}

# Run the dispatcher from a fresh workspace directory.
pw_run() {
  local workspace="$1"
  shift
  (cd "$workspace" && PWCLI_BIN="$FIXTURE_DIR/bin/playwright-cli" \
    PW_ACTIONS_JSON="$FIXTURE_DIR/actions.json" \
    PWCLI_CACHE_DIR="$FIXTURE_DIR/cache" \
    "$PW_SKILL_DIR/scripts/playwright.sh" "$@")
}

# Create a fresh workspace (canonical directory with no symlinks).
new_workspace() {
  local ws
  ws="$(mktemp -d /tmp/pwcli-ws-XXXXXX)"
  printf '%s' "$ws"
}

# Standard live-session fixture for a session named demo.
live_session_json() {
  printf '[{"name":"demo","workspace":"fixture","status":"open","browserType":"chromium","userDataDir":null,"headed":false,"persistent":false,"attached":false,"version":"1.63.0-alpha-2026-08-05","compatible":true}]'
}

# Seed a journal file directly into the session state (simulates a crash residue).
seed_journal() {
  local ws="$1" session="$2" request_id="$3" generation="$4" state="$5" action="$6" digest="$7" resolution="${8:-null}"
  local dir="$ws/.playwright-cli/agent-harness/state/$session/requests"
  mkdir -p -m 0700 "$dir"
  jq -nc \
    --arg session "$session" \
    --arg request_id "$request_id" \
    --arg generation "$generation" \
    --arg action "$action" \
    --arg state "$state" \
    --arg digest "$digest" \
    --argjson resolution "$resolution" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: 1,
      session: $session,
      request_id: $request_id,
      generation: $generation,
      action: $action,
      permission: "write",
      digest: $digest,
      state: $state,
      resolution: $resolution,
      error: null,
      updated: $updated
    }' > "$dir/$request_id.json"
  chmod 0600 "$dir/$request_id.json"
}

seed_owner() {
  local ws="$1" session="$2" generation="$3" phase="$4" request_id="$5"
  local dir="$ws/.playwright-cli/agent-harness/state/$session"
  mkdir -p -m 0700 "$dir"
  jq -nc \
    --arg session "$session" \
    --arg generation "$generation" \
    --arg phase "$phase" \
    --arg workspace "$(cd "$ws" && pwd)" \
    --arg compat "$(jq -r '.compatibility.default_runtime' "$FIXTURE_DIR/actions.json")" \
    --arg created "$request_id" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: 1,
      session: $session,
      current_generation: $generation,
      phase: $phase,
      workspace: $workspace,
      compatibility_id: $compat,
      created_request_id: $created,
      updated: $updated
    }' > "$dir/owner.json"
  chmod 0600 "$dir/owner.json"
}

seed_ledger() {
  local ws="$1" session="$2" generation="$3" latest="${4:-null}" recovery="${5:-null}"
  local dir="$ws/.playwright-cli/agent-harness/state/$session"
  mkdir -p -m 0700 "$dir"
  jq -nc \
    --arg session "$session" \
    --arg generation "$generation" \
    --argjson latest "$latest" \
    --argjson recovery "$recovery" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schema_version: 1,
      session: $session,
      generation: $generation,
      latest_observation_id: $latest,
      recovery: $recovery,
      updated: $updated
    }' > "$dir/ledger.json"
  chmod 0600 "$dir/ledger.json"
}

# A deterministic 64-hex digest for seeded journals.
test_digest() {
  printf 'test-%s' "$1" | sha256sum | cut -d' ' -f1
}

# Read the current owner phase from the workspace state.
owner_phase() {
  local ws="$1" session="$2"
  jq -r '.phase' "$ws/.playwright-cli/agent-harness/state/$session/owner.json" 2>/dev/null || echo ""
}

journal_state() {
  local ws="$1" session="$2" request_id="$3"
  jq -r '.state' "$ws/.playwright-cli/agent-harness/state/$session/requests/$request_id.json" 2>/dev/null || echo ""
}
