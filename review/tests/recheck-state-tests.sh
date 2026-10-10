#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/recheck-state.py"
FIXTURE="$SCRIPT_DIR/fixtures/recheck-snapshot.json"
NO_FINDINGS_SNAPSHOT="$SCRIPT_DIR/fixtures/no-findings-snapshot.json"
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

# reconcile: a snapshot with no thread is a normal value (an initial review
# with 0 findings posts no inline comment), not a read failure.  Incomplete
# pagination still stops under the same rule as a non-empty snapshot.
empty_reconcile="$(jq '. + {operation:"reconcile"}' "$NO_FINDINGS_SNAPSHOT" | "$HELPER")"
assert_decision "reconcile empty snapshot" "$empty_reconcile" ok
assert_field "reconcile empty snapshot stays canonical" "$empty_reconcile" '.snapshot.threads | length' 0
assert_field "reconcile empty snapshot drops pagination" "$empty_reconcile" '.snapshot | has("pagination")' false
empty_reconcile_bare="$(jq -nc '{operation:"reconcile",threads:[]}' | "$HELPER")"
assert_decision "reconcile empty snapshot without pagination" "$empty_reconcile_bare" ok
for invalid_pagination in '{"threads_complete":false,"comments_complete":true}' '{"threads_complete":true,"comments_complete":false}'; do
  empty_pagination="$(jq -nc --argjson pagination "$invalid_pagination" \
    '{operation:"reconcile",threads:[],pagination:$pagination}' | "$HELPER")"
  assert_decision "empty snapshot with incomplete pagination $invalid_pagination stops" "$empty_pagination" stop
  assert_field "empty snapshot pagination stop reason" "$empty_pagination" '.reason' snapshot_invalid
done

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

# plan: an empty snapshot has no thread to select, so the skill skips this step
# and goes to gate.  The stop reason is unchanged.
plan_empty="$(json_input unused --arg head "$H" \
  '{operation:"plan",snapshot:{threads:[]},classification:"Resolved",reviewer_login:"reviewer",verification_head_sha:$head}')"
assert_decision "plan on an empty snapshot stops" "$plan_empty" stop
assert_field "empty snapshot plan keeps its stop reason" "$plan_empty" '.reason' \
  'thread_id is required when snapshot has multiple threads'

# gate: derive the original Blocker set from the full initial snapshot, then
# validate coverage and record identity before evaluating the LGTM policy.
record="$(jq -nc --arg head "$H" '{thread_id:"PRRT_kwDOtest1",root_comment_id:100,reviewer_login:"reviewer",classification:"Resolved",classification_reply_id:101,verification_head_sha:$head}')"
# Reconcile the second thread too, so each gate fixture has a real canonical
# snapshot, including its original root label and its direct classification reply.
optional_reconcile="$(jq '. + {operation:"reconcile"} | .threads += [{
  thread_id:"T2",resolved:false,comments:[
    {id:"PRRC_optional",database_id:200,body:"**Consider**: optional finding",user:{login:"reviewer"},in_reply_to_id:null},
    {id:"PRRC_optional_reply",database_id:201,body:"**Unresolved** (**Consider**): still open",user:{login:"reviewer"},in_reply_to_id:"PRRC_optional"}
  ]
}]' <<< "$threads_only" | "$HELPER")"
assert_decision "reconcile optional thread fixture" "$optional_reconcile" ok
optional_snapshot="$(jq -c '.snapshot' <<< "$optional_reconcile")"
blocker_snapshot="$(jq -c '.threads[1].comments[0].body = "**Blocker**: second finding" |
  .threads[1].comments[1].body = "**Partial** (**Blocker**): one condition remains"' <<< "$optional_snapshot")"
optional_record="$(jq -nc --arg head "$H" '{thread_id:"T2",root_comment_id:200,reviewer_login:"reviewer",classification:"Unresolved",classification_reply_id:201,verification_head_sha:$head}')"
partial_record="$(jq -c '.classification = "Partial"' <<< "$optional_record")"
gate_input="$(jq -nc --argjson snapshot "$base_snapshot" --argjson record "$record" --arg head "$H" \
  '{operation:"gate",snapshot:$snapshot,reviewer_login:"reviewer",records:[$record],verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},round:2}')"

