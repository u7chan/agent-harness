#!/usr/bin/env bash
# Hermetic tests for the local profile editor's BFF and the model master CLI.
#
# Only the server side is covered: the browser UI has no automated test. The
# server never needs pi here — `--resolver` and `--refresh` replace the two
# subprocesses it calls, and every profile and master lives under a temporary
# PI_CODING_AGENT_DIR. scripts/pi-development/tests/run.sh runs this file as
# part of the shared suite.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/../web/server.mjs"
REFRESH="$SCRIPT_DIR/../refresh-models.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pi-model-editor-test-XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
ASSET="$WORK/agent"
PROFILES="$ASSET/pi-development/profiles"
SERVER_PID=""
PORT=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0
FAIL=0

ok() { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
ng() { printf 'FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

check_eq() {
  local name="$1" got="$2" want="$3"
  [ "$got" = "$want" ] && ok "$name" || ng "$name" "got '$got', want '$want'"
}

check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ok "$name" ;;
    *) ng "$name" "expected to contain: $needle" ;;
  esac
}

check_not_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) ng "$name" "should NOT contain: $needle" ;;
    *) ok "$name" ;;
  esac
}

command -v node >/dev/null 2>&1 || {
  printf 'FAIL: node is required to run the editor tests\n' >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf 'FAIL: curl is required to run the editor tests\n' >&2
  exit 1
}

# --- fixtures ---------------------------------------------------------------

mkdir -p "$PROFILES"

cat > "$WORK/stub-ok.sh" <<'STUB'
#!/usr/bin/env bash
printf 'provider=stub model=stub requested=high supported=high effective=high result=ok thinking_level_map={}\n'
STUB
cat > "$WORK/stub-unresolved.sh" <<'STUB'
#!/usr/bin/env bash
printf 'provider=stub model=stub requested=high supported= effective= result=unresolved thinking_level_map={}\n'
STUB
# One refresh stub serves both outcomes: a marker file selects the failure.
cat > "$WORK/stub-refresh.sh" <<STUB
#!/usr/bin/env bash
if [ -f "$WORK/refresh-fails" ]; then
  printf 'result=failed reason=no-models\n'
  exit 1
fi
if [ -f "$WORK/refresh-slow" ]; then
  sleep 1
fi
printf '{\n  "generated_at": "2026-02-03T00:00:00.000Z",\n  "pi_version": "9.9.9",\n  "providers": [{"id": "stub", "models": [{"id": "stub", "supported_thinking": ["high"]}]}]\n}\n' > "\$PI_CODING_AGENT_DIR/pi-development/models.json"
printf 'result=ok path=%s providers=1 models=1 pi_version=9.9.9\n' "\$PI_CODING_AGENT_DIR/pi-development/models.json"
STUB
chmod +x "$WORK/stub-ok.sh" "$WORK/stub-unresolved.sh" "$WORK/stub-refresh.sh"

cat > "$PROFILES/default.json" <<'JSON'
{
  "pr_fix_shared_with_impl": true,
  "legacy_comment": "dropped on the next write",
  "roles": {
    "impl": {"provider": "p", "model": "m", "thinking": "high"},
    "review": {"provider": "p", "model": "m", "thinking": "high"},
    "pr-fix": {"provider": "p", "model": "m", "thinking": "high"},
    "tmp": {"provider": "p", "model": "m", "thinking": "high", "note": "unknown"}
  }
}
JSON

cat > "$ASSET/pi-development/models.json" <<'JSON'
{
  "generated_at": "2999-01-01T00:00:00.000Z",
  "pi_version": "1.5.2",
  "providers": [{"id": "p", "models": [{"id": "m", "supported_thinking": ["high", "max"]}]}]
}
JSON

hash_of() {
  sha256sum "$1" | cut -d' ' -f1
}

start_server() {
  local tag="$1" resolver="$2" refresh="$3"
  local args=(--port 0 --pi-version 1.5.2)
  [ -n "$resolver" ] && args+=(--resolver "$resolver")
  [ -n "$refresh" ] && args+=(--refresh "$refresh")
  PI_CODING_AGENT_DIR="$ASSET" node "$SERVER" "${args[@]}" >"$WORK/$tag.out" 2>"$WORK/$tag.err" &
  SERVER_PID=$!
  local i
  for i in $(seq 1 200); do
    PORT="$(sed -n 's/^listening host=127\.0\.0\.1 port=//p' "$WORK/$tag.out" 2>/dev/null | head -1)"
    if [ -n "$PORT" ]; then
      return 0
    fi
    sleep 0.05
  done
  printf 'FAIL cannot start server %s\n' "$tag" >&2
  cat "$WORK/$tag.err" >&2
  return 1
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
  fi
  PORT=""
}

