#!/usr/bin/env bash
set -euo pipefail

# One connection/output contract for issue.get and both dependency writes.
# Do not follow cursors: expose the limit, and never treat an unseen member
# of a truncated connection as proof of absence.
ISSUE_DEPENDENCIES_QUERY='query($issueId: ID!) {
  node(id: $issueId) {
    __typename
    ... on Issue {
      id number repository { nameWithOwner }
      blockedBy(first: 100) {
        nodes { number title state url }
        totalCount pageInfo { hasNextPage }
      }
      blocking(first: 100) {
        nodes { number title state url }
        totalCount pageInfo { hasNextPage }
      }
    }
  }
}'

issue_node_id() {
  local issue="$1" number="$2"
  printf '%s\n' "$issue" | jq -er --argjson number "$number" '
    select(type == "object" and .number == $number and .pull_request == null) |
    .node_id | select(type == "string" and length > 0)'
}

read_issue_dependencies() {
  local node_id="$1" owner_repo="$2" number="$3"
  local response
  response="$(call_graphql "$ISSUE_DEPENDENCIES_QUERY" -f "issueId=$node_id")" || return 1
  printf '%s\n' "$response" | jq -ec \
    --arg id "$node_id" --arg repo "$owner_repo" --argjson number "$number" '
    def positive_integer: type == "number" and . > 0 and floor == .;
    def connection:
      type == "object" and (.nodes | type == "array") and
      (.nodes | length <= 100) and
      (.totalCount | type == "number" and . >= 0 and floor == .) and
      (.totalCount >= (.nodes | length)) and
      (.pageInfo.hasNextPage | type == "boolean") and
      (.pageInfo.hasNextPage == (.totalCount > (.nodes | length))) and
      all(.nodes[]; type == "object" and (.number | positive_integer) and
        (.title | type == "string") and (.state == "OPEN" or .state == "CLOSED") and
        (.url | type == "string" and length > 0));
    def format_connection:
      {nodes: [.nodes[] | {number, title, state: (.state | ascii_downcase), html_url: .url}],
       totalCount, hasNextPage: .pageInfo.hasNextPage};
    .data.node |
    select(type == "object" and .__typename == "Issue" and .id == $id and .number == $number) |
    select((.repository.nameWithOwner | type) == "string") |
    select((.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase)) |
    select((.blockedBy | connection) and (.blocking | connection)) |
    {blockedBy: (.blockedBy | format_connection), blocking: (.blocking | format_connection)}'
}

dependencies_match() {
  local state="$1" request="$2" desired="$3"
  printf '%s\n' "$state" | jq -e --argjson request "$request" --argjson desired "$desired" '
    def matches($connection; $numbers):
      all($numbers[]; . as $n |
        if $desired then any($connection.nodes[]; .number == $n)
        else ($connection.hasNextPage | not) and all($connection.nodes[]; .number != $n)
        end);
    matches(.blockedBy; $request.blocked_by) and matches(.blocking; $request.blocking)
  ' >/dev/null
}

