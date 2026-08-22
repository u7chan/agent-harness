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

base_reconcile="$(jq '. + {operation:"reconcile"}' "$FIXTURE" | "$HELPER")"
assert_decision "reconcile baseline" "$base_reconcile" ok
base_snapshot="$(jq -c '.snapshot' <<< "$base_reconcile")"
assert_field "connection order is retained for the tail" "$base_reconcile" '.snapshot.threads[0].tail_comment_id' 101

for invalid_filter in \
  '.graphql.threads[0].comments[1].database_id = 100' \
  '.rest.items[1].in_reply_to_id = 999' \
  '.rest.complete = false'; do
  invalid="$(jq "$invalid_filter | . + {operation:\"reconcile\"}" "$FIXTURE" | "$HELPER")"
  assert_decision "invalid ID/topology/pagination stops" "$invalid" stop
done

plan_reuse="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "tail own Resolved reuses" "$plan_reuse" reuse
assert_field "reuse keeps the old anchor" "$plan_reuse" '.anchor_id' 101

root_only="$TMP/root-only.json"
jq 'del(.rest.items[1], .graphql.threads[0].comments[1])' "$FIXTURE" > "$root_only"
root_reconcile="$(jq '. + {operation:"reconcile"}' "$root_only" | "$HELPER")"
root_snapshot="$(jq -c '.snapshot' <<< "$root_reconcile")"
plan_post="$(json_input unused --argjson snapshot "$root_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "no prior classification posts" "$plan_post" post

plan_resolved_to_partial="$(json_input unused --argjson snapshot "$base_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Partial",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
assert_decision "Resolved to Partial posts" "$plan_resolved_to_partial" post

post_raw="$TMP/post.json"
jq '.rest.items += [{id:102,body:"**Resolved**: new evidence",html_url:"https://github.com/u7chan/agent-harness/pull/200#discussion_r102",path:"review/SKILL.md",line:42,commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",in_reply_to_id:100,pull_request_url:"https://api.github.com/repos/u7chan/agent-harness/pulls/200",user:{login:"reviewer"},created_at:"2026-08-22T00:00:00Z",updated_at:"2026-08-22T00:00:00Z",last_edited_at:null}] | .graphql.threads[0].comments += [{id:"PRRC_new",database_id:102,body:"**Resolved**: new evidence",url:"https://github.com/u7chan/agent-harness/pull/200#discussion_r102",path:"review/SKILL.md",line:42,outdated:false,commit_oid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",reply_to_id:"PRRC_root",author_login:"reviewer",author_association:"OWNER",created_at:"2026-08-22T00:00:00Z",updated_at:"2026-08-22T00:00:00Z",last_edited_at:null}]' "$root_only" > "$post_raw"
post_reconcile="$(jq '. + {operation:"reconcile"}' "$post_raw" | "$HELPER")"
post_snapshot="$(jq -c '.snapshot' <<< "$post_reconcile")"
expected_reply='{"id":102,"body":"**Resolved**: new evidence","actor":"reviewer","thread_id":"PRRT_kwDOtest1","root_comment_id":100,"node_id":"PRRC_new"}'
transport_ok="$(json_input unused --argjson plan "$plan_post" --argjson before "$root_snapshot" --argjson after "$post_snapshot" --argjson expected "$expected_reply" --arg head "$H" \
  '{operation:"verify_transport",plan:$plan,plan_snapshot:$before,fresh_snapshot:$after,expected_reply:$expected,transport_outcome:"ok",verification_head_sha:$head}')"
assert_decision "expected reply delta verifies" "$transport_ok" new_reply_verified
assert_field "post fingerprint is retained" "$transport_ok" '.record.verified_fingerprint' "$(jq -r '.snapshot.fingerprint' <<< "$post_reconcile")"

transport_already="$(json_input unused --argjson plan "$plan_post" --argjson before "$root_snapshot" --argjson after "$post_snapshot" --argjson expected "$expected_reply" --arg head "$H" \
  '{operation:"verify_transport",plan:$plan,plan_snapshot:$before,fresh_snapshot:$after,expected_reply:$expected,transport_outcome:"already_applied",verification_head_sha:$head}')"
assert_decision "same operation already-applied delta verifies" "$transport_already" already_applied_reply_verified

transport_stale="$(json_input unused --argjson plan "$plan_post" --argjson before "$root_snapshot" --argjson after "$root_snapshot" --argjson expected "$expected_reply" --arg head "$H" \
  '{operation:"verify_transport",plan:$plan,plan_snapshot:$before,fresh_snapshot:$after,expected_reply:$expected,transport_outcome:"already_applied",verification_head_sha:$head}')"
assert_decision "stale already-applied has no target" "$transport_stale" transport_already_applied

