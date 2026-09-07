#!/usr/bin/env bash
set -uo pipefail

# Contract tests for http.sh call_gh_api retry detection (Issue #176): real
# gh writes HTTP status / transport diagnostics ("HTTP 503", "connection
# refused", rate-limit messages) to stderr while stdout carries the response
# (or error) body. call_gh_api must judge retryability on stdout + stderr
# together, keep the success result stdout-only, honor the retry cap and
# backoff, leave the per-attempt arguments untouched, never auto-resend an
# unknown-outcome request (single-write settings such as GH_RETRY_MAX=1 stay
# honored), and forward only a redacted, size-bounded diagnostic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/fixture.sh"

# Stateful mock gh. Env-driven behavior:
#   MOCK_MODE != success: every api call whose attempt number is <=
#     MOCK_FAIL_UNTIL fails: MOCK_FAIL_STDOUT / MOCK_FAIL_STDERR are emitted
#     and the process exits MOCK_FAIL_RC. Later attempts succeed with
#     MOCK_OK_STDOUT.
#   MOCK_MODE == success: api calls always succeed (MOCK_WARN_STDERR is
#     appended to stderr first, for the no-mixing contract).
# Every invocation is appended to MOCK_GH_CALLS as {"attempt", "argv"} so
# tests can pin the attempt count and per-attempt argument invariance.
# `gh repo view` is answered for actions that resolve the target.
write_retry_mock_gh() {
  mkdir -p "$FIXTURE_DIR/bin"
  cat > "$FIXTURE_DIR/bin/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

argv = sys.argv[1:]

if argv[:2] == ["repo", "view"]:
    sys.stdout.write(os.environ.get("MOCK_REPO_VIEW", "u7chan/agent-harness\n"))
    sys.exit(0)

calls_log = os.environ.get("MOCK_GH_CALLS", "")
state_file = os.environ.get("MOCK_GH_STATE", "")

if argv[:1] != ["api"]:
    sys.stderr.write("unsupported mock command: " + " ".join(argv) + "\n")
    sys.exit(64)

try:
    with open(state_file, encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    state = {}
attempt = int(state.get("attempt", 0)) + 1
state["attempt"] = attempt
with open(state_file, "w", encoding="utf-8") as f:
    json.dump(state, f)

if calls_log:
    with open(calls_log, "a", encoding="utf-8") as f:
        f.write(json.dumps({"attempt": attempt, "argv": argv}, separators=(",", ":")) + "\n")


def succeed():
    warn = os.environ.get("MOCK_WARN_STDERR")
    if warn:
        sys.stderr.write(warn)
    sys.stdout.write(os.environ.get("MOCK_OK_STDOUT", '{"ok":true}\n'))
    sys.exit(0)


if os.environ.get("MOCK_MODE", "success") == "success":
    succeed()

fail_until = int(os.environ.get("MOCK_FAIL_UNTIL", "999999"))
if attempt <= fail_until:
    sys.stdout.write(os.environ.get("MOCK_FAIL_STDOUT", ""))
    sys.stderr.write(os.environ.get("MOCK_FAIL_STDERR", ""))
    sys.exit(int(os.environ.get("MOCK_FAIL_RC", "1")))

succeed()
PY
  chmod +x "$FIXTURE_DIR/bin/gh"

  # Retry backoff must be observable without waiting: log every sleep
  # argument instead of sleeping.
  cat > "$FIXTURE_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_SLEEP_LOG:?}"
SH
  chmod +x "$FIXTURE_DIR/bin/sleep"
}

# http.sh is the file under test: source the real common script (it enables
# set -euo pipefail, the same environment every action runs in).
use_http_sh() {
  source "$GH_ROOT/scripts/common/http.sh"
}

setup_retry_env() {
  export PATH="$FIXTURE_DIR/bin:$PATH"
  export MOCK_GH_STATE="$FIXTURE_DIR/gh-state.json" \
         MOCK_GH_CALLS="$FIXTURE_DIR/gh-calls.log" \
         MOCK_SLEEP_LOG="$FIXTURE_DIR/sleep.log"
  printf '{}\n' > "$MOCK_GH_STATE"
  : > "$MOCK_GH_CALLS"
  : > "$MOCK_SLEEP_LOG"
}

# invoke_gh_api <endpoint> <method> [extra args...] -- calls call_gh_api and
# leaves rc / stdout / stderr in the given files.
invoke_gh_api() {
  local endpoint="$1"
  local method="$2"
  shift 2
  call_gh_api "$endpoint" "$method" "$@" \
    > "$FIXTURE_DIR/out.txt" 2> "$FIXTURE_DIR/err.txt" && rc=0 || rc=$?
}

# The core reproduction (Issue #176): the mock prints an error-body JSON to
# stdout and the "HTTP 503" diagnostic to stderr (exactly like real gh on a
# 5xx). The transient failure must be detected via stderr, retried with the
# exponential backoff, and succeed on the third attempt - and the returned
# stdout must stay the pure success JSON with no diagnostic mixed in.
test_stderr_503_retried_then_success() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure MOCK_FAIL_UNTIL=2 \
    MOCK_FAIL_STDOUT='{"message":"Service Unavailable"}
' \
    MOCK_FAIL_STDERR='gh: Service Unavailable (HTTP 503)
' \
    MOCK_OK_STDOUT='{"ok":true}
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "0" || return 1
  assert_eq "$(cat "$FIXTURE_DIR/out.txt")" '{"ok":true}' || return 1
  assert_eq "$(cat "$FIXTURE_DIR/err.txt")" "" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "3" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n2\n')" || return 1
)

