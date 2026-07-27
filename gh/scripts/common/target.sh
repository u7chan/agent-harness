#!/usr/bin/env bash
set -euo pipefail

resolve_target() {
  local reference="${1:-}"
  local number="${2:-}"
  local expected_type="${3:-}"

  local owner="" repo="" type_str="" num="" url=""

  if [ -n "$reference" ]; then
    if [[ "$reference" == https://github.com/* ]]; then
      local path
      path="${reference#https://github.com/}"
      owner="${path%%/*}"
      path="${path#*/}"
      repo="${path%%/*}"

      case "$path" in
        */issues/*)
          type_str="issue"
          num="${path##*/}"
          ;;
        */pull/*)
          type_str="pull_request"
          num="${path##*/}"
          ;;
        *)
          type_str="repository"
          num=""
          ;;
      esac

      url="$reference"
    elif [[ "$reference" =~ ^[^/]+/[^/]+$ ]]; then
      owner="${reference%%/*}"
      repo="${reference##*/}"

      if [ -n "$number" ]; then
        if [ "$expected_type" = "issue" ]; then
          type_str="issue"
          url="https://github.com/$owner/$repo/issues/$number"
        elif [ "$expected_type" = "pull_request" ]; then
          type_str="pull_request"
          url="https://github.com/$owner/$repo/pull/$number"
        else
          echo "Cannot determine target type: expected_type is required when providing owner/repo and number." >&2
          return 1
        fi
        num="$number"
      else
        type_str="repository"
        url="https://github.com/$owner/$repo"
      fi
    else
      echo "Invalid reference: $reference. Provide a GitHub URL or 'owner/repo'." >&2
      return 1
    fi
  else
    local name_with_owner
    name_with_owner="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || {
      echo "No target specified and could not determine the current repository." >&2
      return 1
    }
    owner="${name_with_owner%%/*}"
    repo="${name_with_owner##*/}"
    type_str="repository"
    url="https://github.com/$name_with_owner"
  fi

  if [ -n "$expected_type" ] && [ -n "$type_str" ] && [ "$type_str" != "$expected_type" ]; then
    echo "Target type mismatch: expected '$expected_type', got '$type_str'." >&2
    return 1
  fi

  jq -n \
    --arg type "$type_str" \
    --arg repo "$owner/$repo" \
    --arg number "${num:-}" \
    --arg url "$url" \
    '{
      type: $type,
      repository: $repo,
      number: (if $number == "" then null else ($number | tonumber) end),
      url: $url
    }'
}

resolve_pr_from_branch() {
  local branch="${1:-}"

  if [ -z "$branch" ]; then
    branch="$(gh pr view --json headRefName --jq '.headRefName' 2>/dev/null)" || {
      echo "No PR found for the current branch. Specify a PR URL or number." >&2
      return 1
    }
  fi

  local pr_json
  pr_json="$(gh pr view "$branch" --json number,url,baseRefName,headRefName 2>/dev/null)" || {
    echo "No open PR found for branch: $branch." >&2
    return 1
  }

  local number url
  number="$(echo "$pr_json" | jq -r '.number')"
  url="$(echo "$pr_json" | jq -r '.url')"

  local owner repo
  local path="${url#*github.com/}"
  owner="${path%%/*}"
  path="${path#*/}"
  repo="${path%%/*}"

  jq -n \
    --arg repo "$owner/$repo" \
    --arg number "$number" \
    --arg url "$url" \
    '{
      type: "pull_request",
      repository: $repo,
      number: ($number | tonumber),
      url: $url
    }'
}
