#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/envelope.sh"
source "$SCRIPT_DIR/../common/target.sh"
source "$SCRIPT_DIR/../common/http.sh"
source "$SCRIPT_DIR/../common/file.sh"

call_graphql() {
  local query="$1"
  shift
  local result exit_code=0
  result="$(gh api graphql -f query="$query" "$@" 2>/dev/null)" || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    return 1
  fi
  if ! echo "$result" | jq -e '(.errors // []) | length == 0' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$result"
}

operation_target() {
  local owner_repo="$1"
  local pr_number="$2"
  local id="$3"
  local url="$4"
  jq -n \
    --arg type "review_comment" \
    --arg repo "$owner_repo" \
    --argjson id "$id" \
    --argjson parent_number "$pr_number" \
    --arg url "$url" \
    '{
      type: $type, repository: $repo, id: $id,
      parent: {type: "pull_request", repository: $repo, number: $parent_number},
      url: $url
    }'
}

format_comment() {
  local comment="$1"
  local outcome="$2"
  echo "$comment" | jq --arg outcome "$outcome" '{
    id,
    body,
    html_url,
    path,
    position,
    line,
    commit_id,
    in_reply_to_id,
    user: {login: .user.login},
    created_at,
    updated_at,
    last_edited_at,
    author_association,
    transport_outcome: $outcome,
    operation_scoped: true
  }'
}

precondition_changed() {
  local message="$1"
  envelope_fail "review-comments.reply" "PRECONDITION_CHANGED" "$message" false
  exit 1
}

valid_baseline_ids() {
  local input="$1"
  jq -e '
    type == "array" and
    all(.[]; type == "number" and . == floor and . > 0) and
    (length == (map(tostring) | unique | length))
  ' <<< "$input" >/dev/null 2>&1
}