# A permanently failing transient-style failure must stop at the retry cap:
# exactly GH_RETRY_MAX (3) attempts, backoff 1s then 2s, nothing on stdout,
# and only the sanitized diagnostic on stderr.
test_stderr_503_retry_cap_and_backoff() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"Service Unavailable"}
' \
    MOCK_FAIL_STDERR='gh: Service Unavailable (HTTP 503)
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "1" || return 1
  assert_eq "$(cat "$FIXTURE_DIR/out.txt")" "" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "3" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n2\n')" || return 1
  assert_contains "$(cat "$FIXTURE_DIR/err.txt")" "HTTP 503" || return 1
)

# (b) stderr-only communication error: real gh prints nothing to stdout for
# transport failures. The retry decision must not depend on stdout content.
test_stderr_only_conn_error_retried() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure MOCK_FAIL_UNTIL=1 \
    MOCK_FAIL_STDERR='Get "http://127.0.0.1:9/repos/x": dial tcp 127.0.0.1:9: connect: connection refused
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "0" || return 1
  assert_eq "$(cat "$FIXTURE_DIR/out.txt")" '{"ok":true}' || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "2" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n')" || return 1
)

# Permanent API errors (4xx) must never be retried even when the diagnostic
# names an HTTP status.
test_permanent_404_not_retried() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"Not Found"}
' \
    MOCK_FAIL_STDERR='gh: Not Found (HTTP 404)
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "1" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "1" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "" || return 1
  assert_contains "$(cat "$FIXTURE_DIR/err.txt")" "HTTP 404" || return 1
)

test_permanent_422_not_retried() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"Validation Failed","errors":[{"resource":"Issue","field":"title","code":"missing"}]}
' \
    MOCK_FAIL_STDERR='gh: Validation Failed (HTTP 422)
'

  invoke_gh_api "repos/u7chan/agent-harness/issues" "POST" --input /dev/null
  assert_eq "$rc" "1" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "1" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "" || return 1
)

# A failure with no recognizable transient signal is an unknown outcome: the
# request (a write, here) must not be automatically resent.
test_unknown_silent_failure_not_retried() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure MOCK_FAIL_STDOUT="" MOCK_FAIL_STDERR=""

  invoke_gh_api "repos/u7chan/agent-harness/issues/1/comments" "POST" --input /dev/null
  assert_eq "$rc" "1" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "1" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "" || return 1
  assert_eq "$(cat "$FIXTURE_DIR/err.txt")" "" || return 1
)

