#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the reply examples in references/posting-api.md without touching
# GitHub. The examples are extracted from the document, rendered with fixture
# identifiers, and run from a temporary fixture root. The fixture keeps the
# real dispatcher and substitutes only the external `gh` CLI, so request
# validation, grant checks, payload construction, and post-write verification
# stay on the production path. A temporary HOME keeps the real gh config out
# of the fixture.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REVIEW_DIR/.." && pwd)"
POSTING_REFERENCE="$REVIEW_DIR/references/posting-api.md"

TMP_DIR="$(mktemp -d /tmp/review-reply-smoke-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

HOME_DIR="$TMP_DIR/home"
FIXTURE_DIR="$TMP_DIR/fixture"
MOCK_DIR="$TMP_DIR/mock"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$HOME_DIR" "$FIXTURE_DIR" "$MOCK_DIR" "$BIN_DIR"

# The fixture root mirrors the paths used by the documented commands.
ln -s "$REPO_ROOT/gh" "$FIXTURE_DIR/gh"
ln -s "$REPO_ROOT/review" "$FIXTURE_DIR/review"

NORMAL_BODY="$TMP_DIR/normal-reply.md"
RECHECK_BODY="$TMP_DIR/recheck-reply.md"

# Quotes, backslashes, Japanese text, and both trailing and embedded newlines
# must survive payload construction and the reply action's byte comparison.
cat > "$NORMAL_BODY" <<'EOF'
フィードバック: "double quote" と 'single quote'、backslash C:\work\review をそのまま返します。
2 行目: 日本語の本文です。
末尾の改行も保持します。
EOF

cat > "$RECHECK_BODY" <<'EOF'
**Resolved**: 引用 "double quote" と 'single quote'、backslash C:\work\review、日本語をそのまま返します。
2 行目: 末尾の改行も保持します。
EOF

cat > "$BIN_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

MOCK_DIR="${MOCK_GH_DIR:?MOCK_GH_DIR is required}"
mkdir -p "$MOCK_DIR"
printf '%s\n' "$*" >> "$MOCK_DIR/calls.log"

root_comment() {
  jq -n '{
    id: 1001,
    body: "root comment",
    html_url: "https://github.com/acme/widgets/pull/7#discussion_r1001",
    path: "review/SKILL.md",
    position: 3,
    line: 3,
    commit_id: "0123456789abcdef0123456789abcdef01234567",
    user: {login: "maintainer"},
    created_at: "2026-10-01T00:00:00Z",
    updated_at: "2026-10-01T00:00:00Z",
    author_association: "OWNER",
    pull_request_url: "https://api.github.com/repos/acme/widgets/pulls/7"
  }'
}

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  printf 'github.com\n  ✓ Logged in to github.com account smoke (keyring)\n'
  exit 0
fi

if [ "${1:-}" != "api" ]; then
  echo "unexpected gh invocation: $*" >&2
  exit 64
fi
shift

method="GET"
input_file=""
jq_filter=""
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H|--method|-f|--input)
      option="$1"
      shift
      [ "$#" -gt 0 ] || { echo "missing value for $option" >&2; exit 64; }
      if [ "$option" = "--method" ]; then
        method="$1"
      elif [ "$option" = "--input" ]; then
        input_file="$1"
      fi
      shift
      ;;
    --jq)
      shift
      [ "$#" -gt 0 ] || { echo "missing value for --jq" >&2; exit 64; }
      jq_filter="$1"
      shift
      ;;
    --*)
      shift
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

endpoint="${positional[0]:-}"