api() { # method path [body] -> prints status to stdout, body to $WORK/last
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -o "$WORK/last" -w '%{http_code}' -X "$method" \
      -H 'content-type: application/json' --data "$body" "http://127.0.0.1:$PORT$path"
  else
    curl -s -o "$WORK/last" -w '%{http_code}' -X "$method" "http://127.0.0.1:$PORT$path"
  fi
}

# --- GET /api/state ---------------------------------------------------------

if ! start_server main "$WORK/stub-ok.sh" "$WORK/stub-refresh.sh"; then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

code="$(api GET /api/state)"
state="$(cat "$WORK/last")"
check_eq "state returns 200" "$code" "200"
check_contains "state lists the profile" "$state" '"name":"default"'
check_contains "state keeps the stored roles" "$state" '"roles":{"impl":{"provider":"p"'
check_contains "state returns the hash for the save guard" "$state" '"hash":"'
check_not_contains "state does not spend a resolve per profile" "$state" '"record"'
check_contains "state reports an unknown top-level key" "$state" '"top":["legacy_comment"]'
check_contains "state reports an unknown role" "$state" '"tmp":["note"]'
check_contains "state carries the model candidates" "$state" '"providers":[{"id":"p","models":[{"id":"m"'
check_contains "state marks the master fresh" "$state" '"stale":false'

code="$(api GET /)"
check_eq "index is served" "$code" "200"
check_contains "index is HTML" "$(cat "$WORK/last")" '<!doctype html>'

# Missing and broken masters degrade to free-text mode instead of failing.
mv "$ASSET/pi-development/models.json" "$WORK/models.backup"
code="$(api GET /api/state)"
check_eq "missing master still returns 200" "$code" "200"
check_contains "missing master is reported" "$(cat "$WORK/last")" '"models":{"status":"missing"}'
printf 'not json\n' > "$ASSET/pi-development/models.json"
code="$(api GET /api/state)"
check_eq "broken master still returns 200" "$code" "200"
check_contains "broken master is reported" "$(cat "$WORK/last")" '"status":"invalid"'
mv "$WORK/models.backup" "$ASSET/pi-development/models.json"

# A master with a malformed model row is invalid, not a crash for the UI.
printf '{"generated_at":"2999-01-01T00:00:00.000Z","pi_version":"1.5.2","providers":[{"id":"p","models":[null]}]}\n' > "$ASSET/pi-development/models.json"
code="$(api GET /api/state)"
check_eq "a malformed master still returns 200" "$code" "200"
check_contains "a malformed model row is reported" "$(cat "$WORK/last")" '"reason":"invalid-shape"'
node -e '
const fs = require("node:fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  generated_at: "2999-01-01T00:00:00.000Z",
  pi_version: "1.5.2",
  providers: [{ id: "p", models: [{ id: "m", supported_thinking: ["high", "max"] }] }],
}, null, 2));
' "$ASSET/pi-development/models.json"

# An old master is stale, and says why. The age check is deterministic here;
# the pi-version check needs an installed pi, which this suite does not require.
node -e '
const fs = require("node:fs");
const file = process.argv[1];
const doc = JSON.parse(fs.readFileSync(file, "utf8"));
doc.generated_at = "2020-01-01T00:00:00.000Z";
fs.writeFileSync(file, JSON.stringify(doc));
' "$ASSET/pi-development/models.json"
code="$(api GET /api/state)"
check_contains "an old master is marked stale" "$(cat "$WORK/last")" '"stale_reason":"age"'

# --- PUT /api/profile -------------------------------------------------------

valid_body() { # hash [shared] [ui-tester] [thinking]
  local hash="$1" shared="${2:-true}" ui="${3:-}" thinking="${4:-max}"
  local roles="\"impl\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"$thinking\"},\"review\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"$thinking\"},\"pr-fix\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"$thinking\"}"
  if [ -n "$ui" ]; then
    roles="$roles,\"ui-tester\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"$ui\"}"
  fi
  printf '{"profile":"default","expected_hash":"%s","pr_fix_shared_with_impl":%s,"roles":{%s}}' "$hash" "$shared" "$roles"
}

before="$(hash_of "$PROFILES/default.json")"
code="$(api PUT /api/profile "$(valid_body "$before" true max max)")"
saved="$(cat "$WORK/last")"
check_eq "valid save returns 200" "$code" "200"
check_contains "save echoes the write record" "$saved" 'written=true'
check_eq "save writes mode 600" "$(stat -c '%a' "$PROFILES/default.json")" "600"
check_contains "save applies the thinking level" "$(cat "$PROFILES/default.json")" '"thinking": "max"'
check_not_contains "save drops the unknown top-level key" "$(cat "$PROFILES/default.json")" 'legacy_comment'
check_not_contains "save drops the unknown role" "$(cat "$PROFILES/default.json")" '"tmp"'

after="$(hash_of "$PROFILES/default.json")"
code="$(api PUT /api/profile "$(valid_body "$before" true max high)")"
check_eq "stale hash returns 409" "$code" "409"
check_contains "conflict names both hashes" "$(cat "$WORK/last")" '"result":"conflict"'
check_eq "conflict leaves the file alone" "$(hash_of "$PROFILES/default.json")" "$after"