external_raw="$TMP/external.json"
jq '.rest.items += [{id:103,body:"external",html_url:"https://github.com/u7chan/agent-harness/pull/200#discussion_r103",path:"review/SKILL.md",line:42,commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",in_reply_to_id:100,pull_request_url:"https://api.github.com/repos/u7chan/agent-harness/pulls/200",user:{login:"other"},created_at:"2026-08-22T00:00:00Z",updated_at:"2026-08-22T00:00:00Z",last_edited_at:null}] | .graphql.threads[0].comments += [{id:"PRRC_external",database_id:103,body:"external",url:"https://github.com/u7chan/agent-harness/pull/200#discussion_r103",path:"review/SKILL.md",line:42,outdated:false,commit_oid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",reply_to_id:"PRRC_root",author_login:"other",author_association:"MEMBER",created_at:"2026-08-22T00:00:00Z",updated_at:"2026-08-22T00:00:00Z",last_edited_at:null}]' "$root_only" > "$external_raw"
external_reconcile="$(jq '. + {operation:"reconcile"}' "$external_raw" | "$HELPER")"
external_snapshot="$(jq -c '.snapshot' <<< "$external_reconcile")"
transport_external="$(json_input unused --argjson plan "$plan_post" --argjson before "$root_snapshot" --argjson after "$external_snapshot" --argjson expected "$expected_reply" --arg head "$H" \
  '{operation:"verify_transport",plan:$plan,plan_snapshot:$before,fresh_snapshot:$after,expected_reply:$expected,transport_outcome:"ok",verification_head_sha:$head}')"
assert_decision "nonmatching concurrent reply stops" "$transport_external" stop
assert_field "nonmatching concurrent reply is precondition change" "$transport_external" '.reason' precondition_changed

edited_raw="$TMP/edited.json"
jq '.rest.items[0].body = "edited root" | .graphql.threads[0].comments[0].body = "edited root"' "$post_raw" > "$edited_raw"
edited_reconcile="$(jq '. + {operation:"reconcile"}' "$edited_raw" | "$HELPER")"
edited_snapshot="$(jq -c '.snapshot' <<< "$edited_reconcile")"
transport_edited="$(json_input unused --argjson plan "$plan_post" --argjson before "$root_snapshot" --argjson after "$edited_snapshot" --argjson expected "$expected_reply" --arg head "$H" \
  '{operation:"verify_transport",plan:$plan,plan_snapshot:$before,fresh_snapshot:$after,expected_reply:$expected,transport_outcome:"ok",verification_head_sha:$head}')"
assert_decision "body edit is not an expected delta" "$transport_edited" stop

record="$(jq -c '.record' <<< "$transport_ok")"
eligibility="$(json_input unused --argjson record "$record" --argjson fresh "$post_snapshot" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "verified record is Resolve eligible" "$eligibility" eligible

head_changed="$(json_input unused --argjson record "$record" --argjson fresh "$post_snapshot" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "Resolve head mismatch stops" "$head_changed" stop
lgtm_missing="$(json_input unused --argjson record "$record" --argjson fresh "$post_snapshot" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:false}')"
assert_decision "unverified LGTM stops Resolve" "$lgtm_missing" stop

resolved_after="$(jq '.graphql.threads[0].resolved = true' "$post_raw" | jq '. + {operation:"reconcile"}' | "$HELPER" | jq -c '.snapshot')"
resolve_post="$(json_input unused --argjson record "$record" --argjson before "$post_snapshot" --argjson after "$resolved_after" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,transport_outcome:"ok"}')"
assert_decision "Resolve post-read verifies only state toggle" "$resolve_post" resolved_by_run
external_resolve="$(json_input unused --argjson record "$record" --argjson fresh "$resolved_after" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "external Resolve is reported separately" "$external_resolve" already_resolved_external

gate_round2="$(json_input unused --argjson records "[$record]" --arg head "$H" \
  '{operation:"gate",records:$records,verification_head_sha:$head,full_review:{clean:false,blockers:1,important_unknowns:0},round:2}')"
assert_decision "Round 2 remaining Blocker blocks LGTM" "$gate_round2" blocked
gate_partial="$(json_input unused --argjson records "[$record,{\"classification\":\"Partial\"}]" --arg head "$H" \
  '{operation:"gate",records:$records,verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:2}')"
assert_decision "Partial record blocks LGTM" "$gate_partial" blocked
gate_round3="$(json_input unused --argjson records "[$record]" --arg head "$H" \
  '{operation:"gate",records:$records,verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:3}')"
assert_decision "clean Round 3 permits LGTM planning" "$gate_round3" lgtm_eligible

echo "PASS: $pass_count recheck state helper cases"