case "$endpoint" in
  user)
    printf 'tester\n'
    ;;
  repos/acme/widgets/pulls/7)
    jq -n '{url: "https://api.github.com/repos/acme/widgets/pulls/7"}'
    ;;
  repos/acme/widgets/pulls/comments/1001)
    root_comment
    ;;
  repos/acme/widgets/pulls/comments/2001)
    if [ -s "$MOCK_DIR/created-comment.json" ]; then
      cat "$MOCK_DIR/created-comment.json"
    else
      echo "mock reply 2001 does not exist" >&2
      exit 1
    fi
    ;;
  repos/acme/widgets/pulls/7/comments)
    if [ "$method" = "POST" ]; then
      count="$(cat "$MOCK_DIR/post-count" 2>/dev/null || echo 0)"
      count=$((count + 1))
      printf '%s\n' "$count" > "$MOCK_DIR/post-count"
      if [ "${MOCK_GH_POST_FAIL:-0}" = "1" ]; then
        echo "mock POST failure" >&2
        exit 1
      fi
      cp "$input_file" "$MOCK_DIR/posted-body.json"
      jq -n --slurpfile request "$input_file" '{
        id: 2001,
        body: $request[0].body,
        html_url: "https://github.com/acme/widgets/pull/7#discussion_r2001",
        path: "review/SKILL.md",
        position: 3,
        line: 3,
        commit_id: "0123456789abcdef0123456789abcdef01234567",
        in_reply_to_id: $request[0].in_reply_to,
        user: {login: "tester"},
        created_at: "2026-10-01T00:00:01Z",
        updated_at: "2026-10-01T00:00:01Z",
        author_association: "MEMBER",
        pull_request_url: "https://api.github.com/repos/acme/widgets/pulls/7"
      }' > "$MOCK_DIR/created-comment.json"
      cat "$MOCK_DIR/created-comment.json"
    elif [ "$method" = "GET" ]; then
      {
        root_comment
        if [ -s "$MOCK_DIR/created-comment.json" ]; then
          cat "$MOCK_DIR/created-comment.json"
        fi
      } | jq -s '.'
    else
      echo "unsupported method for comments endpoint: $method" >&2
      exit 64
    fi
    ;;
  *)
    echo "unsupported gh api endpoint: $endpoint" >&2
    exit 64
    ;;
esac
MOCK
chmod +x "$BIN_DIR/gh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

reset_mock() {
  rm -rf "$MOCK_DIR"
  mkdir -p "$MOCK_DIR"
  printf '0\n' > "$MOCK_DIR/post-count"
  : > "$MOCK_DIR/calls.log"
}

# Extract the fenced bash block that contains the given marker comment. The
# marker is pinned by review/tests/run.sh, so a changed or removed example is
# reported there before this smoke silently stops covering it.
extract_example() {
  local marker="$1"
  local output="$2"

  awk -v marker="$marker" '
    /^```bash[[:space:]]*$/ { in_block = 1; buf = ""; next }
    /^```[[:space:]]*$/ && in_block {
      if (index(buf, marker) > 0) {
        printf "%s", buf
        found = 1
        exit
      }
      in_block = 0
      next
    }
    in_block { buf = buf $0 "\n" }
    END { if (!found) exit 1 }
  ' "$POSTING_REFERENCE" > "$output"
}

render_example() {
  local marker="$1"
  local output="$2"
  local raw="$TMP_DIR/example.raw"

  extract_example "$marker" "$raw" || fail "example marker not found: $marker"
  sed \
    -e 's#<owner>#acme#g' \
    -e 's#<repo>#widgets#g' \
    -e 's#<number>#7#g' \
    -e 's#<root-comment-id>#1001#g' \
    -e "s#/tmp/reply.md#$NORMAL_BODY#g" \
    -e "s#/tmp/recheck.md#$RECHECK_BODY#g" \
    -e "s#/tmp/reply.json#$TMP_DIR/reply.json#g" \
    "$raw" > "$output"
}

run_example() {
  local script="$1"
  local post_fail="${2:-0}"

  reset_mock
  (
    cd "$FIXTURE_DIR"
    HOME="$HOME_DIR" \
      XDG_CONFIG_HOME="$HOME_DIR/.config" \
      PATH="$BIN_DIR:$PATH" \
      MOCK_GH_DIR="$MOCK_DIR" \
      MOCK_GH_POST_FAIL="$post_fail" \
      bash "$script"
  )
}

projection_field() {
  local output="$1"
  local filter="$2"

  printf '%s\n' "$output" | tail -n 1 | jq -r "$filter"
}

assert_post_body() {
  local name="$1"
  local expected_file="$2"

  [ -s "$MOCK_DIR/posted-body.json" ] || fail "$name did not POST a body"
  jq -j '.body' "$MOCK_DIR/posted-body.json" > "$TMP_DIR/posted-body.txt"
  cmp -s "$TMP_DIR/posted-body.txt" "$expected_file" || \
    fail "$name body did not round-trip byte-for-byte"
}

assert_no_post() {
  local name="$1"
  local count

  count="$(cat "$MOCK_DIR/post-count")"
  [ "$count" = "0" ] || fail "$name performed $count POST request(s)"
}