code="$(api PUT /api/profile "$(valid_body "$after" true "" high)")"
check_eq "saving without ui-tester returns 200" "$code" "200"
check_not_contains "omitting ui-tester removes it" "$(cat "$PROFILES/default.json")" 'ui-tester'

after="$(hash_of "$PROFILES/default.json")"
code="$(api PUT /api/profile "{\"profile\":\"default\",\"expected_hash\":\"$after\",\"pr_fix_shared_with_impl\":true,\"roles\":{\"impl\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"max\"},\"review\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"max\"},\"pr-fix\":{\"provider\":\"p\",\"model\":\"m\",\"thinking\":\"high\"}}}")"
check_eq "pr-fix mismatch returns 422" "$code" "422"
check_contains "mismatch reports the contract reason" "$(cat "$WORK/last")" 'reason=bad-shared'
check_eq "mismatch leaves the file alone" "$(hash_of "$PROFILES/default.json")" "$after"

code="$(api PUT /api/profile "$(valid_body "$after" true "" max | sed 's/"profile":"default"/"profile":"nope"/')")"
check_eq "unknown profile returns 404" "$code" "404"

code="$(api PUT /api/profile "{\"profile\":\"../x\",\"expected_hash\":\"$after\",\"pr_fix_shared_with_impl\":true,\"roles\":{}}")"
check_eq "invalid profile name returns 400" "$code" "400"

code="$(api PUT /api/profile "{\"profile\":\"default\",\"expected_hash\":\"$after\",\"pr_fix_shared_with_impl\":true,\"extra\":1,\"roles\":{}}")"
check_eq "unknown field returns 400" "$code" "400"

# --- host and origin --------------------------------------------------------

code="$(curl -s -o "$WORK/last" -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/api/state")"
check_eq "foreign Host returns 403" "$code" "403"

code="$(curl -s -o "$WORK/last" -w '%{http_code}' -X POST -H 'Origin: http://evil.example' "http://127.0.0.1:$PORT/api/models/refresh")"
check_eq "foreign Origin returns 403" "$code" "403"

# --- catalog refresh --------------------------------------------------------

code="$(curl -s -o "$WORK/last" -w '%{http_code}' -X POST -H "Origin: http://127.0.0.1:$PORT" "http://127.0.0.1:$PORT/api/models/refresh")"
check_eq "refresh returns 200" "$code" "200"
check_contains "refresh reports the new master" "$(cat "$WORK/last")" '"pi_version":"9.9.9"'

: > "$WORK/refresh-fails"
master="$(hash_of "$ASSET/pi-development/models.json")"
code="$(curl -s -o "$WORK/last" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/models/refresh")"
check_eq "failed refresh returns 500" "$code" "500"
check_contains "failed refresh reports the reason" "$(cat "$WORK/last")" 'reason=no-models'
check_eq "failed refresh keeps the master" "$(hash_of "$ASSET/pi-development/models.json")" "$master"
rm -f "$WORK/refresh-fails"

# --- refresh concurrency ----------------------------------------------------

: > "$WORK/refresh-slow"
curl -s -o "$WORK/c1.body" -w '%{http_code}\n' -X POST "http://127.0.0.1:$PORT/api/models/refresh" > "$WORK/c1.code" &
c1=$!
curl -s -o "$WORK/c2.body" -w '%{http_code}\n' -X POST "http://127.0.0.1:$PORT/api/models/refresh" > "$WORK/c2.code" &
c2=$!
wait "$c1" "$c2"
codes="$(cat "$WORK/c1.code" "$WORK/c2.code" | sort | tr '\n' ' ')"
check_eq "a second refresh is refused while one runs" "$codes" "200 409 "
rm -f "$WORK/refresh-slow"

# --- unresolved roles -------------------------------------------------------

stop_server
start_server unresolved "$WORK/stub-unresolved.sh" "$WORK/stub-refresh.sh"
current="$(hash_of "$PROFILES/default.json")"
code="$(api PUT /api/profile "$(valid_body "$current")")"
check_eq "unresolved model returns 422" "$code" "422"
check_contains "unresolved model reports the record" "$(cat "$WORK/last")" 'result=unresolved'
check_eq "unresolved model leaves the file alone" "$(hash_of "$PROFILES/default.json")" "$current"
stop_server

# --- refresh helper CLI -----------------------------------------------------

out="$("$REFRESH" --pi-root "$WORK/missing" 2>/dev/null)"
check_contains "refresh rejects an unreadable pi root" "$out" 'result=failed'
check_contains "refresh names the unreadable pi root" "$out" 'reason=unreadable-pi-root'

out="$("$REFRESH" --nope 2>/dev/null)"
check_contains "refresh rejects an unknown argument" "$out" 'reason=argument-error'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