mutate_issue_dependencies() {
  local input="$1" action="$2" desired="$3"

  # The dispatcher validates top-level types/unknown fields. Here enforce
  # the action-specific alternatives and same-repository issue numbers.
  if ! printf '%s\n' "$input" | jq -e '
    ((.blocked_by // []) | length) + ((.blocking // []) | length) > 0
  ' >/dev/null; then
    envelope_fail "$action" "MISSING_REQUIRED_FIELD" "At least one of blocked_by or blocking must be non-empty" false
    return 1
  fi
  if ! printf '%s\n' "$input" | jq -e '
    def positive_integer: type == "number" and . > 0 and floor == .;
    (.number | positive_integer) and
    all((.blocked_by // [])[], (.blocking // [])[]; positive_integer)
  ' >/dev/null; then
    envelope_fail "$action" "TARGET_ERROR" "number, blocked_by and blocking must contain positive issue integers from the current repository" false
    return 1
  fi

  local number request repo_target owner_repo issue_target
  number="$(printf '%s\n' "$input" | jq -r '.number')"
  request="$(printf '%s\n' "$input" | jq -c '{blocked_by: ((.blocked_by // []) | unique), blocking: ((.blocking // []) | unique)}')"
  repo_target="$(resolve_target)" || {
    envelope_fail "$action" "TARGET_ERROR" "Failed to resolve repository target" false
    return 1
  }
  owner_repo="$(printf '%s\n' "$repo_target" | jq -r '.repository')"
  issue_target="$(printf '%s\n' "$repo_target" | jq --argjson number "$number" '{type: "issue", repository: .repository, number: $number}')"

  local issue node_id before
  issue="$(call_gh_api "repos/$owner_repo/issues/$number" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    envelope_fail "$action" "API_ERROR" "Failed to fetch issue" false
    return 1
  }
  if printf '%s\n' "$issue" | jq -e '.pull_request != null' >/dev/null; then
    envelope_fail "$action" "NOT_FOUND" "Issue #$number not found (pull requests are not dependencies)" false
    return 1
  fi
  node_id="$(issue_node_id "$issue" "$number")" || {
    envelope_fail "$action" "API_ERROR" "Issue response has no verifiable node ID" false
    return 1
  }
  before="$(read_issue_dependencies "$node_id" "$owner_repo" "$number" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    envelope_fail "$action" "API_ERROR" "Failed to fetch issue dependencies" false
    return 1
  }

  local plan
  plan="$(printf '%s\n' "$before" | jq -c --argjson request "$request" '
    . as $state |
    [{direction: "blockedBy", numbers: $request.blocked_by},
     {direction: "blocking", numbers: $request.blocking}] |
    [.[] | .direction as $direction | .numbers[] | . as $number |
      {direction: $direction, number: $number,
       present: any($state[$direction].nodes[]; .number == $number),
       truncated: $state[$direction].hasNextPage}]')"
  if printf '%s\n' "$plan" | jq -e 'any(.[]; .truncated and (.present | not))' >/dev/null; then
    envelope_fail "$action" "API_ERROR" "Dependency list is truncated; cannot determine requested relationships" false
    return 1
  fi
  plan="$(printf '%s\n' "$plan" | jq -c --argjson desired "$desired" '[.[] | select(.present != $desired)]')"
  if [ "$plan" = "[]" ]; then
    envelope_already_applied "$action" "$issue_target" "$before"
    return 0
  fi

  # Resolve every changed peer before the first write. Duplicate numbers
  # (even across directions) use one REST lookup; the current issue is cached.
  local node_ids peer peer_issue peer_id
  node_ids="$(jq -nc --arg number "$number" --arg id "$node_id" '{($number): $id}')"
  while IFS= read -r peer; do
    [ "$peer" = "$number" ] && continue
    peer_issue="$(call_gh_api "repos/$owner_repo/issues/$peer" 2>"$GH_TEMP_DIR/gh-stderr")" || {
      envelope_fail "$action" "API_ERROR" "Failed to fetch dependency issue #$peer" false
      return 1
    }
    if printf '%s\n' "$peer_issue" | jq -e '.pull_request != null' >/dev/null; then
      envelope_fail "$action" "NOT_FOUND" "Dependency issue #$peer is a pull request" false
      return 1
    fi
    peer_id="$(issue_node_id "$peer_issue" "$peer")" || {
      envelope_fail "$action" "API_ERROR" "Dependency issue #$peer has no verifiable node ID" false
      return 1
    }
    node_ids="$(printf '%s\n' "$node_ids" | jq -c --arg peer "$peer" --arg id "$peer_id" '. + {($peer): $id}')"
  done < <(printf '%s\n' "$plan" | jq -r '[.[].number] | unique[]')

  local mutation
  if [ "$desired" = true ]; then mutation=addBlockedBy; else mutation=removeBlockedBy; fi
  local query="mutation(\$issueId: ID!, \$blockingIssueId: ID!) { $mutation(input: {issueId: \$issueId, blockingIssueId: \$blockingIssueId}) { clientMutationId } }"
  local direction issue_id blocking_id result rc wrote=false
  while IFS=$'\t' read -r direction peer; do
    peer_id="$(printf '%s\n' "$node_ids" | jq -r --arg peer "$peer" '.[$peer]')"
    if [ "$direction" = blockedBy ]; then
      issue_id="$node_id"; blocking_id="$peer_id"
    else
      issue_id="$peer_id"; blocking_id="$node_id"
    fi
    result="$(GH_RETRY_MAX=1 call_graphql "$query" -f "issueId=$issue_id" -f "blockingIssueId=$blocking_id" 2>"$GH_TEMP_DIR/gh-stderr")" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Explicit GraphQL errors on the first write are API_ERROR (including
      # permission/self-reference rejection). Transport failures and partial
      # batches are ambiguous, never retried or reported as unapplied.
      if [ "$rc" -eq 2 ] && [ "$wrote" = false ]; then
        envelope_fail "$action" "API_ERROR" "Failed to mutate issue dependencies" false
      else
        envelope_unknown_outcome "$action" "$issue_target" "{}"
      fi
      return 1
    fi
    if ! printf '%s\n' "$result" | jq -e --arg mutation "$mutation" '.data[$mutation] | type == "object" and has("clientMutationId")' >/dev/null; then
      envelope_unknown_outcome "$action" "$issue_target" "{}"
      return 1
    fi
    wrote=true
  done < <(printf '%s\n' "$plan" | jq -r '.[] | [.direction, .number] | @tsv')

  local after
  after="$(read_issue_dependencies "$node_id" "$owner_repo" "$number" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    envelope_unknown_outcome "$action" "$issue_target" "{}"
    return 1
  }
  if ! dependencies_match "$after" "$request" "$desired"; then
    envelope_unknown_outcome "$action" "$issue_target" "$after"
    return 1
  fi
  envelope_ok "$action" "$issue_target" "$after"
}
