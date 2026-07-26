#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <pr-number-or-url> (--inline <comment-id> | --conversation) <body-file>" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
reference="$1"
mode="$2"
shift 2

case "$mode" in
  --inline)
    [ "$#" -eq 2 ] || usage
    comment_id="$1"
    body_file="$2"
    ;;
  --conversation)
    [ "$#" -eq 1 ] || usage
    body_file="$1"
    ;;
  *) usage ;;
esac

[ -f "$body_file" ] || { echo "Reply body file not found: $body_file" >&2; exit 2; }
body="$(<"$body_file")"

gh auth status >/dev/null
pr_url="$(gh pr view "$reference" --json url --jq .url)"
path="${pr_url#*github.com/}"
owner="${path%%/*}"
path="${path#*/}"
repo="${path%%/*}"
number="${pr_url##*/}"

if [ "$mode" = "--inline" ]; then
  root_comment_id="$comment_id"
  declare -A seen_comment_ids=()

  while :; do
    if [ "${seen_comment_ids[$root_comment_id]+present}" = "present" ]; then
      echo "Could not resolve a top-level review comment: circular reply chain." >&2
      exit 1
    fi
    seen_comment_ids[$root_comment_id]=1

    parent_comment_id="$(
      gh api "repos/$owner/$repo/pulls/comments/$root_comment_id" \
        --jq '.in_reply_to_id // empty'
    )"
    [ -n "$parent_comment_id" ] || break
    root_comment_id="$parent_comment_id"
  done

  gh api --method POST "repos/$owner/$repo/pulls/$number/comments/$root_comment_id/replies" --raw-field body="$body"
else
  gh api --method POST "repos/$owner/$repo/issues/$number/comments" --raw-field body="$body"
fi