NORMAL_EXAMPLE="$TMP_DIR/normal-example.sh"
RECHECK_EXAMPLE="$TMP_DIR/recheck-example.sh"
render_example '# 通常のフィードバック返信（再チェック分類ではない）' "$NORMAL_EXAMPLE"
render_example '# 再チェック分類返信（テンプレート検査あり）' "$RECHECK_EXAMPLE"

# 1. The normal feedback example posts the exact body. The body intentionally
# does not match the recheck template, proving the validator is not invoked.
normal_output="$(run_example "$NORMAL_EXAMPLE" 0)" || fail "normal example failed"
[ "$(projection_field "$normal_output" '.status')" = "ok" ] || \
  fail "normal example did not return ok: $normal_output"
[ "$(projection_field "$normal_output" '.id')" = "2001" ] || \
  fail "normal example did not project the comment id: $normal_output"
[ "$(projection_field "$normal_output" '.url')" = "https://github.com/acme/widgets/pull/7#discussion_r2001" ] || \
  fail "normal example did not project the comment URL: $normal_output"
[ "$(projection_field "$normal_output" '.error')" = "null" ] || \
  fail "normal example projected an error on success: $normal_output"
case "$normal_output" in
  *"payload is valid"*) fail "normal example ran the recheck validator" ;;
esac
assert_post_body "normal example" "$NORMAL_BODY"
NORMAL_SUCCESS_OUTPUT="$normal_output"

# 2. The recheck example runs the validator and posts the exact body.
recheck_output="$(run_example "$RECHECK_EXAMPLE" 0)" || fail "recheck example failed"
case "$recheck_output" in
  *"OK: review-comments.reply payload is valid"*) ;;
  *) fail "recheck example did not run the validator: $recheck_output" ;;
esac
[ "$(projection_field "$recheck_output" '.status')" = "ok" ] || \
  fail "recheck example did not return ok: $recheck_output"
assert_post_body "recheck example" "$RECHECK_BODY"

# 3. Invalid input fails before any write.
INVALID_EXAMPLE="$TMP_DIR/invalid-example.sh"
sed 's#--argjson reply_to 1001#--arg reply_to invalid#' "$NORMAL_EXAMPLE" > "$INVALID_EXAMPLE"
invalid_output="$(run_example "$INVALID_EXAMPLE" 0)" || fail "invalid example did not produce an envelope"
[ "$(projection_field "$invalid_output" '.status')" = "failed" ] || \
  fail "invalid input was not failed: $invalid_output"
[ "$(projection_field "$invalid_output" '.error.code')" = "TYPE_MISMATCH" ] || \
  fail "invalid input did not report TYPE_MISMATCH: $invalid_output"
assert_no_post "invalid input"
[ "$(wc -l < "$MOCK_DIR/calls.log")" -eq 0 ] || fail "invalid input reached gh"

# 4. A read grant is not enough for a write action.
GRANT_EXAMPLE="$TMP_DIR/grant-example.sh"
sed 's#grant: "write"#grant: "read"#' "$NORMAL_EXAMPLE" > "$GRANT_EXAMPLE"
grant_output="$(run_example "$GRANT_EXAMPLE" 0)" || fail "grant example did not produce an envelope"
[ "$(projection_field "$grant_output" '.status')" = "failed" ] || \
  fail "insufficient grant was not failed: $grant_output"
[ "$(projection_field "$grant_output" '.error.code')" = "GRANT_INSUFFICIENT" ] || \
  fail "insufficient grant did not report GRANT_INSUFFICIENT: $grant_output"
assert_no_post "insufficient grant"

# 5. An unverified write is reported as unknown_outcome, not as success, and
# the action does not re-POST in the same run.
unknown_output="$(run_example "$NORMAL_EXAMPLE" 1)" || fail "unknown-outcome example did not produce an envelope"
[ "$(projection_field "$unknown_output" '.status')" = "unknown_outcome" ] || \
  fail "unverified write was not reported as unknown_outcome: $unknown_output"
[ "$(projection_field "$unknown_output" '.id')" = "null" ] || \
  fail "unknown_outcome exposed a comment id as success: $unknown_output"
[ "$(projection_field "$unknown_output" '.url')" = "null" ] || \
  fail "unknown_outcome exposed a comment URL as success: $unknown_output"
[ "$unknown_output" != "$NORMAL_SUCCESS_OUTPUT" ] || \
  fail "unknown_outcome was rendered exactly like success"
[ "$(cat "$MOCK_DIR/post-count")" = "1" ] || \
  fail "unknown_outcome re-POSTed in the same run"

echo "PASS: reply invocation examples"