# Single-write settings stay honored: actions that must not auto-resend
# (comments.create, comments.delete, review-comments.delete, ...) pin
# GH_RETRY_MAX=1 around the write; a transient-looking write failure must
# then be attempted exactly once.
test_single_write_gh_retry_max_one() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export GH_RETRY_MAX=1
  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"Service Unavailable"}
' \
    MOCK_FAIL_STDERR='gh: Service Unavailable (HTTP 503)
'

  invoke_gh_api "repos/u7chan/agent-harness/issues/1/comments" "POST" --input /dev/null
  assert_eq "$rc" "1" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "1" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "" || return 1
)

# Retries must re-send the exact same arguments: endpoint, method, headers
# and extra flags are never mutated between attempts.
test_args_invariant_across_retries() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure MOCK_FAIL_UNTIL=2 \
    MOCK_FAIL_STDERR='gh: Service Unavailable (HTTP 503)
'

  invoke_gh_api "repos/u7chan/agent-harness/pulls" "GET" \
    -f "state=open" -f "per_page=5" -H "X-Custom-Trace: abc123"

  assert_eq "$rc" "0" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "3" || return 1

  local first_argv second_argv third_argv
  first_argv="$(jq -s '.[0].argv' "$MOCK_GH_CALLS")"
  second_argv="$(jq -s '.[1].argv' "$MOCK_GH_CALLS")"
  third_argv="$(jq -s '.[2].argv' "$MOCK_GH_CALLS")"
  assert_eq "$second_argv" "$first_argv" || return 1
  assert_eq "$third_argv" "$first_argv" || return 1
  assert_json_eq "$first_argv" 'index("repos/u7chan/agent-harness/pulls") != null' "true" || return 1
  assert_json_eq "$first_argv" 'index("state=open") != null' "true" || return 1
  assert_json_eq "$first_argv" 'index("per_page=5") != null' "true" || return 1
  assert_json_eq "$first_argv" 'index("X-Custom-Trace: abc123") != null' "true" || return 1
)

# Rate-limit failures keep being detected on the stdout error body and are
# retried up to the cap.
test_rate_limit_retried() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"API rate limit exceeded for installation ID 123.","documentation_url":"https://docs.github.com/rest"}
' \
    MOCK_FAIL_STDERR='gh: API rate limit exceeded for installation ID 123. (HTTP 403)
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "1" || return 1
  assert_eq "$(jq -s 'length' "$MOCK_GH_CALLS")" "3" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n2\n')" || return 1
  assert_contains "$(cat "$FIXTURE_DIR/err.txt")" "rate limit" || return 1
)

# A successful call that also wrote to gh stderr must return the stdout JSON
# untouched; the diagnostic goes to stderr only and never into the result.
test_success_json_not_mixed_with_stderr_warning() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  export MOCK_MODE=success \
    MOCK_WARN_STDERR='gh: warning: an example diagnostic
'

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "0" || return 1
  assert_eq "$(cat "$FIXTURE_DIR/out.txt")" '{"ok":true}' || return 1
  assert_contains "$(cat "$FIXTURE_DIR/err.txt")" "an example diagnostic" || return 1
  if grep -q '{"ok":true}' "$FIXTURE_DIR/err.txt"; then
    echo "success JSON leaked into stderr"
    return 1
  fi
)