normalize_comment() {
  jq -c '[.[] | {
    id: (.id // .comment_id),
    body: (.body // ""),
    in_reply_to_id: (.in_reply_to_id // .reply_to_comment_id // null),
    actor: (.user.login // .user_login // .actor // ""),
    path: (.path // null),
    line: (.line // null),
    commit_id: (.commit_id // null),
    created_at: (.created_at // null),
    updated_at: (.updated_at // null)
  }] | sort_by(.id)'
}

baseline_matches_current() {
  local baseline_comments="$1"
  local current_comments="$2"
  local normalized_baseline normalized_current
  normalized_baseline="$(normalize_comment <<< "$baseline_comments")" || return 1
  normalized_current="$(normalize_comment <<< "$current_comments")" || return 1
  [ "$normalized_baseline" = "$normalized_current" ]
}

ids_and_delta() {
  local baseline_ids="$1"
  local current_file
  current_file="$(gh_make_temp "delta-comments")"
  cat > "$current_file"
  local current_ids
  current_ids="$(jq -c '[.[].id] | sort' "$current_file")" || {
    gh_cleanup "$current_file"
    return 1
  }
  local result
  result="$(jq -n \
    --argjson baseline "$baseline_ids" \
    --argjson current "$current_ids" \
    --slurpfile comments "$current_file" \
    '{
      baseline: ($baseline | sort),
      current: $current,
      added: ($current - ($baseline | sort)),
      removed: (($baseline | sort) - $current),
      added_comments: [$comments[0][] as $comment |
        select((($current - ($baseline | sort)) | index($comment.id)) != null) | $comment]
    }')" || {
    gh_cleanup "$current_file"
    return 1
  }
  gh_cleanup "$current_file"
  printf '%s\n' "$result"
}

graphql_thread_state() {
  local thread_id="$1"
  local query
  query='query($threadId: ID!, $after: String) { node(id: $threadId) { ... on PullRequestReviewThread { id isResolved pullRequest { url repository { nameWithOwner } } comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id databaseId body url path line outdated commit { oid } replyTo { id } author { login } authorAssociation createdAt updatedAt lastEditedAt } } } } }'

  local cursor="null"
  local comments_file
  comments_file="$(gh_make_temp "graphql-comments")"
  printf '[]\n' > "$comments_file"
  local node_state=""
  while :; do
    local page_result
    page_result="$(call_graphql "$query" -F threadId="$thread_id" -F after="$cursor" 2>/dev/null)" || return 1

    # A successfully answered node lookup that no longer has a thread is an
    # observed identity change, not a transport failure. Let the reconciliation
    # below classify it as PRECONDITION_CHANGED.
    if echo "$page_result" | jq -e '.data.node == null' >/dev/null 2>&1; then
      jq -nc '{node: null, comments: []}'
      return 0
    fi

    if ! echo "$page_result" | jq -e '
      .data.node != null and
      (.data.node.id | type == "string") and
      (.data.node.isResolved | type == "boolean") and
      (.data.node.pullRequest.url | type == "string") and
      (.data.node.pullRequest.repository.nameWithOwner | type == "string") and
      (.data.node.comments | type == "object") and
      (.data.node.comments.nodes | type == "array") and
      (.data.node.comments.pageInfo | type == "object") and
      (.data.node.comments.pageInfo.hasNextPage | type == "boolean")
    ' >/dev/null 2>&1; then
      return 1
    fi

    if [ -z "$node_state" ]; then
      node_state="$(echo "$page_result" | jq -c '.data.node | {
        id,
        resolved: .isResolved,
        pull_request_url: .pullRequest.url,
        repository: .pullRequest.repository.nameWithOwner
      }')" || return 1
    fi

    local page_comments
    page_comments="$(echo "$page_result" | jq -c '[.data.node.comments.nodes[] | {
      id: .databaseId,
      node_id: .id,
      body,
      url,
      path,
      line,
      outdated,
      commit_id: .commit.oid,
      reply_to_node_id: .replyTo.id,
      actor: .author.login,
      author_association: .authorAssociation,
      created_at: .createdAt,
      updated_at: .updatedAt,
      last_edited_at: .lastEditedAt
    }]')" || return 1
    local page_file
    page_file="$(gh_make_temp "graphql-comment-page")"
    printf '%s\n' "$page_comments" > "$page_file"
    jq -n -c --slurpfile old "$comments_file" --slurpfile page "$page_file" \
      '$old[0] + $page[0]' > "${comments_file}.tmp" || return 1
    mv "${comments_file}.tmp" "$comments_file"
    gh_cleanup "$page_file"

    local has_next end_cursor
    has_next="$(echo "$page_result" | jq -r '.data.node.comments.pageInfo.hasNextPage')"
    end_cursor="$(echo "$page_result" | jq -r '.data.node.comments.pageInfo.endCursor // "null"')"
    if [ "$has_next" != "true" ]; then
      break
    fi
    if [ "$end_cursor" = "null" ] || [ "$end_cursor" = "$cursor" ]; then
      return 1
    fi
    cursor="$end_cursor"
  done

  local node_file
  node_file="$(gh_make_temp "graphql-node")"
  printf '%s\n' "$node_state" > "$node_file"
  jq -nc --slurpfile node "$node_file" --slurpfile comments "$comments_file" \
    '{node: $node[0], comments: $comments[0]}'
  gh_cleanup "$node_file"
  gh_cleanup "$comments_file"
}

graphql_preflight_check() {
  local state_file="$1"
  local rest_comments_file="$2"
  local baseline_ids="$3"
  local allow_expected_effect="$4"
  local body_file="$5"
  local actor="$6"
  local root_id="$7"
  local root_node_id="$8"
  local root_path="$9"
  local root_line="${10}"
  local root_commit_id="${11}"
  local thread_id="${12}"
  local pr_url="${13}"
  local owner_repo="${14}"
  local baseline_resolved="${15}"

  jq -n -c \
    --slurpfile state "$state_file" \
    --slurpfile rest_comments "$rest_comments_file" \
    --argjson baseline_ids "$baseline_ids" \
    --argjson allow_expected_effect "$allow_expected_effect" \
    --rawfile body "$body_file" \
    --arg actor "$actor" \
    --argjson root_id "$root_id" \
    --arg root_node_id "$root_node_id" \
    --arg root_path "$root_path" \
    --argjson root_line "$root_line" \
    --arg root_commit_id "$root_commit_id" \
    --arg thread_id "$thread_id" \
    --arg pr_url "$pr_url" \
    --arg owner_repo "$owner_repo" \
    --argjson baseline_resolved "$baseline_resolved" '
      def rest_shape:
        . as $comment |
        {
          id: $comment.id,
          node_id: ($comment.node_id // null),
          body: ($comment.body // null),
          actor: ($comment.user.login // null),
          path: ($comment.path // null),
          line: ($comment.line // null),
          commit_id: ($comment.commit_id // null),
          reply_to_id: ($comment.in_reply_to_id // null),
          url: ($comment.html_url // null),
          created_at: ($comment.created_at // null),
          updated_at: ($comment.updated_at // null),
          last_edited_at: (if ($comment | has("last_edited_at")) then $comment.last_edited_at else null end),
          has_last_edited_at: ($comment | has("last_edited_at")),
          outdated: (if ($comment | has("outdated")) then $comment.outdated else null end),
          has_outdated: ($comment | has("outdated")),
          author_association: ($comment.author_association // null),
          has_author_association: ($comment | has("author_association"))
        };

      def comment_match($expected; $actual):
        ($actual != null) and
        ($actual.id == $expected.id) and
        ($expected.node_id != null) and ($actual.node_id == $expected.node_id) and
        ($actual.body == $expected.body) and
        ($actual.actor == $expected.actor) and
        ($actual.path == $expected.path) and
        ($actual.line == $expected.line) and
        ($actual.commit_id == $expected.commit_id) and
        ($actual.reply_to_node_id == $expected.reply_to_node_id) and
        ($actual.created_at == $expected.created_at) and
        ($actual.updated_at == $expected.updated_at) and
        (if $expected.has_last_edited_at then $actual.last_edited_at == $expected.last_edited_at else true end) and
        (if $expected.has_outdated then $actual.outdated == $expected.outdated else true end) and
        (if $expected.has_author_association then $actual.author_association == $expected.author_association else true end) and
        (if $expected.url != null then $actual.url == $expected.url else true end);

      ($state[0]) as $state_value
      | ($rest_comments[0]) as $rest_value
      | ($rest_value
        | map(select(.id == $root_id or .in_reply_to_id == $root_id) | rest_shape)) as $rest_thread0
      | ($rest_thread0 | map({key: (.id | tostring), value: .}) | from_entries) as $rest_by_id
      | ($rest_thread0 | map(. as $comment |
          . + {
            reply_to_node_id: (
              if $comment.reply_to_id == null then null
              else ($rest_by_id[($comment.reply_to_id | tostring)].node_id // "__missing_parent_node__")
              end
            )
          }
        )) as $expected
      | ($expected | map(.id)) as $expected_ids
      | ($state_value.comments) as $actual
      | ($actual | map(.id)) as $actual_ids
      | ($actual | map(.id | tostring) | unique | length == ($actual | length)) as $unique_ids
      | ($actual | map(.node_id) | unique | length == ($actual | length)) as $unique_nodes
      | ($actual | map(. as $comment | select(($expected_ids | index($comment.id)) == null))) as $extras
      | ($expected | map(. as $comment |
          . as $expected_comment |
          ($actual | map(select(.id == $expected_comment.id)) | if length == 1 then .[0] else null end) as $actual_comment |
          {expected: $expected_comment, actual: $actual_comment, matches: comment_match($expected_comment; $actual_comment)}
        )) as $known_checks
      | ($extras | map(. as $comment | select(
          (($baseline_ids | index($comment.id)) == null) and
          ($comment.body == $body) and
          ($comment.actor == $actor) and
          ($comment.reply_to_node_id == $root_node_id) and
          ($comment.path == $root_path) and
          ($comment.line == $root_line) and
          ($comment.commit_id == $root_commit_id)
        ))) as $matching_extras
      | (
          ($state_value.node.id == $thread_id) and
          ($state_value.node.resolved == $baseline_resolved) and
          ($state_value.node.pull_request_url == $pr_url) and
          ($state_value.node.repository == $owner_repo) and
          ($rest_thread0 | map(select(.id == $root_id)) | length == 1) and
          ($expected | all(.[];
            (.id | type == "number") and
            (.node_id | type == "string") and (.node_id | length > 0) and
            (.body | type == "string") and
            (.actor | type == "string") and (.actor | length > 0) and
            ((.line == null) or (.line | type == "number")) and
            ((.reply_to_id == null) or (.reply_to_id | type == "number")) and
            ((.reply_to_node_id == null) or (.reply_to_node_id | type == "string"))
          )) and
          ($actual | all(.[];
            (.id | type == "number") and
            (.node_id | type == "string") and (.node_id | length > 0) and
            (.body | type == "string") and
            (.actor | type == "string") and (.actor | length > 0) and
            ((.path == null) or (.path | type == "string")) and
            ((.line == null) or (.line | type == "number")) and
            ((.reply_to_node_id == null) or (.reply_to_node_id | type == "string")) and
            ((.created_at == null) or (.created_at | type == "string")) and
            ((.updated_at == null) or (.updated_at | type == "string")) and
            ((.last_edited_at == null) or (.last_edited_at | type == "string")) and
            ((.outdated == null) or (.outdated | type == "boolean"))
          )) and
          $unique_ids and $unique_nodes and
          (($expected_ids - $actual_ids) | length == 0) and
          ($known_checks | all(.[]; .matches)) and
          (
            if ($extras | length) == 0 then true
            elif $allow_expected_effect and ($extras | length) == 1 and ($matching_extras | length) == 1 then true
            else false
            end
          )
        ) as $valid
      | {
          valid: $valid,
          already_applied_comment: (if $valid and ($extras | length) == 1 and ($matching_extras | length) == 1 then $matching_extras[0] else null end)
        }
    '
}

main() {
  local request_file="$1"

  local number reference reply_to thread_id baseline_thread_resolved plan_fingerprint baseline_ids baseline_comments_present request_body_file
  number="$(jq -r '.number' "$request_file")"
  reference="$(jq -r '.reference // empty' "$request_file")"
  reply_to="$(jq -r '.reply_to' "$request_file")"
  thread_id="$(jq -r '.thread_id // empty' "$request_file")"
  baseline_thread_resolved="$(jq -c 'if has("baseline_thread_resolved") then .baseline_thread_resolved else null end' "$request_file")"
  request_body_file="$(gh_make_temp "request-body")"
  jq -j '.body' "$request_file" > "$request_body_file"
  plan_fingerprint="$(jq -r '.plan_fingerprint // empty' "$request_file")"
  baseline_ids="$(jq -c '.baseline_comment_ids // empty' "$request_file")"

  if [ -z "$plan_fingerprint" ]; then
    envelope_fail "review-comments.reply" "MISSING_OPERATION_IDENTITY" "plan_fingerprint is required for operation-scoped reply transport" false
    exit 1
  fi
  if [ -z "$baseline_ids" ] || ! valid_baseline_ids "$baseline_ids"; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "baseline_comment_ids must contain unique positive integer IDs" false
    exit 1
  fi
  if [ -z "$thread_id" ] || [ "$baseline_thread_resolved" != "true" ] && [ "$baseline_thread_resolved" != "false" ]; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "thread_id and boolean baseline_thread_resolved are required" false
    exit 1
  fi
  baseline_comments_present="$(jq -r 'has("baseline_comments")' "$request_file")"
  if [ "$baseline_comments_present" = "true" ] && [ "$(jq -r '.baseline_comments | type' "$request_file")" != "array" ]; then
    envelope_fail "review-comments.reply" "INVALID_OPERATION_BASELINE" "baseline_comments must be an array" false
    exit 1
  fi

  local target
  target="$(resolve_pr_target "$reference" "$number")" || {
    envelope_fail "review-comments.reply" "TARGET_ERROR" "Failed to resolve PR target" false
    exit 1
  }
  local owner_repo pr_number pr_url
  owner_repo="$(echo "$target" | jq -r '.repository')"
  pr_number="$(echo "$target" | jq -r '.number')"
  pr_url="$(echo "$target" | jq -r '.url')"

  local actor
  actor="$(gh api user --jq '.login' 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "AUTH_ERROR" "Failed to resolve current user" false
    exit 1
  }

  local parent_data parent_api_url
  parent_data="$(call_gh_api "repos/$owner_repo/pulls/$pr_number" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch pull request" false
    exit 1
  }
  parent_api_url="$(echo "$parent_data" | jq -r '.url')"

  local current
  current="$(call_gh_api "repos/$owner_repo/pulls/comments/$reply_to" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch reply-to review comment" false
    exit 1
  }

  local current_pr_url
  current_pr_url="$(echo "$current" | jq -r '.pull_request_url // ""')"
  if [ "$current_pr_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Comment $reply_to does not belong to PR $pr_number (pull_request_url=$current_pr_url, expected=$parent_api_url)" false
    exit 1
  fi

  # Walk to the actual root and reject cycles.  The write always targets the
  # root numeric REST ID, so the caller and the operation baseline share one
  # unambiguous topology identity.
  local visited_file
  visited_file="$(gh_make_temp "visited-ids")"
  echo "[]" > "$visited_file"
  local root="$current"
  local step=0
  local max_depth=50
  while :; do
    step=$((step + 1))
    if [ "$step" -gt "$max_depth" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Root comment resolution exceeded max depth ($max_depth)" false
      exit 1
    fi
    local root_id
    root_id="$(echo "$root" | jq -r '.id // empty')"
    if [ -z "$root_id" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no numeric id" false
      exit 1
    fi
    if [ "$(jq --argjson id "$root_id" 'index($id) != null' "$visited_file")" = "true" ]; then
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Circular reference detected in comment thread at comment $root_id" false
      exit 1
    fi
    jq --argjson id "$root_id" '. + [$id]' "$visited_file" > "${visited_file}.tmp" && mv "${visited_file}.tmp" "$visited_file"
    local parent_id
    parent_id="$(echo "$root" | jq -r '.in_reply_to_id // empty')"
    if [ -z "$parent_id" ]; then
      break
    fi
    root="$(call_gh_api "repos/$owner_repo/pulls/comments/$parent_id" 2>/dev/null)" || {
      gh_cleanup "$visited_file"
      envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch parent comment $parent_id during root resolution" false
      exit 1
    }
  done
  gh_cleanup "$visited_file"

  local root_pull_request_url root_id root_node_id root_path root_commit_id
  root_pull_request_url="$(echo "$root" | jq -r '.pull_request_url // ""')"
  root_id="$(echo "$root" | jq -r '.id')"
  root_node_id="$(echo "$root" | jq -r '.node_id // empty')"
  root_path="$(echo "$root" | jq -r '.path // empty')"
  root_commit_id="$(echo "$root" | jq -r '.commit_id // empty')"
  if [ "$root_pull_request_url" != "$parent_api_url" ]; then
    envelope_fail "review-comments.reply" "REPLY_MISMATCH" "Root comment belongs to $root_pull_request_url, not $parent_api_url" false
    exit 1
  fi
  if [ -z "$root_node_id" ] || [ -z "$root_path" ] || [ -z "$root_commit_id" ]; then
    envelope_fail "review-comments.reply" "API_ERROR" "Root comment has no node_id, path, or commit_id to inherit" false
    exit 1
  fi

  local pr_target
  pr_target="$(jq -n \
    --arg type "pull_request" \
    --arg repo "$owner_repo" \
    --argjson number "$pr_number" \
    --arg url "$pr_url" \
    '{type: $type, repository: $repo, number: $number, url: $url}')"

  # This is the operation preflight.  An old exact-body comment is harmless if
  # it is part of the baseline: it is not the effect of this operation.  Only
  # one new, exact, direct reply can be adopted as an operation-scoped retry.
  local existing existing_file adopted="" adopted_id="" operation_already_applied=false
  existing="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch existing review comments" false
    exit 1
  }
  existing_file="$(gh_make_temp "baseline-comments")"
  printf '%s\n' "$existing" > "$existing_file"
  local delta
  delta="$(ids_and_delta "$baseline_ids" <<< "$existing")" || precondition_changed "Failed to compare operation baseline IDs"
  local added_count removed_count
  added_count="$(echo "$delta" | jq -r '.added | length')"
  removed_count="$(echo "$delta" | jq -r '.removed | length')"

  if [ "$added_count" -eq 0 ] && [ "$removed_count" -eq 0 ] && [ "$baseline_comments_present" = "true" ]; then
    if ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" "$existing"; then
      precondition_changed "Operation baseline comment body or edit metadata changed"
    fi
  elif [ "$added_count" -gt 0 ] || [ "$removed_count" -gt 0 ]; then
    if [ "$removed_count" -ne 0 ] || [ "$added_count" -ne 1 ]; then
      precondition_changed "Operation baseline changed by a non-single reply effect"
    fi
    adopted="$(echo "$existing" | jq -c --argjson baseline "$baseline_ids" --rawfile body "$request_body_file" --arg actor "$actor" --argjson root_id "$root_id" '
      [.[] as $comment | select(
        (($baseline | index($comment.id)) == null) and
        $comment.body == $body and
        ($comment.user.login // "") == $actor and
        ($comment.in_reply_to_id // null) == $root_id
      ) | $comment]
      | if length == 1 then .[0] else empty end
    ')" || adopted=""
    if [ -z "$adopted" ] || [ "$adopted" = "null" ]; then
      precondition_changed "Operation baseline changed by a non-matching reply"
    fi
    adopted_id="$(echo "$adopted" | jq -r '.id')"
    if [ "$baseline_comments_present" = "true" ] && ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" \
      "$(echo "$existing" | jq --argjson id "$adopted_id" '[.[] | select(.id != $id)]')"; then
      precondition_changed "Operation baseline changed an existing comment or edit metadata"
    fi
    operation_already_applied=true
  fi

  # Re-read the complete GraphQL comment connection immediately before
  # constructing the POST. The REST collection is the operation checkpoint,
  # while GraphQL supplies the thread identity, topology, and metadata that
  # REST cannot safely represent. A GraphQL-only expected reply is also
  # adoptable, but only when it is the single operation-scoped effect.
  local allow_graph_expected_effect=false
  if [ "$added_count" -eq 0 ] && [ "$removed_count" -eq 0 ]; then
    allow_graph_expected_effect=true
  fi

  local root_line
  root_line="$(echo "$root" | jq -c '.line // null')"
  local thread_state thread_state_file
  thread_state="$(graphql_thread_state "$thread_id" 2>/dev/null)" || {
    envelope_fail "review-comments.reply" "API_ERROR" "Failed to fetch root review thread state" false
    exit 1
  }
  thread_state_file="$(gh_make_temp "graphql-thread-state")"
  printf '%s\n' "$thread_state" > "$thread_state_file"

  local graphql_check
  graphql_check="$(graphql_preflight_check \
    "$thread_state_file" "$existing_file" "$baseline_ids" "$allow_graph_expected_effect" \
    "$request_body_file" "$actor" "$root_id" "$root_node_id" "$root_path" \
    "$root_line" "$root_commit_id" "$thread_id" "$pr_url" "$owner_repo" \
    "$baseline_thread_resolved")" || {
    precondition_changed "GraphQL thread preflight could not be reconciled with the operation baseline"
  }
  if [ "$(echo "$graphql_check" | jq -r '.valid')" != "true" ]; then
    precondition_changed "GraphQL thread comment set, topology, metadata, or identity changed"
  fi

  local graphql_adopted_id
  graphql_adopted_id="$(echo "$graphql_check" | jq -r '.already_applied_comment.id // empty')"
  if [ -n "$graphql_adopted_id" ] && [ "$operation_already_applied" != "true" ]; then
    adopted_id="$graphql_adopted_id"
    adopted="$(call_gh_api "repos/$owner_repo/pulls/comments/$graphql_adopted_id" 2>/dev/null)" || \
      precondition_changed "GraphQL observed an expected reply but REST could not verify it"
    if ! echo "$adopted" | jq -e \
      --argjson id "$graphql_adopted_id" \
      --argjson root_id "$root_id" \
      --arg parent_api_url "$parent_api_url" \
      --arg actor "$actor" \
      --rawfile body "$request_body_file" '
        .id == $id and
        .pull_request_url == $parent_api_url and
        .body == $body and
        (.user.login // "") == $actor and
        .in_reply_to_id == $root_id
      ' >/dev/null 2>&1; then
      precondition_changed "GraphQL expected reply failed REST identity verification"
    fi
    operation_already_applied=true
  fi

  if [ "$baseline_thread_resolved" != "false" ]; then
    precondition_changed "Operation baseline thread is already resolved"
  fi

  if [ "$operation_already_applied" = "true" ]; then
    local adopted_url adopted_target
    adopted_url="$(echo "$adopted" | jq -r '.html_url // ""')"
    adopted_target="$(operation_target "$owner_repo" "$pr_number" "$adopted_id" "$adopted_url")"
    envelope_already_applied "review-comments.reply" "$adopted_target" "$(format_comment "$adopted" "already_applied")"
    exit 0
  fi

  local body_file
  body_file="$(gh_make_temp "write-body")"
  jq -n --rawfile b "$request_body_file" --argjson in_reply_to "$root_id" \
    '{body: $b, in_reply_to: $in_reply_to}' > "$body_file"

  local saved_retry="${GH_RETRY_MAX:-3}"
  GH_RETRY_MAX=1
  local response
  response="$(call_gh_api "repos/$owner_repo/pulls/$pr_number/comments" "POST" --input "$body_file" 2>"$GH_TEMP_DIR/gh-stderr")" || {
    GH_RETRY_MAX="$saved_retry"
    gh_cleanup "$body_file"
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  GH_RETRY_MAX="$saved_retry"
  gh_cleanup "$body_file"

  local response_id
  response_id="$(echo "$response" | jq -r '.id // empty')"
  if ! [[ "$response_id" =~ ^[0-9]+$ ]]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$response"
    exit 1
  fi

  local verified
  verified="$(call_gh_api "repos/$owner_repo/pulls/comments/$response_id" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "{}"
    exit 1
  }
  local verified_id verified_pr verified_actor verified_reply response_url verified_url
  verified_id="$(echo "$verified" | jq -r '.id // empty')"
  verified_pr="$(echo "$verified" | jq -r '.pull_request_url // ""')"
  verified_actor="$(echo "$verified" | jq -r '.user.login // empty')"
  verified_reply="$(echo "$verified" | jq -r '.in_reply_to_id // empty')"
  response_url="$(echo "$response" | jq -r '.html_url // ""')"
  verified_url="$(echo "$verified" | jq -r '.html_url // ""')"
  local verified_body_file
  verified_body_file="$(gh_make_temp "verified-body")"
  jq -j '.body // empty' <<< "$verified" > "$verified_body_file"
  local response_body_file
  response_body_file="$(gh_make_temp "response-body")"
  jq -j '.body // empty' <<< "$response" > "$response_body_file"
  if [ "$response_id" != "$verified_id" ] || [ "$response_url" != "$verified_url" ] || [ "$verified_pr" != "$parent_api_url" ] || \
     ! cmp -s "$request_body_file" "$response_body_file" || \
     ! cmp -s "$request_body_file" "$verified_body_file" || [ "$verified_actor" != "$actor" ] || [ "$verified_reply" != "$root_id" ]; then
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  fi

  # A successful POST is not enough.  The full post snapshot must be exactly
  # baseline + the returned reply; a concurrent Y makes the transport outcome
  # observable but unsafe to adopt as a classification record.
  local after
  after="$(call_gh_api_paginated "repos/$owner_repo/pulls/$pr_number/comments" '[.[]]' "100" 2>/dev/null)" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  }
  local after_delta after_added after_removed
  after_delta="$(ids_and_delta "$baseline_ids" <<< "$after")" || {
    envelope_unknown_outcome "review-comments.reply" "$pr_target" "$verified"
    exit 1
  }
  after_added="$(echo "$after_delta" | jq -r '.added | length')"
  after_removed="$(echo "$after_delta" | jq -r '.removed | length')"
  if [ "$after_removed" -ne 0 ] || [ "$after_added" -ne 1 ] || \
     [ "$(echo "$after_delta" | jq -r --argjson id "$response_id" '.added | index($id) != null')" != "true" ]; then
    precondition_changed "Post-write snapshot contains an unexpected comment delta"
  fi
  if [ "$baseline_comments_present" = "true" ] && ! baseline_matches_current "$(jq -c '.baseline_comments' "$request_file")" \
    "$(echo "$after" | jq --argjson id "$response_id" '[.[] | select(.id != $id)]')"; then
    precondition_changed "Post-write snapshot changed an existing comment or edit metadata"
  fi

  local comment_target
  comment_target="$(operation_target "$owner_repo" "$pr_number" "$response_id" "$(echo "$verified" | jq -r '.html_url // ""')")"
  envelope_ok "review-comments.reply" "$comment_target" "$(format_comment "$verified" "ok")"
}

main "$@"
