#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [pr-number-or-url]" >&2
  exit 2
fi

reference="${1:-}"
gh auth status >/dev/null
if [ -n "$reference" ]; then
  pr_url="$(gh pr view "$reference" --json url --jq .url)"
else
  pr_url="$(gh pr view --json url --jq .url)"
fi
path="${pr_url#*github.com/}"
owner="${path%%/*}"
path="${path#*/}"
repo="${path%%/*}"
number="${pr_url##*/}"

gh api graphql \
  -f query='query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$number) {
        url
        comments(first:100) { nodes { id author { login } body createdAt url } }
        reviews(first:100) { nodes { id author { login } body state submittedAt url } }
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            comments(first:100) {
              nodes {
                databaseId
                author { login }
                body
                path
                line
                originalLine
                createdAt
                url
              }
            }
          }
        }
      }
    }
  }' \
  -f owner="$owner" \
  -f repo="$repo" \
  -F number="$number"
