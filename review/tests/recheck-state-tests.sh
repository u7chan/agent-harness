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
assert_field "Action actor shape is normalized" "$base_reconcile" '.snapshot.threads[0].comments[0].actor' reviewer
assert_field "Action reply target shape is normalized" "$base_reconcile" '.snapshot.threads[0].comments[1].reply_to_node_id' PRRC_root

edited_history_raw="$TMP/edited-history.json"
jq '.graphql.threads[0].comments[1].last_edited_at = "2026-08-22T01:00:00Z"' "$FIXTURE" > "$edited_history_raw"
edited_history_reconcile="$(jq '. + {operation:"reconcile"}' "$edited_history_raw" | "$HELPER")"
assert_decision "REST missing edit history accepts GraphQL edited comment" "$edited_history_reconcile" ok
edited_history_changed="$TMP/edited-history-changed.json"
jq '.graphql.threads[0].comments[1].last_edited_at = "2026-08-22T02:00:00Z"' "$edited_history_raw" > "$edited_history_changed"
edited_history_changed_reconcile="$(jq '. + {operation:"reconcile"}' "$edited_history_changed" | "$HELPER")"
if [ "$(jq -r '.snapshot.fingerprint' <<< "$edited_history_reconcile")" = "$(jq -r '.snapshot.fingerprint' <<< "$edited_history_changed_reconcile")" ]; then
  echo "FAIL: GraphQL edit metadata did not change the fingerprint" >&2
  exit 1
fi
pass_count=$((pass_count + 1))

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
assert_field "post snapshot fingerprint is retained" "$transport_ok" '.record.verified_snapshot_fingerprint' "$(jq -r '.snapshot.fingerprint' <<< "$post_reconcile")"
assert_field "post target thread fingerprint is retained" "$transport_ok" '.record.verified_fingerprint' "$(jq -r '.snapshot.threads[0].thread_fingerprint' <<< "$post_reconcile")"

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
resolve_already_applied="$(json_input unused --argjson record "$record" --argjson before "$post_snapshot" --argjson after "$resolved_after" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,transport_outcome:"already_applied"}')"
assert_decision "already-applied Resolve is external" "$resolve_already_applied" already_resolved_external
assert_field "already-applied Resolve preserves state-only verification" "$resolve_already_applied" '.state_delta_verified' true
resolve_already_stably_resolved="$(json_input unused --argjson record "$record" --argjson before "$resolved_after" --argjson after "$resolved_after" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,transport_outcome:"already_applied"}')"
assert_decision "already-applied already-resolved post-read is external" "$resolve_already_stably_resolved" already_resolved_external
resolve_already_unresolved="$(json_input unused --argjson record "$record" --argjson before "$post_snapshot" --argjson after "$post_snapshot" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,transport_outcome:"already_applied"}')"
assert_decision "already-applied unresolved post-read fails closed" "$resolve_already_unresolved" stop
external_resolve="$(json_input unused --argjson record "$record" --argjson fresh "$resolved_after" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "external Resolve is reported separately" "$external_resolve" already_resolved_external

# Resolve records are thread-scoped, while an explicitly supplied successful
# Resolve result is the only permitted delta from an earlier target in this
# run.  This exercises A -> B sequencing and rejects both target and unrelated
# external changes.
multi_reconcile="$(jq '. + {operation:"reconcile"}' "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" | "$HELPER")"
assert_decision "multi-thread fixture reconciles" "$multi_reconcile" ok
multi_snapshot="$(jq -c '.snapshot' <<< "$multi_reconcile")"
multi_plan_a="$(json_input unused --argjson snapshot "$multi_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest1",root_comment_id:100,verification_head_sha:$head}')"
multi_plan_b="$(json_input unused --argjson snapshot "$multi_snapshot" --arg head "$H" \
  '{operation:"plan",snapshot:$snapshot,classification:"Resolved",reviewer_login:"reviewer",thread_id:"PRRT_kwDOtest2",root_comment_id:200,verification_head_sha:$head}')"
assert_decision "multi-thread A reuses" "$multi_plan_a" reuse
assert_decision "multi-thread B reuses" "$multi_plan_b" reuse
multi_record_a="$(json_input unused --argjson plan "$multi_plan_a" --argjson snapshot "$multi_snapshot" --arg head "$H" \
  '{operation:"verify_reuse",plan:$plan,plan_snapshot:$snapshot,fresh_snapshot:$snapshot,verification_head_sha:$head}' | jq -c '.record')"
multi_record_b="$(json_input unused --argjson plan "$multi_plan_b" --argjson snapshot "$multi_snapshot" --arg head "$H" \
  '{operation:"verify_reuse",plan:$plan,plan_snapshot:$snapshot,fresh_snapshot:$snapshot,verification_head_sha:$head}' | jq -c '.record')"