# Forwarded diagnostics are redacted (secrets stripped) and size-bounded:
# raw gh stderr is never transcribed verbatim. A 2,000-byte flood containing
# a GitHub token, a URL query secret and an Authorization header must reach
# the caller as at most GH_DIAG_MAX_BYTES bytes with the secrets gone and
# the retry signal ("HTTP 503") preserved.
test_failure_diag_sanitized_and_size_bounded() (
  setup_fixture
  trap teardown_fixture EXIT
  write_retry_mock_gh
  use_http_sh
  setup_retry_env

  # A 2000-byte flood tail exercises the GH_DIAG_MAX_BYTES=500 bound on
  # the forwarded diagnostic.
  local flood=""
  flood="$(head -c 2000 /dev/zero | tr '\0' 'y')"
  export MOCK_MODE=failure
  export MOCK_FAIL_STDERR="gh: Service Unavailable (HTTP 503)
GET https://api.github.com/repos/u7chan/agent-harness?access_token=ghp_SUPERSECRETTOKEN1234567890&per_page=1
Authorization: Bearer ghp_ANOTHERSECRETTOKEN0987654321
${flood}
"

  invoke_gh_api "repos/u7chan/agent-harness" "GET"
  assert_eq "$rc" "1" || return 1

  local err_text diag_bytes
  err_text="$(cat "$FIXTURE_DIR/err.txt")"
  diag_bytes="$(printf '%s' "$err_text" | wc -c)"
  if [ "$diag_bytes" -gt 500 ]; then
    echo "forwarded diagnostic not size-bounded: $diag_bytes bytes"
    return 1
  fi
  assert_contains "$err_text" "HTTP 503" || return 1
  assert_contains "$err_text" "[REDACTED]" || return 1
  if printf '%s' "$err_text" | grep -q 'SUPERSECRETTOKEN\|SUPERSECRET\|ANOTHERSECRET'; then
    echo "secret leaked into the forwarded diagnostic"
    return 1
  fi
)

# End-to-end through the dispatcher: repo.get retries a 503 on stderr three
# times (repo view target resolution excluded) and reports API_ERROR in the
# envelope; the envelope stays valid JSON (no raw stderr merged into it).
test_repo_get_end_to_end_retry() (
  setup_fixture
  trap teardown_fixture EXIT
  cp "$GH_ROOT/scripts/actions/repo.get.sh" "$FIXTURE_DIR/scripts/actions/repo.get.sh"
  chmod +x "$FIXTURE_DIR/scripts/actions/repo.get.sh"
  write_retry_mock_gh
  setup_retry_env
  export GH_TEST_AUTH_RESULT=0

  export MOCK_MODE=failure \
    MOCK_FAIL_STDOUT='{"message":"Service Unavailable"}
' \
    MOCK_FAIL_STDERR='gh: Service Unavailable (HTTP 503)
'

  local input_file output rc
  input_file="$(mktemp /tmp/gh-http-retry-input-XXXXXX)"
  printf '{}\n' > "$input_file"
  output="$(fixture_gh "repo.get" "$input_file" 2>/dev/null)" && rc=0 || rc=$?
  rm -f "$input_file"

  assert_eq "$rc" "1" || return 1
  assert_json_eq "$output" '.status' "failed" || return 1
  assert_json_eq "$output" '.error.code' "API_ERROR" || return 1
  assert_eq "$(jq -s '[.[] | select(.argv[0] == "api")] | length' "$MOCK_GH_CALLS")" "3" || return 1
  assert_eq "$(cat "$MOCK_SLEEP_LOG")" "$(printf '1\n2\n')" || return 1
)

main() {
  echo "=== http.sh retry (stderr transient detection) contract tests ==="

  run_test test_stderr_503_retried_then_success
  run_test test_stderr_503_retry_cap_and_backoff
  run_test test_stderr_only_conn_error_retried
  run_test test_permanent_404_not_retried
  run_test test_permanent_422_not_retried
  run_test test_unknown_silent_failure_not_retried
  run_test test_single_write_gh_retry_max_one
  run_test test_args_invariant_across_retries
  run_test test_rate_limit_retried
  run_test test_success_json_not_mixed_with_stderr_warning
  run_test test_failure_diag_sanitized_and_size_bounded
  run_test test_repo_get_end_to_end_retry

  print_summary
}

main