gate_case() {
  local name="$1" expected="$2" filter="$3" reason="${4:-}" output
  output="$(jq --argjson optional_snapshot "$optional_snapshot" --argjson blocker_snapshot "$blocker_snapshot" \
    --argjson optional_record "$optional_record" --argjson partial_record "$partial_record" \
    "$filter" <<< "$gate_input" | "$HELPER")"
  assert_decision "$name" "$output" "$expected"
  if [ -n "$reason" ]; then
    assert_field "$name reason" "$output" '.reason' "$reason"
  fi
}

gate_case_from() {
  local input="$1" name="$2" expected="$3" filter="$4" reason="${5:-}" output
  output="$(jq "$filter" <<< "$input" | "$HELPER")"
  assert_decision "$name" "$output" "$expected"
  if [ -n "$reason" ]; then
    assert_field "$name reason" "$output" '.reason' "$reason"
  fi
}

gate_clean="$("$HELPER" <<< "$gate_input")"
assert_decision "clean full review permits LGTM" "$gate_clean" lgtm_eligible
assert_field "LGTM records the fixed head" "$gate_clean" '.head_sha' "$H"
assert_field "LGTM records the reviewer root count" "$gate_clean" '.root_count' 1
assert_field "LGTM records the complete Blocker count" "$gate_clean" '.record_count' 1
assert_field "LGTM omits the prior review id without an empty snapshot" "$gate_clean" 'has("prior_review_id")' false

gate_case "missing snapshot stops" stop 'del(.snapshot)' snapshot_is_required
gate_case "missing reviewer stops" stop 'del(.reviewer_login)' invalid_reviewer_login
gate_case "missing both required inputs stops" stop 'del(.snapshot, .reviewer_login)'
for invalid_snapshot in 'null' '[]' '{}' '{canonical:null}' '{canonical:[]}'; do
  gate_case "invalid snapshot $invalid_snapshot stops" stop ".snapshot = $invalid_snapshot" snapshot_invalid
done
gate_case "incomplete snapshot stops" stop \
  '.snapshot.pagination = {threads_complete:true,comments_complete:false}' snapshot_invalid
for invalid_reviewer in 'null' '""' '[]'; do
  gate_case "invalid reviewer $invalid_reviewer stops" stop ".reviewer_login = $invalid_reviewer" invalid_reviewer_login
done
gate_case "reviewer without any root cannot pass with empty records" stop \
  '.reviewer_login = "someone-else" | .records = []' reviewer_root_missing
gate_case "reply authorship does not establish root authorship" stop \
  '.snapshot.threads[0].comments[0].actor = "someone-else" | .records = []' reviewer_root_missing

gate_case "missing original Blocker stops" stop '.records = []' blocker_record_mismatch
gate_case "one of two original Blockers omitted stops" stop \
  '.snapshot = $blocker_snapshot' blocker_record_mismatch
gate_case "missing coverage is checked before Partial" stop \
  '.snapshot = $blocker_snapshot | .records[0].classification = "Partial"' blocker_record_mismatch
gate_case "optional record mixed into Blocker records stops" stop \
  '.snapshot = $optional_snapshot | .records += [$optional_record]' blocker_record_mismatch
gate_case "same count with an optional root substituted stops" stop \
  '.snapshot = $optional_snapshot | .records = [$optional_record | .classification = "Resolved"]' blocker_record_mismatch
gate_mismatch="$(jq --argjson snapshot "$optional_snapshot" --argjson record "$optional_record" \
  '.snapshot = $snapshot | .records = [$record | .classification = "Resolved"]' <<< "$gate_input" | "$HELPER")"
assert_field "coverage mismatch reports the omitted root" "$gate_mismatch" '.missing_root_comment_ids | join(",")' 100
assert_field "coverage mismatch reports the unexpected root" "$gate_mismatch" '.unexpected_root_comment_ids | join(",")' 200
gate_case "all original Blockers resolved permits LGTM" lgtm_eligible \
  '.snapshot = $blocker_snapshot | .records += [$partial_record | .classification = "Resolved" | .classification_reply_id = 202]'
gate_case "record order does not affect coverage" lgtm_eligible \
  '.snapshot = $blocker_snapshot | .records += [$partial_record | .classification = "Resolved" | .classification_reply_id = 202] | .records |= reverse'
for label in Nit Consider FYI; do
  gate_case "original $label is not a Blocker" lgtm_eligible \
    ".snapshot.threads[0].comments[0].body = \"**$label**: optional finding\" | .records = []"
