#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <reviews.create|review-comments.reply> <payload-file>" >&2
  exit 2
}

fail() {
  echo "INVALID: $1" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage

action="$1"
payload_file="$2"

[ -f "$payload_file" ] || fail "payload file does not exist"
jq empty "$payload_file" >/dev/null 2>&1 || fail "payload must be valid JSON"

case "$action" in
  reviews.create|review-comments.reply) ;;
  *) usage ;;
esac

texts="$(jq -r '
  if $action == "reviews.create" then
    [.body, (.comments[]?.body)]
  else
    [.body]
  end
  | .[] // empty
' --arg action "$action" "$payload_file")"

[ -n "$texts" ] || fail "body must not be empty"

if grep -Fq '\n' <<<"$texts"; then
  fail 'body contains a literal \n sequence'
fi

if grep -Eq '\((Optional|Required)\)|（(任意|必須)）' <<<"$texts"; then
  fail "severity labels must not include requirement supplements"
fi

if grep -Eq '\{(Blocker\|Nit\|Consider\|FYI|問題と根拠|発生条件と影響|必要な場合だけ修正案|件数|解消を確認できた根拠|元のラベル|残っている条件と影響|判定できない理由|full SHA|n|意味で要約した確認範囲)\}' <<<"$texts"; then
  fail "body contains an unresolved template variable"
fi

if grep -Eq '(^|[^[:alnum:]_.])((pr(\.[a-z-]+)*)|comments|reviews|review-comments|review-threads|reviewers)\.(read|create|reply|resolve|unresolve|update|delete|request|remove)([^[:alnum:]_.]|$)' <<<"$texts"; then
  fail "body contains a raw action name"
fi

if grep -Eq 'Verification|Remaining:[[:space:]]*none|Skipped candidates|(Blocker|Nit|Consider|FYI)(:|[[:space:]])+0(件|[^0-9]|$)' <<<"$texts"; then
  fail "body contains prohibited audit details"
fi

if [ "$action" = "reviews.create" ]; then
  event="$(jq -r '.event // empty' "$payload_file")"
  [ "$event" = "COMMENT" ] || fail "event must be COMMENT"

  commit_id="$(jq -r '.commit_id // empty' "$payload_file")"
  [[ "$commit_id" =~ ^[0-9a-fA-F]{40}$ ]] || fail "commit_id must be a full commit SHA"

  jq -e '
    (.body | type == "string" and length > 0) and
    ([.comments[]?.body | type == "string" and test("^\\*\\*(Blocker|Nit|Consider|FYI)\\*\\*: ")] | all)
  ' "$payload_file" >/dev/null || fail "inline findings must start with an exact severity label"

  review_body="$(jq -r '.body' "$payload_file")"
  first_line="${review_body%%$'\n'*}"
  has_blocker="$(jq '[.body, .comments[]?.body] | any(.[]; . != null and test("(^|\\n)\\*\\*Blocker\\*\\*: "))' "$payload_file")"

  if [ "$first_line" = "**LGTM**" ]; then
    [ "$has_blocker" = "false" ] || fail "LGTM cannot coexist with a Blocker finding"
  elif [[ "$first_line" =~ ^\*\*Blocker:\ [1-9][0-9]*件\*\*$ ]]; then
    :
  else
    fail "review body must start with LGTM or a positive Blocker count"
  fi
else
  jq -e '
    .body | test(
      "^(\\*\\*Resolved\\*\\*: |\\*\\*(Partial|Unresolved)\\*\\* \\(\\*\\*(Blocker|Nit|Consider|FYI)\\*\\*\\): |\\*\\*Unknown\\*\\*: )"
    )
  ' "$payload_file" >/dev/null || fail "reply body does not match a recheck template"
fi

echo "OK: $action payload is valid"