assert_field "B record keeps a thread-scoped fingerprint" "$multi_record_b" '.verified_fingerprint' "$(jq -r '.snapshot.threads[1].thread_fingerprint' <<< "$multi_reconcile")"
multi_after_a="$(jq '.graphql.threads[0].resolved = true | . + {operation:"reconcile"}' "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" | "$HELPER" | jq -c '.snapshot')"
multi_after_ab="$(jq '.graphql.threads[0].resolved = true | .graphql.threads[1].resolved = true | . + {operation:"reconcile"}' "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" | "$HELPER" | jq -c '.snapshot')"
multi_resolve_a="$(json_input unused --argjson record "$multi_record_a" --argjson before "$multi_snapshot" --argjson after "$multi_after_a" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,transport_outcome:"ok"}')"
assert_decision "multi-thread A resolves by run" "$multi_resolve_a" resolved_by_run
multi_eligibility_b="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_after_a" --argjson run "$multi_resolve_a" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,this_run_resolve_records:[$run],current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "B remains eligible after verified A Resolve" "$multi_eligibility_b" eligible
multi_resolve_b="$(json_input unused --argjson record "$multi_record_b" --argjson before "$multi_after_a" --argjson after "$multi_after_ab" --argjson run "$multi_resolve_a" \
  '{operation:"resolve_post",record:$record,before_snapshot:$before,after_snapshot:$after,this_run_resolve_records:[$run],transport_outcome:"ok"}')"
assert_decision "B resolves after verified A Resolve" "$multi_resolve_b" resolved_by_run

multi_b_edit_raw="$TMP/multi-b-edit.json"
jq '.rest.items[3].body = "edited second evidence" | .graphql.threads[1].comments[1].body = "edited second evidence"' \
  "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_b_edit_raw"
multi_b_edit="$(jq '. + {operation:"reconcile"}' "$multi_b_edit_raw" | "$HELPER" | jq -c '.snapshot')"
multi_b_edit_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_b_edit" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "B edit fails closed" "$multi_b_edit_check" stop

multi_b_delete_raw="$TMP/multi-b-delete.json"
jq 'del(.rest.items[3], .graphql.threads[1].comments[1])' \
  "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_b_delete_raw"
multi_b_delete="$(jq '. + {operation:"reconcile"}' "$multi_b_delete_raw" | "$HELPER" | jq -c '.snapshot')"
multi_b_delete_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_b_delete" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "B deleted comment fails closed" "$multi_b_delete_check" stop

multi_b_identity_raw="$TMP/multi-b-identity.json"
jq '.graphql.threads[1].thread_id = "PRRT_other_identity"' \
  "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_b_identity_raw"
multi_b_identity="$(jq '. + {operation:"reconcile"}' "$multi_b_identity_raw" | "$HELPER" | jq -c '.snapshot')"
multi_b_identity_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_b_identity" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "B thread identity change fails closed" "$multi_b_identity_check" stop

multi_b_resolved_raw="$TMP/multi-b-resolved.json"
jq '.graphql.threads[1].resolved = true' "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_b_resolved_raw"
multi_b_resolved="$(jq '. + {operation:"reconcile"}' "$multi_b_resolved_raw" | "$HELPER" | jq -c '.snapshot')"
multi_b_resolved_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_b_resolved" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "B externally resolved is not eligible" "$multi_b_resolved_check" already_resolved_external
assert_field "B externally resolved has no target" "$multi_b_resolved_check" '.eligible' false

multi_other_edit_raw="$TMP/multi-other-edit.json"
jq '.rest.items[1].body = "edited first evidence" | .graphql.threads[0].comments[1].body = "edited first evidence"' \
  "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_other_edit_raw"
multi_other_edit="$(jq '. + {operation:"reconcile"}' "$multi_other_edit_raw" | "$HELPER" | jq -c '.snapshot')"
multi_other_edit_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_other_edit" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "unverified other-thread edit fails closed" "$multi_other_edit_check" stop

multi_other_resolved_raw="$TMP/multi-other-resolved.json"
jq '.graphql.threads[0].resolved = true' "$SCRIPT_DIR/fixtures/recheck-multi-thread.json" > "$multi_other_resolved_raw"
multi_other_resolved="$(jq '. + {operation:"reconcile"}' "$multi_other_resolved_raw" | "$HELPER" | jq -c '.snapshot')"
multi_other_resolved_check="$(json_input unused --argjson record "$multi_record_b" --argjson fresh "$multi_other_resolved" --arg head "$H" \
  '{operation:"resolve_eligibility",record:$record,fresh_snapshot:$fresh,current_head_sha:$head,lgtm_commit_id:$head,lgtm_verified:true}')"
assert_decision "unverified other-thread Resolve fails closed" "$multi_other_resolved_check" stop

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
