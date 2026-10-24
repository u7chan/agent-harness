#!/usr/bin/env bash
set -euo pipefail

# Run the reply examples in references/posting-api.md without touching GitHub:
# temporary HOME + mock gh CLI, real dispatcher, no network.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REVIEW_DIR/.." && pwd)"
POSTING_REFERENCE="$REVIEW_DIR/references/posting-api.md"

TMP_DIR="$(mktemp -d /tmp/review-reply-smoke-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
HOME_DIR="$TMP_DIR/home"
MOCK_DIR="$TMP_DIR/mock"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$HOME_DIR" "$MOCK_DIR" "$BIN_DIR"
NORMAL_BODY="$TMP_DIR/normal-reply.md"
RECHECK_BODY="$TMP_DIR/recheck-reply.md"

# Quotes, backslashes, Japanese text, and the trailing newline must survive.
cat > "$NORMAL_BODY" <<'EOF'
フィードバック: "double quote" と 'single quote'、backslash C:\work\review をそのまま返します。
2 行目: 日本語の本文です。
末尾の改行も保持します。
EOF
{ printf '**Resolved**: '; cat "$NORMAL_BODY"; } > "$RECHECK_BODY"

cat > "$BIN_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
d="${MOCK_GH_DIR:?}"
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then printf 'github.com\n  ✓ Logged in to github.com account smoke\n'; exit 0; fi
[ "${1:-}" = api ] || exit 64
shift
e=""; input=""
while [ "$#" -gt 0 ]; do case "$1" in
  --input) input="$2"; shift 2;; -H|--method|-f|--jq) shift 2;; --*) shift;; *) [ -z "$e" ] && e="$1"; shift;; esac; done
u="https://github.com/acme/widgets/pull/7#discussion_r2001"
c() { jq -n --rawfile b "$1" --arg u "$u" '{id:2001,body:$b,html_url:$u,pull_request_url:"https://api.github.com/repos/acme/widgets/pulls/7",in_reply_to_id:1001,user:{login:"tester"}}'; }
case "$e" in
  user) printf 'tester\n';;
  repos/acme/widgets/pulls/7) printf '{"url":"https://api.github.com/repos/acme/widgets/pulls/7"}\n';;
  repos/acme/widgets/pulls/comments/1001) printf '{"id":1001,"pull_request_url":"https://api.github.com/repos/acme/widgets/pulls/7","user":{"login":"maintainer"}}\n';;
  repos/acme/widgets/pulls/7/comments)
    if [ -n "$input" ]; then jq -j '.body' "$input" > "$d/posted"; c "$d/posted" > "$d/created"; cat "$d/created"; else printf '[]\n'; fi;;
  repos/acme/widgets/pulls/comments/2001)
    if [ "${MOCK_GH_MISMATCH:-0}" = 1 ]; then printf 'different body\n' > "$d/mismatch"; c "$d/mismatch"; else cat "$d/created"; fi;;
  *) exit 64;;
esac
MOCK
chmod +x "$BIN_DIR/gh"

fail() { echo "FAIL: $*" >&2; exit 1; }
field() { printf '%s\n' "$1" | tail -n 1 | jq -r "$2"; }
expect() { [ "$(field "$1" "$2")" = "$3" ] || fail "$4: $1"; }

# The marker is pinned by review/tests/run.sh; the block itself may change.
extract_example() {
  awk -v m="$1" '/^```bash/{f=1;b="";next} /^```$/&&f{if(index(b,m)){printf "%s",b;exit}f=0;next} f{b=b $0 "\n"}' "$POSTING_REFERENCE" > "$2"
}

render_example() {
  extract_example "$1" "$TMP_DIR/example.raw"
  [ -s "$TMP_DIR/example.raw" ] || fail "example marker not found: $1"
  sed -e 's#<owner>#acme#g' -e 's#<repo>#widgets#g' -e 's#<number>#7#g' -e 's#<root-comment-id>#1001#g' \
    -e "s#/tmp/<topic>-reply.md#$NORMAL_BODY#g" -e "s#/tmp/<topic>-recheck.md#$RECHECK_BODY#g" \
    -e "s#/tmp/<topic>-reply.json#$TMP_DIR/reply.json#g" "$TMP_DIR/example.raw" > "$2"
}

run_example() {
  rm -rf "$MOCK_DIR"; mkdir -p "$MOCK_DIR"
  ( cd "$REPO_ROOT"; HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" PATH="$BIN_DIR:$PATH" MOCK_GH_DIR="$MOCK_DIR" MOCK_GH_MISMATCH="${2:-0}" bash "$1" )
}

assert_body() {
  [ -s "$MOCK_DIR/posted" ] && cmp -s "$MOCK_DIR/posted" "$2" || fail "$1 body did not round-trip"
}

NORMAL_EXAMPLE="$TMP_DIR/normal-example.sh"
RECHECK_EXAMPLE="$TMP_DIR/recheck-example.sh"
render_example '# 通常のフィードバック返信（再チェック分類ではない）' "$NORMAL_EXAMPLE"
render_example '# 再チェック分類返信（テンプレート検査あり）' "$RECHECK_EXAMPLE"

normal="$(run_example "$NORMAL_EXAMPLE" 0)" || fail "normal example failed"
expect "$normal" '.status' ok normal
! printf '%s\n' "$normal" | grep -q 'payload is valid' || fail "normal example ran the validator"
assert_body "normal example" "$NORMAL_BODY"

recheck="$(run_example "$RECHECK_EXAMPLE" 0)" || fail "recheck example failed"
printf '%s\n' "$recheck" | grep -q 'OK: review-comments.reply payload is valid' || fail "recheck validator did not run"
expect "$recheck" '.status' ok recheck
assert_body "recheck example" "$RECHECK_BODY"

INVALID_EXAMPLE="$TMP_DIR/invalid-example.sh"
sed 's#--argjson reply_to 1001#--arg reply_to invalid#' "$NORMAL_EXAMPLE" > "$INVALID_EXAMPLE"
invalid="$(run_example "$INVALID_EXAMPLE" 0)" || fail "invalid example failed"
expect "$invalid" '.status + ":" + .error.code' 'failed:TYPE_MISMATCH' invalid
[ ! -e "$MOCK_DIR/posted" ] || fail "invalid input reached POST"

GRANT_EXAMPLE="$TMP_DIR/grant-example.sh"
sed 's#grant: "write"#grant: "read"#' "$NORMAL_EXAMPLE" > "$GRANT_EXAMPLE"
grant="$(run_example "$GRANT_EXAMPLE" 0)" || fail "grant example failed"
expect "$grant" '.status + ":" + .error.code' 'failed:GRANT_INSUFFICIENT' grant
[ ! -e "$MOCK_DIR/posted" ] || fail "insufficient grant reached POST"

# POST succeeds, but the re-read body differs: the action must report
# unknown_outcome even though its data may carry the created id and URL.
unknown="$(run_example "$NORMAL_EXAMPLE" 1)" || fail "unknown-outcome example failed"
expect "$unknown" '.status' unknown_outcome unknown
[ "$unknown" != "$normal" ] || fail "unknown_outcome was rendered like success"

echo "PASS: reply invocation examples"
