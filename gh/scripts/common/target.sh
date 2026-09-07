#!/usr/bin/env bash
set -euo pipefail

# --- target resolution -------------------------------------------------------
# Reference contract (documented for the agent in gh/SKILL.md "Targets" and
# pinned by gh/tests/contract/target-resolve.sh):
#   - Accepted forms: 'owner/repo', and the GitHub URL forms
#     https://github.com/<owner>/<repo>[/pull/<n>|/issues/<n>].
#   - Issue/PR numbers must be positive integers. 0, negatives, decimals
#     and non-numeric values fail with TARGET_ERROR at the action before any
#     API call - both in URL number segments and in the number input.
#   - A query string, a fragment, trailing slashes, and any path after the
#     issue/PR number (e.g. /pull/12/files, /pull/12/commits) are URL
#     decorations for the same resource: they are normalized away and the
#     envelope target.url is the canonical, decoration-free URL.
#   - Any other host, any path that is not one of the accepted forms, and
#     owner-only URLs (https://github.com/<owner> with no repository, e.g.
#     https://github.com/octocat) fail resolution (no API call). The
#     owner/repo spelling given in the reference is kept in
#     target.repository.

# GitHub owner/repo segments are ASCII letters and digits plus '.', '-',
# '_'. Empty segments and segments that are exactly '.' or '..' would
# change which API path the resolved repository points at and are
# rejected; dots inside a name (e.g. release..notes) do not affect path
# joining and stay accepted, matching the pre-#180 behavior.
valid_repo_segment() {
  local segment="$1"

  case "$segment" in
    "" | "." | ".." | *[!A-Za-z0-9._-]*)
      return 1
      ;;
  esac
  return 0
}

# Issue/PR numbers are [1-9][0-9]*: no sign, no decimal point, no leading
# zeros.
valid_positive_number() {
  local value="$1"

  [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

resolve_target() {
  local reference="${1:-}"
  local number="${2:-}"
  local expected_type="${3:-}"

  local owner="" repo="" type_str="" num="" url=""

  if [ -n "$reference" ]; then
    if [[ "$reference" == https://github.com/* ]]; then
      # A fragment or a query string never addresses a different resource,
      # so both are stripped before parsing; trailing slashes are path
      # decoration with the same property.
      local path
      path="${reference#https://github.com/}"
      path="${path%%#*}"
      path="${path%%\?*}"
      while [[ "$path" == */ ]]; do
        path="${path%/}"
      done

      # A URL must carry the repository: an owner-only path would otherwise
      # reuse the owner as the repo (octocat -> octocat/octocat) and could
      # reach API paths of a repository that was never named.
      if [[ "$path" != */* ]]; then
        echo "Invalid reference URL: $reference. Expected https://github.com/<owner>/<repo>[/pull/<n>|/issues/<n>]; an owner alone cannot identify a repository." >&2
        return 1
      fi

      owner="${path%%/*}"
      path="${path#*/}"
      repo="${path%%/*}"
      # Everything after the repo segment (if any) is the resource path.
      if [[ "$path" == */* ]]; then
        path="${path#*/}"
      else
        path=""
      fi

      if ! valid_repo_segment "$owner" || ! valid_repo_segment "$repo"; then
        echo "Invalid reference URL: $reference. Expected https://github.com/<owner>/<repo>[/pull/<n>|/issues/<n>] with a valid GitHub owner/repo." >&2
        return 1
      fi

      case "$path" in
        "")
          type_str="repository"
          ;;
        pull/* | issues/*)
          local kind num_tail
          kind="${path%%/*}"
          num_tail="${path#*/}"
          num="${num_tail%%/*}"
          # Any path beyond the number (e.g. /files, /commits) is GitHub UI
          # navigation for the same issue/PR; it cannot change the target,
          # so it is dropped and the envelope url stays canonical.
          if ! valid_positive_number "$num"; then
            echo "Invalid reference URL: $reference. Issue/PR numbers must be positive integers." >&2
            return 1
          fi
          if [ "$kind" = "pull" ]; then
            type_str="pull_request"
          else
            type_str="issue"
          fi
          ;;
        *)
          echo "Invalid reference URL: $reference. Expected https://github.com/<owner>/<repo> or https://github.com/<owner>/<repo>/pull/<n> (or /issues/<n>)." >&2
          return 1
          ;;
      esac

      url="https://github.com/$owner/$repo"
      if [ "$type_str" = "pull_request" ]; then
        url="$url/pull/$num"
      elif [ "$type_str" = "issue" ]; then
        url="$url/issues/$num"
      fi
    elif [[ "$reference" =~ ^[^/]+/[^/]+$ ]]; then
      owner="${reference%%/*}"
      repo="${reference##*/}"

      if ! valid_repo_segment "$owner" || ! valid_repo_segment "$repo"; then
        echo "Invalid reference: $reference. Expected 'owner/repo' with a valid GitHub owner/repo." >&2
        return 1
      fi

      if [ -n "$number" ]; then
        if ! valid_positive_number "$number"; then
          echo "Invalid number: $number. Issue/PR numbers must be positive integers." >&2
          return 1
        fi
        num="$number"

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
      else
        type_str="repository"
        url="https://github.com/$owner/$repo"
      fi
    else
      echo "Invalid reference: $reference. Provide a GitHub URL (https://github.com/<owner>/<repo>[/pull/<n>|/issues/<n>]) or 'owner/repo'." >&2
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

resolve_pr_target() {
  local reference="${1:-}"
  local number="${2:-}"

  if [ -n "$reference" ] || [ -n "$number" ]; then
    if [ -n "$reference" ]; then
      resolve_target "$reference" "$number" "pull_request" || return 1
    else
      # Number-only references are validated before any gh call (the
      # repository discovery included): an invalid number must never reach
      # an API path or trigger a write.
      if ! valid_positive_number "$number"; then
        echo "Invalid PR number: $number. PR numbers must be positive integers." >&2
        return 1
      fi

      local repo_target
      repo_target="$(resolve_target)" || return 1
      local owner_repo
      owner_repo="$(echo "$repo_target" | jq -r '.repository')"
      local url="https://github.com/$owner_repo/pull/$number"
      jq -n \
        --arg repo "$owner_repo" \
        --arg number "$number" \
        --arg url "$url" \
        '{
          type: "pull_request",
          repository: $repo,
          number: ($number | tonumber),
          url: $url
        }'
    fi
  else
    resolve_pr_from_branch "" || return 1
  fi
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
