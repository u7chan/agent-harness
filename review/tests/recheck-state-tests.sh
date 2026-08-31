#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/recheck-state.py"
FIXTURE="$SCRIPT_DIR/fixtures/recheck-snapshot.json"
TMP="$(mktemp -d /tmp/recheck-state-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
pass_count=0

run_helper() {
  "$HELPER" < "$1"
}

json_input() {
  local output_name="$1"
  shift
  jq -n "$@" > "$TMP/input.json"
  run_helper "$TMP/input.json"
}

assert_decision() {
  local name="$1" output="$2" expected="$3" actual
  actual="$(jq -r '.decision // empty' <<< "$output")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $name expected decision=$expected, got: $output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

assert_field() {
  local name="$1" output="$2" filter="$3" expected="$4" actual
  actual="$(jq -r "$filter" <<< "$output")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $name expected $expected, got $actual ($output)" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

# Strict parser: only the current direct-reply headers are recognized.
for body in \
  '**Resolved**: evidence' \
  '**Partial** (**Blocker**): one condition remains' \
  '**Unresolved** (**Nit**): still reproducible' \
  '**Unknown**: missing execution evidence'; do
  output="$(json_input unused --arg body "$body" '{operation:"parse",body:$body}')"
  assert_decision "strict parser accepts $body" "$output" classification
done
for body in \
  '> **Resolved**: quoted' \
  '```\n**Resolved**: fenced\n```' \
  'prefix **Resolved**: inline' \
  'first line\n**Resolved**: second line' \
  '**resolved**: old case' \
  '**Partial** (Blocker): missing exact label' \
  '**Resolved**: ' \
  '**Resolved** (**Blocker**): invalid supplement'; do
  output="$(json_input unused --arg body "$body" '{operation:"parse",body:$body}')"
  assert_decision "strict parser rejects $body" "$output" not_classification
done

# reconcile: review-threads.read output (threads only) normalizes to a
# canonical snapshot without REST cross-check.
threads_only="$(jq '{threads: .graphql.threads}' "$FIXTURE")"
base_reconcile="$(jq '. + {operation:"reconcile"}' <<< "$threads_only" | "$HELPER")"
assert_decision "reconcile baseline threads" "$base_reconcile" ok
base_snapshot="$(jq -c '.snapshot' <<< "$base_reconcile")"
assert_field "connection order is retained for the tail" "$base_reconcile" '.snapshot.threads[0].tail_comment_id' 101
assert_field "actor is normalized to user.login" "$base_reconcile" '.snapshot.threads[0].comments[0].actor' reviewer
assert_field "reply target is the parent GraphQL node id" "$base_reconcile" '.snapshot.threads[0].comments[1].reply_to_comment_id' PRRC_root
assert_field "canonical snapshot has no fingerprint key" "$base_reconcile" '.snapshot | has("fingerprint")' false

jq -n --slurpfile fixture "$FIXTURE" '{operation:"reconcile", threads: $fixture[0].graphql.threads, pagination: {threads_complete: true, comments_complete: false}}' > "$TMP/pagination-incomplete.json"
if [ "$(jq -r '.decision // empty' <<< "$(run_helper "$TMP/pagination-incomplete.json")")" != "stop" ]; then
  echo "FAIL: incomplete pagination is not fail-closed" >&2
  exit 1
fi
pass_count=$((pass_count + 1))

for invalid_filter in \
  '.graphql.threads[0].comments[1].database_id = 100' \
  '.graphql.threads[0].comments[1].in_reply_to_id = "PRRC_absent"' \
  '.graphql.threads[0].resolved = "yes"'; do
  invalid="$(jq "$invalid_filter | {threads: .graphql.threads, operation:\"reconcile\"}" "$FIXTURE" | "$HELPER")"
  assert_decision "invalid ID/topology/resolved state stops" "$invalid" stop
done

# plan: reuse only when the tail reply has the same actor, root, and
# classification; otherwise post.
plan_reuse="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "tail own Resolved reuses" "$plan_reuse" reuse
assert_field "reuse keeps the old anchor" "$plan_reuse" '.anchor_id' 101
plan_reuse_partial="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_field "reuse identifies the tail as anchor" "$plan_reuse_partial" '.tail_comment_id' 101

root_only="$TMP/root-only.json"
jq 'del(.graphql.threads[0].comments[1])' "$FIXTURE" > "$root_only"
root_reconcile="$(jq '{threads: .graphql.threads} | . + {operation:"reconcile"}' "$root_only" | "$HELPER")"
root_snapshot="$(jq -c '.snapshot' <<< "$root_reconcile")"
plan_post="$(json_input unused --argjson snapshot "$root_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "no prior classification posts" "$plan_post" post

plan_partial="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Partial",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "Resolved tail against Partial classification posts" "$plan_partial" post

plan_other_actor="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"someone-else",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "someone else's root stops" "$plan_other_actor" stop
assert_field "someone else's root is a root actor mismatch" "$plan_other_actor" '.reason' root_actor_mismatch

resolved_raw="$TMP/resolved.json"
jq '.graphql.threads[0].resolved = true' "$FIXTURE" > "$resolved_raw"
resolved_reconcile="$(jq '{threads: .graphql.threads} | . + {operation:"reconcile"}' "$resolved_raw" | "$HELPER")"
resolved_snapshot="$(jq -c '.snapshot' <<< "$resolved_reconcile")"
plan_resolved="$(json_input unused --argjson snapshot "$resolved_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "already-resolved thread stops" "$plan_resolved" stop

plan_no_head="$(json_input unused --argjson snapshot "$base_snapshot" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100}')"
assert_decision "missing verification head stops" "$plan_no_head" stop

# gate: LGTM policy uses classification records and the full review result.
record="$(jq -nc --arg head "$H" '{thread_id:"PRRT_kwDOtest1",root_comment_id:100,reviewer_login:"reviewer",classification:"Resolved",classification_reply_id:101,verification_head_sha:$head}')"
gate_clean="$(json_input unused --argjson record "$record" --arg head "$H" \
  '{operation:"gate",records:[$record],verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:2}')"
assert_decision "clean full review permits LGTM" "$gate_clean" lgtm_eligible
assert_field "LGTM records the fixed head" "$gate_clean" '.head_sha' "$H"

gate_blocker="$(json_input unused --argjson record "$record" --arg head "$H" \
  '{operation:"gate",records:[$record],verification_head_sha:$head,full_review:{clean:false,blockers:1,important_unknowns:0},round:2}')"
assert_decision "remaining Blocker blocks LGTM" "$gate_blocker" blocked
gate_partial="$(json_input unused --argjson record "$record" --arg head "$H" \
  '{operation:"gate",records:[$record,{thread_id:"T2",root_comment_id:200,reviewer_login:"reviewer",classification:"Partial",classification_reply_id:201,verification_head_sha:$head}],verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:2}')"
assert_decision "Partial record blocks LGTM" "$gate_partial" blocked
assert_field "Partial record blocks with classification reason" "$gate_partial" '.reason' classification_not_resolved
gate_round3="$(json_input unused --argjson record "$record" --arg head "$H" \
  '{operation:"gate",records:[$record],verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:3}')"
assert_decision "clean Round 3 permits LGTM planning" "$gate_round3" lgtm_eligible
gate_head_mismatch="$(json_input unused --argjson record "$record" --arg head "$H" \
  '{operation:"gate",records:[$record],verification_head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",full_review:{clean:true,blockers:0,important_unknowns:0},round:2}')"
assert_decision "record head mismatch stops" "$gate_head_mismatch" stop

echo "PASS: $pass_count recheck state helper cases"