done
gate_case "resolved original Blocker is excluded" lgtm_eligible \
  '.snapshot.threads[0].resolved = true | .records = []'
gate_case "record for an already-resolved Blocker stops" stop \
  '.snapshot.threads[0].resolved = true' blocker_record_mismatch
gate_case "another reviewer's Blocker is excluded" lgtm_eligible \
  '.snapshot = $blocker_snapshot | .snapshot.threads[1].comments[0].actor = "someone-else"'
gate_case "Blocker label in a reply is not a root finding" lgtm_eligible \
  '.snapshot.threads[0].comments[0].body = "**FYI**: reference" |
   .snapshot.threads[0].comments[1].body = "**Blocker**: not a root" | .records = []'

gate_case "duplicate original Blocker record stops" stop '.records += .records' duplicate_record_root
gate_case "record thread mismatch stops" stop '.records[0].thread_id = "T2"' record_thread_mismatch
gate_case "record reviewer mismatch stops" stop '.records[0].reviewer_login = "someone-else"' record_reviewer_mismatch
gate_case "record head mismatch stops" stop \
  '.verification_head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' record_head_mismatch
gate_case "missing verification head stops" stop 'del(.verification_head_sha)' verification_head_sha_missing
gate_case "missing records stops" stop 'del(.records)' records_are_required
gate_case "records must be an array" stop '.records = {}' records_are_required
gate_case "record must be an object" stop '.records = [null]'
for field in thread_id root_comment_id reviewer_login classification classification_reply_id verification_head_sha; do
  gate_case "record missing $field stops" stop "del(.records[0].$field)"
done
for field in thread_id reviewer_login verification_head_sha; do
  for invalid_value in 'null' '""' '[]'; do
    gate_case "record $field=$invalid_value stops" stop ".records[0].$field = $invalid_value"
  done
done
for field in root_comment_id classification_reply_id; do
  for invalid_id in 'null' '0' '-1' 'true' '100.5' '"100"' '[]'; do
    gate_case "record $field=$invalid_id stops" stop ".records[0].$field = $invalid_id"
  done
done
gate_case "invalid classification type stops" stop '.records[0].classification = []'
gate_case "invalid classification value stops" stop '.records[0].classification = "resolved"'
gate_case "Partial record still requires a verified reply" stop \
  '.records[0].classification = "Partial" | del(.records[0].classification_reply_id)'

gate_case "remaining Blocker blocks LGTM" blocked \
  '.full_review.clean = false | .full_review.blockers = 1' full_review_not_clean
for classification in Partial Unresolved Unknown; do
  gate_case "$classification record blocks LGTM" blocked \
    ".records[0].classification = \"$classification\"" classification_not_resolved
done
gate_case "Partial second Blocker blocks LGTM" blocked \
  '.snapshot = $blocker_snapshot | .records += [$partial_record]' classification_not_resolved
# Keep optional records for reporting/Resolve, but pass only original Blocker
# records; the helper independently verifies this selection against the snapshot.
classified="$(jq -nc --argjson blocker "$record" --argjson optional "$optional_record" '[{root_label:"Blocker",record:$blocker},{root_label:"Consider",record:$optional}]')"
mandatory="$(jq -c '[.[] | select(.root_label == "Blocker") | .record]' <<< "$classified")"
gate_optional_open="$(jq --argjson snapshot "$optional_snapshot" --argjson records "$mandatory" \
  '.snapshot = $snapshot | .records = $records' <<< "$gate_input" | "$HELPER")"
assert_decision "unresolved optional finding does not block mandatory gate" "$gate_optional_open" lgtm_eligible
assert_field "optional classification remains available outside gate" "$(jq -nc --argjson classified "$classified" '{count:($classified | length)}')" '.count' 2
gate_case "important unknowns block LGTM" blocked '.full_review.important_unknowns = 1' full_review_not_clean
gate_case "missing full review blocks LGTM" blocked 'del(.full_review)' full_review_not_clean
gate_case "invalid full review stops" stop '.full_review = []' full_review_is_invalid
gate_case "clean Round 3 permits LGTM planning" lgtm_eligible '.round = 3'
gate_case "Round 3 with a remaining Blocker blocks LGTM" blocked \
  '.round = 3 | .blocker_remaining = true' round_limit

