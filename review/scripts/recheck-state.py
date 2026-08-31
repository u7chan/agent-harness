#!/usr/bin/env python3
"""Pure, deterministic checks used by the review re-check workflow.

The review skill owns the decision to re-evaluate a finding, the decision to
post a classification reply, and the decision to post an LGTM.  This
executable only turns already-collected JSON snapshots into safe, reproducible
decisions.  It deliberately has no network, clock, or persistent-state
dependency.

Input is one JSON object.  The ``operation`` member selects one of the small
operations documented in ``review/references/recheck.md``.  Valid operations
always print one JSON object and exit zero; a decision of ``stop`` is an
expected fail-closed result, not a transport error.
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any


SCHEMA_VERSION = 1
CLASSIFICATIONS = {"Resolved", "Partial", "Unresolved", "Unknown"}


def fail(message: str) -> int:
    print(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "status": "failed",
                "error": {"code": "INVALID_INPUT", "message": message},
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 2


def emit(operation: str, **values: Any) -> int:
    result = {"schema_version": SCHEMA_VERSION, "status": "ok", "operation": operation}
    result.update(values)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


def stop(operation: str, reason: str, **values: Any) -> int:
    return emit(operation, decision="stop", reason=reason, **values)


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def first_present(obj: dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in obj:
            return obj[name]
    return default


def login_from(value: Any) -> Any:
    if isinstance(value, dict):
        return first_present(value, "login", default=None)
    return value


def normalize_comment(raw: Any) -> tuple[dict[str, Any] | None, str | None]:
    """Normalize one review-threads.read comment shape.

    The action exposes the GraphQL node ID as ``id``, the REST numeric ID as
    ``database_id``, the reply target as the parent node ID in
    ``in_reply_to_id``, and the actor as ``user.login``.  Older fixtures may
    use ``author_login`` / ``reply_to_id`` instead; accept both, keeping the
    GraphQL node ID as the topology identity.
    """
    if not isinstance(raw, dict):
        return None, "comment is not an object"

    node_id = first_present(raw, "id", "node_id", default=None)
    database_id = first_present(raw, "database_id", "databaseId", "comment_id", default=None)
    reply_to = first_present(
        raw, "in_reply_to_id", "reply_to_id", "reply_to_comment_id", "replyToId", default=None
    )
    body = first_present(raw, "body", default=None)
    actor = first_present(raw, "author_login", "user_login", "actor", default=None)
    if actor is None:
        actor = login_from(first_present(raw, "user", "author", default=None))
    path = first_present(raw, "path", default=None)
    line = first_present(raw, "line", default=None)
    commit_id = first_present(raw, "commit_id", "commit_oid", default=None)
    created_at = first_present(raw, "created_at", "createdAt", default=None)
    updated_at = first_present(raw, "updated_at", "updatedAt", default=None)

    if not isinstance(node_id, str) or not node_id:
        return None, "comment is missing the GraphQL node id"
    if not is_int(database_id) or database_id <= 0:
        return None, "comment is missing a positive database_id"
    if not isinstance(body, str):
        return None, "comment body is not a string"
    if not isinstance(actor, str) or not actor:
        return None, "comment actor is missing"
    if reply_to is not None and not isinstance(reply_to, str):
        return None, "comment reply target is not a string or null"
    if path is not None and not isinstance(path, str):
        return None, "comment path is not a string"
    if line is not None and not is_int(line):
        return None, "comment line is not an integer or null"
    if commit_id is not None and not isinstance(commit_id, str):
        return None, "comment commit id is not a string"
    for timestamp_name, timestamp in (("created_at", created_at), ("updated_at", updated_at)):
        if timestamp is not None and not isinstance(timestamp, str):
            return None, f"comment {timestamp_name} is not a string or null"

    return {
        "node_id": node_id,
        "comment_id": database_id,
        "body": body,
        "actor": actor,
        "reply_to_comment_id": reply_to,
        "path": path,
        "line": line,
        "commit_id": commit_id,
        "created_at": created_at,
        "updated_at": updated_at,
    }, None


def normalize_thread(raw: Any, seen_ids: set[int], seen_node_ids: set[str]) -> tuple[dict[str, Any] | None, str | None]:
    if not isinstance(raw, dict):
        return None, "thread is not an object"
    thread_id = first_present(raw, "thread_id", "id", default=None)
    if not isinstance(thread_id, str) or not thread_id:
        return None, "thread is missing id"
    resolved = first_present(raw, "resolved", "is_resolved", "isResolved", default=None)
    if not isinstance(resolved, bool):
        return None, f"thread {thread_id} has an invalid resolved state"

    raw_comments = first_present(raw, "comments", default=None)
    if isinstance(raw_comments, dict):
        raw_comments = raw_comments.get("nodes")
    if not isinstance(raw_comments, list) or not raw_comments:
        return None, f"thread {thread_id} has no comments"

    comments: list[dict[str, Any]] = []
    for raw_comment in raw_comments:
        comment, error = normalize_comment(raw_comment)
        if error:
            return None, error
        assert comment is not None
        if comment["node_id"] in seen_node_ids:
            return None, f"duplicate GraphQL comment node id {comment['node_id']}"
        if comment["comment_id"] in seen_ids:
            return None, f"duplicate comment database id {comment['comment_id']}"
        seen_node_ids.add(comment["node_id"])
        seen_ids.add(comment["comment_id"])
        comments.append(comment)

    by_node = {comment["node_id"]: comment for comment in comments}
    roots = [comment for comment in comments if comment["reply_to_comment_id"] is None]
    if len(roots) != 1:
        return None, f"thread {thread_id} does not have exactly one root comment"
    root = roots[0]
    for comment in comments:
        reply_to = comment["reply_to_comment_id"]
        if reply_to is None:
            continue
        if reply_to not in by_node:
            return None, f"comment {comment['comment_id']} reply target is absent"
        if reply_to != root["node_id"]:
            return None, f"comment {comment['comment_id']} is not a direct root reply"

    return {
        "thread_id": thread_id,
        "resolved": resolved,
        "root_comment_id": root["comment_id"],
        "tail_comment_id": comments[-1]["comment_id"],
        "comments": comments,
    }, None


def threads_from(value: Any) -> tuple[list[dict[str, Any]] | None, str | None, bool]:
    """Accept review-threads.read output (``{threads, pagination}``), a raw
    threads array, or the fixture ``{graphql: {threads}}`` shape."""
    if isinstance(value, dict) and "graphql" in value:
        value = value["graphql"]
    if isinstance(value, dict) and "threads" in value:
        pagination = value.get("pagination", {})
        if not isinstance(pagination, dict):
            return None, "pagination is not an object", False
        for flag_name, flag in pagination.items():
            if not isinstance(flag, bool):
                return None, f"pagination flag {flag_name} is not boolean", False
            if flag is False:
                return None, f"{flag_name} is false", False
        value = value["threads"]
    if not isinstance(value, list):
        return None, "threads must be an array or an object with a threads array", False
    return value, None, True


def snapshot_from(value: Any) -> tuple[dict[str, Any] | None, str | None]:
    """Normalize the read state into one canonical thread snapshot."""
    if not isinstance(value, dict):
        return None, "snapshot is not an object"
    if "canonical" in value:
        value = value["canonical"]
    if "snapshot" in value and isinstance(value["snapshot"], dict):
        value = value["snapshot"]

    if not ("threads" in value or "graphql" in value):
        return None, "threads are required"
    raw_threads, error, _ = threads_from(value)
    if error is not None:
        return None, error
    assert raw_threads is not None

    seen_ids: set[int] = set()
    seen_node_ids: set[str] = set()
    seen_threads: set[str] = set()
    threads: list[dict[str, Any]] = []
    for raw_thread in raw_threads:
        thread, error = normalize_thread(raw_thread, seen_ids, seen_node_ids)
        if error:
            return None, error
        assert thread is not None
        if thread["thread_id"] in seen_threads:
            return None, f"duplicate thread id {thread['thread_id']}"
        seen_threads.add(thread["thread_id"])
        threads.append(thread)
    if not threads:
        return None, "snapshot has no threads"
    return {"threads": threads}, None


def thread_for(snapshot: dict[str, Any], thread_id: Any) -> dict[str, Any] | None:
    candidates = [thread for thread in snapshot["threads"] if thread.get("thread_id") == thread_id]
    return candidates[0] if len(candidates) == 1 else None


def classification_from_body(body: Any) -> dict[str, str] | None:
    if not isinstance(body, str):
        return None
    # The first line is intentionally strict.  No trim, quote, code fence,
    # case-folding, legacy lower-case label, or second-line recognition.
    match = re.fullmatch(r"\*\*(Resolved|Unknown)\*\*: ([^\r\n]+)(?:\r?\n.*)?", body, re.DOTALL)
    if match:
        return {"classification": match.group(1)}
    match = re.fullmatch(
        r"\*\*(Partial|Unresolved)\*\* \(\*\*(Blocker|Nit|Consider|FYI)\*\*\): ([^\r\n]+)(?:\r?\n.*)?",
        body,
        re.DOTALL,
    )
    if match:
        return {"classification": match.group(1), "label": match.group(2)}
    return None


def valid_classification(value: Any) -> bool:
    return isinstance(value, str) and value in CLASSIFICATIONS


def select_thread(snapshot: dict[str, Any], requested: Any) -> tuple[dict[str, Any] | None, str | None]:
    if requested is not None:
        thread = thread_for(snapshot, requested)
        if thread is None:
            return None, "thread is missing or not unique"
        return thread, None
    if len(snapshot["threads"]) != 1:
        return None, "thread_id is required when snapshot has multiple threads"
    return snapshot["threads"][0], None


def root_and_tail(
    thread: dict[str, Any], root_comment_id: Any = None
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str | None]:
    roots = [comment for comment in thread["comments"] if comment.get("reply_to_comment_id") is None]
    if len(roots) != 1:
        return None, None, "thread does not have a unique root"
    root = roots[0]
    if root_comment_id is not None and root["comment_id"] != root_comment_id:
        return None, None, "root comment id does not match snapshot"
    return root, thread["comments"][-1], None


def operation_parse(input_data: dict[str, Any]) -> int:
    body = input_data.get("body")
    parsed = classification_from_body(body)
    if parsed is None:
        return emit("parse", decision="not_classification", classification=None)
    return emit("parse", decision="classification", **parsed)


def operation_reconcile(input_data: dict[str, Any]) -> int:
    snapshot, error = snapshot_from(input_data)
    if error:
        return stop("reconcile", "snapshot_invalid", detail=error)
    assert snapshot is not None
    return emit("reconcile", decision="ok", snapshot=snapshot)


def operation_plan(input_data: dict[str, Any]) -> int:
    snapshot, error = snapshot_from(first_present(input_data, "snapshot", "baseline", default=input_data))
    if error:
        return stop("plan", "snapshot_invalid", detail=error)
    assert snapshot is not None
    classification = input_data.get("classification")
    reviewer = input_data.get("reviewer_login")
    if not valid_classification(classification):
        return stop("plan", "invalid_classification")
    if not isinstance(reviewer, str) or not reviewer:
        return stop("plan", "invalid_reviewer_login")
    thread, error = select_thread(snapshot, input_data.get("thread_id"))
    if error:
        return stop("plan", error)
    assert thread is not None
    root, tail, error = root_and_tail(thread, input_data.get("root_comment_id"))
    if error:
        return stop("plan", error)
    assert root is not None and tail is not None
    if root["actor"] != reviewer:
        return stop("plan", "root_actor_mismatch")
    if thread["resolved"]:
        return stop("plan", "thread_already_resolved")

    verification_head_sha = input_data.get("verification_head_sha", input_data.get("head_sha"))
    if not isinstance(verification_head_sha, str) or not verification_head_sha:
        return stop("plan", "verification_head_sha_missing_or_invalid")

    common = {
        "thread_id": thread["thread_id"],
        "root_comment_id": root["comment_id"],
        "reviewer_login": reviewer,
        "classification": classification,
        "verification_head_sha": verification_head_sha,
        "tail_comment_id": tail["comment_id"],
    }
    # A tail reply by the same reviewer to the same root with the same
    # classification is the plan-level dedup: the reply is already applied.
    tail_parsed = classification_from_body(tail["body"])
    reusable = (
        tail["comment_id"] != root["comment_id"]
        and tail["actor"] == reviewer
        and tail.get("reply_to_comment_id") == root["node_id"]
        and tail_parsed is not None
        and tail_parsed.get("classification") == classification
    )
    if reusable:
        return emit("plan", decision="reuse", anchor_id=tail["comment_id"], **common)
    return emit("plan", decision="post", anchor_id=None, **common)


def check_record(record: Any) -> tuple[dict[str, Any] | None, str | None]:
    if not isinstance(record, dict):
        return None, "record is not an object"
    required = {
        "thread_id",
        "root_comment_id",
        "reviewer_login",
        "classification",
        "classification_reply_id",
        "verification_head_sha",
    }
    missing = sorted(field for field in required if field not in record)
    if missing:
        return None, f"record is missing fields: {', '.join(missing)}"
    if record["classification"] not in CLASSIFICATIONS:
        return None, "record has an invalid classification"
    if not isinstance(record["classification_reply_id"], int) or record["classification_reply_id"] <= 0:
        return None, "record has an invalid classification reply id"
    return record, None


def operation_gate(input_data: dict[str, Any]) -> int:
    records = input_data.get("records")
    if not isinstance(records, list):
        return stop("gate", "records_are_required")
    head = input_data.get("verification_head_sha", input_data.get("head_sha"))
    if not isinstance(head, str) or not head:
        return stop("gate", "verification_head_sha_missing")
    for record_value in records:
        if isinstance(record_value, dict) and record_value.get("classification") in {"Partial", "Unresolved", "Unknown"}:
            return emit("gate", decision="blocked", eligible=False, reason="classification_not_resolved")
        record, error = check_record(record_value)
        if error:
            return stop("gate", error)
        assert record is not None
        if record["verification_head_sha"] != head:
            return stop("gate", "record_head_mismatch")

    full_review = input_data.get("full_review", {})
    if not isinstance(full_review, dict):
        return stop("gate", "full_review_is_invalid")
    clean = full_review.get("clean", input_data.get("full_review_clean", False))
    blockers = full_review.get("blockers", 0)
    important_unknowns = full_review.get("important_unknowns", full_review.get("unknowns", 0))
    if clean is not True or blockers != 0 or important_unknowns != 0:
        return emit("gate", decision="blocked", eligible=False, reason="full_review_not_clean")
    if input_data.get("round") == 3 and input_data.get("blocker_remaining", False):
        return emit("gate", decision="blocked", eligible=False, reason="round_limit")
    return emit(
        "gate",
        decision="lgtm_eligible",
        eligible=True,
        head_sha=head,
        record_count=len(records),
    )


OPERATIONS = {
    "parse": operation_parse,
    "reconcile": operation_reconcile,
    "plan": operation_plan,
    "gate": operation_gate,
}


def main() -> int:
    try:
        raw = sys.stdin.read() if len(sys.argv) == 1 else open(sys.argv[1], encoding="utf-8").read()
        data = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"input is not valid JSON: {exc}")
    if not isinstance(data, dict):
        return fail("input must be a JSON object")
    operation = data.get("operation")
    if operation not in OPERATIONS:
        return fail(f"unknown operation: {operation}")
    return OPERATIONS[operation](data)


if __name__ == "__main__":
    sys.exit(main())
