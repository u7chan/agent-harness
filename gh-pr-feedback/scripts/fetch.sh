#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [pr-number-or-url]" >&2
  exit 2
}

[ "$#" -le 1 ] || usage

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

result="$(gh api graphql \
  -f query='query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$number) {
        url
        comments(first:100) {
          pageInfo { hasNextPage }
          nodes { id author { login } body createdAt url }
        }
        reviews(first:100) {
          pageInfo { hasNextPage }
          nodes { id author { login } body state submittedAt url }
        }
        reviewThreads(first:100) {
          pageInfo { hasNextPage }
          nodes {
            id
            isResolved
            comments(first:100) {
              pageInfo { hasNextPage }
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
  -F number="$number")"

if jq -e '
  .data.repository.pullRequest as $pr
  | $pr.comments.pageInfo.hasNextPage
    or $pr.reviews.pageInfo.hasNextPage
    or $pr.reviewThreads.pageInfo.hasNextPage
    or any($pr.reviewThreads.nodes[]?; .comments.pageInfo.hasNextPage)
' >/dev/null <<<"$result"; then
  echo "Incomplete feedback result: GitHub returned more than 100 items; pagination is required." >&2
  exit 1
fi

printf '%s\n' "$result"