# gate: a snapshot with no thread is normal when the initial review posted no
# inline finding (`0 findings`).  Reviewer identity then comes from the
# reviews.read projection passed as prior_review, and the record and
# full_review checks still run: an empty snapshot never short-circuits them.
empty_gate_input="$(jq -nc --arg head "$H" \
  '{operation:"gate",snapshot:{threads:[]},reviewer_login:"reviewer",records:[],verification_head_sha:$head,full_review:{clean:true,blockers:0,important_unknowns:0},prior_review:{review_id:5477253768,commit_id:$head,reviewer_login:"reviewer"}}')"
empty_gate_clean="$("$HELPER" <<< "$empty_gate_input")"
assert_decision "empty snapshot with a matching prior review permits LGTM" "$empty_gate_clean" lgtm_eligible
assert_field "empty snapshot LGTM records the fixed head" "$empty_gate_clean" '.head_sha' "$H"
assert_field "empty snapshot LGTM reports no reviewer root" "$empty_gate_clean" '.root_count' 0
assert_field "empty snapshot LGTM reports no record" "$empty_gate_clean" '.record_count' 0
assert_field "empty snapshot LGTM returns the prior review id" "$empty_gate_clean" '.prior_review_id' 5477253768

gate_case_from "$empty_gate_input" "missing prior review stops" stop 'del(.prior_review)' prior_review_is_required
gate_case_from "$empty_gate_input" "prior review must be an object" stop '.prior_review = []' prior_review_invalid
gate_case_from "$empty_gate_input" "null prior review is not a prior review" stop '.prior_review = null' prior_review_invalid
for invalid_review_id in '"5477253768"' '0' '-1' 'true' '5477253768.5' '[]' 'null'; do
  gate_case_from "$empty_gate_input" "prior review_id=$invalid_review_id is invalid" stop \
    ".prior_review.review_id = $invalid_review_id" prior_review_invalid
done
for invalid_commit in '""' '"547726035"' '"0123456789abcdef0123456789abcdef0123456z"' 'null' '[]'; do
  gate_case_from "$empty_gate_input" "prior review commit_id=$invalid_commit is invalid" stop \
    ".prior_review.commit_id = $invalid_commit" prior_review_invalid
done
for invalid_prior_login in '""' 'null' '[]'; do
  gate_case_from "$empty_gate_input" "prior review reviewer_login=$invalid_prior_login is invalid" stop \
    ".prior_review.reviewer_login = $invalid_prior_login" prior_review_invalid
done
gate_case_from "$empty_gate_input" "prior review login mismatch stops" stop \
  '.prior_review.reviewer_login = "someone-else"' prior_review_reviewer_mismatch

gate_case_from "$empty_gate_input" "missing records stops on an empty snapshot" stop 'del(.records)' records_are_required
gate_case_from "$empty_gate_input" "records must be an array on an empty snapshot" stop '.records = {}' records_are_required
gate_case_from "$empty_gate_input" "missing verification head stops on an empty snapshot" stop 'del(.verification_head_sha)' verification_head_sha_missing
gate_case_from "$empty_gate_input" "unclean full review blocks on an empty snapshot" blocked '.full_review.clean = false' full_review_not_clean
gate_case_from "$empty_gate_input" "remaining Blocker blocks on an empty snapshot" blocked '.full_review.blockers = 1' full_review_not_clean
gate_case_from "$empty_gate_input" "important unknown blocks on an empty snapshot" blocked '.full_review.important_unknowns = 1' full_review_not_clean
gate_case_from "$empty_gate_input" "round limit blocks on an empty snapshot" blocked '.round = 3 | .blocker_remaining = true' round_limit
empty_gate_record="$(jq --argjson record "$record" '.records = [$record]' <<< "$empty_gate_input" | "$HELPER")"
assert_decision "a record without a thread stops on an empty snapshot" "$empty_gate_record" stop
assert_field "empty snapshot reports the record mismatch" "$empty_gate_record" '.reason' blocker_record_mismatch
assert_field "empty snapshot reports the unexpected root id" "$empty_gate_record" '.unexpected_root_comment_ids | join(",")' 100
assert_field "empty snapshot reports no missing root" "$empty_gate_record" '.missing_root_comment_ids | length' 0

# A prior_review passed with a non-empty snapshot is not consulted, so a skill
# that always sends it cannot change the decision.
gate_case "prior review is ignored when the snapshot has threads" lgtm_eligible \
  '.prior_review = {review_id:0,commit_id:"short",reviewer_login:"someone-else"}'

echo "PASS: $pass_count recheck state helper cases"
