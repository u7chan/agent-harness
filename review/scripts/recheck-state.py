#!/usr/bin/env python3
"""Pure, deterministic checks used by the review re-check workflow.

The review skill owns the decision to re-evaluate a finding and the decision to
post an LGTM.  This executable only turns already-collected JSON snapshots into
safe, reproducible decisions.  It deliberately has no network, clock, or
persistent-state dependency.

Input is one JSON object.  The ``operation`` member selects one of the small
operations documented in ``review/references/recheck.md``.  Valid operations
always print one JSON object and exit zero; a decision of ``stop`` is an
expected fail-closed result, not a transport error.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from copy import deepcopy
from typing import Any, Iterable


SCHEMA_VERSION = 1
CLASSIFICATIONS = {"Resolved", "Partial", "Unresolved", "Unknown"}
SEVERITIES = {"Blocker", "Nit", "Consider", "FYI"}
MATERIALIZATION_STATES = {
    "new_reply_verified",
    "reused_reply_verified",
    "already_applied_reply_verified",
}


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


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def json_hash(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256_text(encoded)


def comment_fingerprint_material(comment: dict[str, Any]) -> dict[str, Any]:
    return {
        "comment_id": comment["comment_id"],
        "node_id": comment["node_id"],
        "actor": comment["actor"],
        "reply_to_comment_id": comment["reply_to_comment_id"],
        "reply_to_node_id": comment["reply_to_node_id"],
        "body_hash": comment["body_hash"],
        "path": comment["path"],
        "line": comment["line"],
        "commit_id": comment["commit_id"],
        "created_at": comment["created_at"],
        "updated_at": comment["updated_at"],
        "last_edited_at": comment["last_edited_at"],
    }


def thread_fingerprint_material(thread: dict[str, Any]) -> dict[str, Any]:
    return {
        "thread_id": thread["thread_id"],
        "resolved": thread["resolved"],
        "comments": [comment_fingerprint_material(comment) for comment in thread["comments"]],
    }


def thread_fingerprint(thread: dict[str, Any]) -> str:
    """Hash one thread without depending on any other PR thread."""
    return json_hash(thread_fingerprint_material(thread))


def first_present(obj: dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in obj:
            return obj[name]
    return default


def nested_present(obj: dict[str, Any], *paths: tuple[str, ...], default: Any = None) -> Any:
    for path in paths:
        current: Any = obj
        found = True
        for key in path:
            if not isinstance(current, dict) or key not in current:
                found = False
                break
            current = current[key]
        if found:
            return current
    return default


def login_from(value: Any, *, graphql: bool) -> Any:
    if isinstance(value, dict):
        return first_present(value, "login", default=None)
    return value


def normalize_time(value: Any) -> Any:
    if value is None:
        return None
    return value if isinstance(value, str) else "__invalid__"


def normalize_line(value: Any) -> Any:
    if value is None:
        return None
    return value if is_int(value) else "__invalid__"


def normalize_comment_common(raw: Any, *, graphql: bool) -> tuple[dict[str, Any] | None, str | None]:
    if not isinstance(raw, dict):
        return None, "comment is not an object"

    if graphql:
        node_id = first_present(raw, "id", default=None)
        database_id = first_present(raw, "database_id", "databaseId", default=None)
        # ``review-threads.read`` exposes the GraphQL node's reply target as
        # ``in_reply_to_id`` and the actor as ``user.login``.  The raw
        # GraphQL response and older fixtures use ``reply_to_id`` and
        # ``author_login`` instead.  Accept both representations, but keep
        # the GraphQL node ID as the authoritative topology value.
        reply_to_node = first_present(
            raw, "reply_to_id", "reply_to_node_id", "in_reply_to_id", "replyToId", default=None
        )
        body = first_present(raw, "body", default=None)
        actor = first_present(raw, "author_login", default=None)
        if actor is None:
            actor = first_present(raw, "user_login", default=None)
        if actor is None:
            actor = login_from(first_present(raw, "author", "user", default=None), graphql=True)
        commit_id = first_present(raw, "commit_id", "commit_oid", default=None)
        path = first_present(raw, "path", default=None)
        line = first_present(raw, "line", default=None)
        created_at = first_present(raw, "created_at", "createdAt", default=None)
        updated_at = first_present(raw, "updated_at", "updatedAt", default=None)
        last_edited_at = first_present(raw, "last_edited_at", "lastEditedAt", default=None)
    else:
        node_id = first_present(raw, "node_id", "nodeId", default=None)
        database_id = first_present(raw, "id", default=None)
        reply_to_node = None
        body = first_present(raw, "body", default=None)
        actor = first_present(raw, "user_login", default=None)
        if actor is None:
            actor = login_from(first_present(raw, "user", default=None), graphql=False)
        reply_to_rest = first_present(raw, "in_reply_to_id", "reply_to_id", "replyToId", default=None)
        commit_id = first_present(raw, "commit_id", "commit_oid", default=None)
        path = first_present(raw, "path", default=None)
        line = first_present(raw, "line", default=None)
        created_at = first_present(raw, "created_at", "createdAt", default=None)
        updated_at = first_present(raw, "updated_at", "updatedAt", default=None)
        last_edited_at = first_present(raw, "last_edited_at", "lastEditedAt", default=None)

    if graphql:
        if not isinstance(node_id, str) or not node_id:
            return None, "GraphQL comment is missing id"
        if not is_int(database_id) or database_id <= 0:
            return None, "GraphQL comment is missing a positive database_id"
    else:
        if not is_int(database_id) or database_id <= 0:
            return None, "REST comment is missing a positive id"
        if node_id is not None and (not isinstance(node_id, str) or not node_id):
            return None, "REST comment has an invalid node_id"

    if not isinstance(body, str):
        return None, "comment body is not a string"
    if not isinstance(actor, str) or not actor:
        return None, "comment actor is missing"
    if path is not None and not isinstance(path, str):
        return None, "comment path is not a string"
    line = normalize_line(line)
    if line == "__invalid__":
        return None, "comment line is not an integer or null"
    for timestamp_name, timestamp in (
        ("created_at", created_at),
        ("updated_at", updated_at),
        ("last_edited_at", last_edited_at),
    ):
        normalized = normalize_time(timestamp)
        if normalized == "__invalid__":
            return None, f"comment {timestamp_name} is not a string or null"
        if timestamp_name == "created_at":
            created_at = normalized
        elif timestamp_name == "updated_at":
            updated_at = normalized
        else:
            last_edited_at = normalized
    if commit_id is not None and not isinstance(commit_id, str):
        return None, "comment commit id is not a string"

    return {
        "node_id": node_id,
        "database_id": database_id,
        "body": body,
        "actor": actor,
        "reply_to_node_id": reply_to_node if graphql else None,
        "reply_to_database_id": (reply_to_rest if not graphql else None),
        "path": path,
        "line": line,
        "commit_id": commit_id,
        "created_at": created_at,
        "updated_at": updated_at,
        "last_edited_at": last_edited_at,
    }, None


def collection_values(value: Any, *, key: str) -> tuple[list[Any], bool, bool]:
    """Return collection, complete flag, and whether a complete flag was explicit."""
    if isinstance(value, list):
        return value, True, False
    if not isinstance(value, dict):
        raise ValueError(f"{key} collection is not an array or object")
    if "items" in value:
        items = value["items"]
    elif key in value:
        items = value[key]
    elif key == "rest" and "comments" in value:
        items = value["comments"]
    elif key == "graphql" and "threads" in value:
        items = value["threads"]
    else:
        raise ValueError(f"{key} collection is missing items")
    if not isinstance(items, list):
        raise ValueError(f"{key} collection items is not an array")
    complete = value.get("complete", True)
    explicit = "complete" in value
    if not isinstance(complete, bool):
        raise ValueError(f"{key}.complete is not boolean")
    return items, complete, explicit


def has_next_page(value: dict[str, Any]) -> bool:
    page_info = first_present(value, "comments_pageInfo", "pageInfo", default=None)
    return isinstance(page_info, dict) and page_info.get("hasNextPage") is True


def reconcile(raw_input: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    rest_value = first_present(raw_input, "rest", "rest_comments", default=None)
    graphql_value = first_present(raw_input, "graphql", "graphql_threads", default=None)
    if rest_value is None or graphql_value is None:
        return None, "both REST comments and GraphQL threads are required"

    try:
        rest_items, rest_complete, _ = collection_values(rest_value, key="rest")
        graphql_threads, graphql_complete, _ = collection_values(graphql_value, key="graphql")
    except ValueError as exc:
        return None, str(exc)

    for collection_name, collection_value in (("rest", rest_value), ("graphql", graphql_value)):
        if isinstance(collection_value, dict) and isinstance(collection_value.get("pagination"), dict):
            if any(value is False for value in collection_value["pagination"].values()):
                return None, f"{collection_name} pagination is incomplete"
    if not rest_complete or not graphql_complete:
        return None, "pagination is incomplete"

    rest_comments: list[dict[str, Any]] = []
    rest_by_id: dict[int, dict[str, Any]] = {}
    for raw in rest_items:
        comment, error = normalize_comment_common(raw, graphql=False)
        if error:
            return None, error
        assert comment is not None
        cid = comment["database_id"]
        if cid in rest_by_id:
            return None, f"duplicate REST comment id {cid}"
        rest_by_id[cid] = comment
        rest_comments.append(comment)

    normalized_threads: list[dict[str, Any]] = []
    seen_threads: set[str] = set()
    seen_node_ids: set[str] = set()
    seen_database_ids: set[int] = set()
    membership: dict[int, str] = {}

    for raw_thread in graphql_threads:
        if not isinstance(raw_thread, dict):
            return None, "GraphQL thread is not an object"
        thread_id = first_present(raw_thread, "thread_id", "id", default=None)
        if not isinstance(thread_id, str) or not thread_id:
            return None, "GraphQL thread is missing id"
        if thread_id in seen_threads:
            return None, f"duplicate GraphQL thread id {thread_id}"
        seen_threads.add(thread_id)

        if "resolved" in raw_thread:
            resolved = raw_thread["resolved"]
        elif "is_resolved" in raw_thread:
            resolved = raw_thread["is_resolved"]
        elif "isResolved" in raw_thread:
            resolved = raw_thread["isResolved"]
        else:
            return None, f"thread {thread_id} is missing resolved state"
        if not isinstance(resolved, bool):
            return None, f"thread {thread_id} has an invalid resolved state"
        if has_next_page(raw_thread):
            return None, f"thread {thread_id} comment pagination is incomplete"

        raw_comments = first_present(raw_thread, "comments", default=None)
        if isinstance(raw_comments, dict):
            if raw_comments.get("pageInfo", {}).get("hasNextPage") is True:
                return None, f"thread {thread_id} comment pagination is incomplete"
            raw_comments = raw_comments.get("nodes")
        if not isinstance(raw_comments, list) or not raw_comments:
            return None, f"thread {thread_id} has no comments"

        comments: list[dict[str, Any]] = []
        for raw_comment in raw_comments:
            comment, error = normalize_comment_common(raw_comment, graphql=True)
            if error:
                return None, error
            assert comment is not None
            node_id = comment["node_id"]
            database_id = comment["database_id"]
            if node_id in seen_node_ids:
                return None, f"duplicate GraphQL comment node id {node_id}"
            if database_id in seen_database_ids:
                return None, f"duplicate GraphQL database id {database_id}"
            seen_node_ids.add(node_id)
            seen_database_ids.add(database_id)
            if database_id not in rest_by_id:
                return None, f"GraphQL comment {database_id} is absent from REST snapshot"
            if database_id in membership:
                return None, f"REST comment {database_id} belongs to multiple threads"
            membership[database_id] = thread_id
            rest_comment = rest_by_id[database_id]

            if comment["body"] != rest_comment["body"]:
                return None, f"body mismatch for comment {database_id}"
            if comment["actor"] != rest_comment["actor"]:
                return None, f"actor mismatch for comment {database_id}"
            if comment["path"] != rest_comment["path"] or comment["line"] != rest_comment["line"]:
                return None, f"topology position mismatch for comment {database_id}"
            if comment["commit_id"] != rest_comment["commit_id"]:
                return None, f"commit mismatch for comment {database_id}"
            if comment["created_at"] != rest_comment["created_at"]:
                return None, f"created_at mismatch for comment {database_id}"
            if comment["updated_at"] != rest_comment["updated_at"]:
                return None, f"updated_at mismatch for comment {database_id}"
            # REST review-comment responses do not expose edit history.  The
            # GraphQL lastEditedAt value is the checkpoint/fingerprint source
            # of truth; comparing it with REST's absent/null field would
            # reject every PR containing an already edited comment.

            rest_reply = rest_comment["reply_to_database_id"]
            graphql_reply = comment["reply_to_node_id"]
            if (rest_reply is None) != (graphql_reply is None):
                return None, f"reply topology mismatch for comment {database_id}"
            if rest_reply is not None and not is_int(rest_reply):
                return None, f"REST reply target for comment {database_id} is invalid"
            if graphql_reply is not None and not isinstance(graphql_reply, str):
                return None, f"GraphQL reply target for comment {database_id} is invalid"

            comments.append(
                {
                    "comment_id": database_id,
                    "node_id": node_id,
                    "body": comment["body"],
                    "body_hash": sha256_text(comment["body"]),
                    "actor": comment["actor"],
                    "reply_to_comment_id": rest_reply,
                    "reply_to_node_id": graphql_reply,
                    "path": comment["path"],
                    "line": comment["line"],
                    "commit_id": comment["commit_id"],
                    "created_at": comment["created_at"],
                    "updated_at": comment["updated_at"],
                    "last_edited_at": comment["last_edited_at"],
                }
            )

        roots = [comment for comment in comments if comment["reply_to_comment_id"] is None]
        if len(roots) != 1:
            return None, f"thread {thread_id} does not have exactly one root comment"
        root = roots[0]
        root_node_id = root["node_id"]
        for comment in comments:
            if comment["reply_to_comment_id"] is None:
                continue
            parent_rest = rest_by_id[comment["reply_to_comment_id"]] if comment["reply_to_comment_id"] in rest_by_id else None
            if parent_rest is None:
                return None, f"REST reply target {comment['reply_to_comment_id']} is absent"
            parent_graphql = next(
                (candidate for candidate in comments if candidate["comment_id"] == comment["reply_to_comment_id"]),
                None,
            )
            if parent_graphql is None or comment["reply_to_node_id"] != parent_graphql["node_id"]:
                return None, f"reply target mismatch for comment {comment['comment_id']}"
            if comment["reply_to_node_id"] != root_node_id:
                return None, f"comment {comment['comment_id']} is not a direct root reply"

        normalized_thread = {
            "thread_id": thread_id,
            "resolved": resolved,
            "root_comment_id": root["comment_id"],
            "tail_comment_id": comments[-1]["comment_id"],
            "comments": comments,
        }
        normalized_thread["thread_fingerprint"] = thread_fingerprint(normalized_thread)
        normalized_threads.append(normalized_thread)

    if len(membership) != len(rest_comments):
        missing = sorted(set(rest_by_id) - set(membership))
        return None, f"REST comments absent from GraphQL threads: {missing}"

    fingerprint_material = [thread_fingerprint_material(thread) for thread in normalized_threads]

    canonical = {"threads": normalized_threads, "comment_ids": []}
    # Keep the ordered GraphQL connection as the only source of ordering.  The
    # REST response order is intentionally not copied into the fingerprint.
    canonical["comment_ids"] = [
        comment["comment_id"] for thread in normalized_threads for comment in thread["comments"]
    ]
    canonical["fingerprint_material"] = fingerprint_material
    canonical["fingerprint"] = json_hash(fingerprint_material)
    canonical["pagination_complete"] = True
    return canonical, None


def snapshot_from(value: Any) -> tuple[dict[str, Any] | None, str | None]:
    """Accept a raw reconciliation input or the helper's snapshot output."""
    if not isinstance(value, dict):
        return None, "snapshot is not an object"

    if "canonical" in value:
        value = value["canonical"]
    elif "snapshot" in value and isinstance(value["snapshot"], dict):
        value = value["snapshot"]

    if "rest" in value or "rest_comments" in value:
        return reconcile(value)

    if not isinstance(value.get("threads"), list) or not isinstance(value.get("fingerprint"), str):
        return None, "snapshot must contain canonical threads and fingerprint"

    # Canonical snapshots are produced by this file.  Validate the structural
    # pieces used by all later operations rather than trusting a caller's hash.
    canonical = deepcopy(value)
    material = []
    all_ids: list[int] = []
    seen_ids: set[int] = set()
    seen_node_ids: set[str] = set()
    seen_threads: set[str] = set()
    for thread in canonical["threads"]:
        if not isinstance(thread, dict):
            return None, "canonical thread is not an object"
        tid = thread.get("thread_id")
        if not isinstance(tid, str) or not tid or tid in seen_threads:
            return None, "canonical thread id is missing or duplicated"
        seen_threads.add(tid)
        if not isinstance(thread.get("resolved"), bool):
            return None, f"canonical thread {tid} has invalid resolved state"
        comments = thread.get("comments")
        if not isinstance(comments, list) or not comments:
            return None, f"canonical thread {tid} has no comments"
        if thread.get("root_comment_id") != next(
            (c.get("comment_id") for c in comments if c.get("reply_to_comment_id") is None), None
        ):
            return None, f"canonical thread {tid} root is inconsistent"
        if thread.get("tail_comment_id") != comments[-1].get("comment_id"):
            return None, f"canonical thread {tid} tail is inconsistent"
        roots = [c for c in comments if c.get("reply_to_comment_id") is None]
        if len(roots) != 1:
            return None, f"canonical thread {tid} does not have one root"
        root_node = roots[0].get("node_id")
        ids_in_thread = {c.get("comment_id") for c in comments}
        if None in ids_in_thread or any(not is_int(cid) or cid <= 0 for cid in ids_in_thread):
            return None, f"canonical thread {tid} has an invalid comment id"
        for comment in comments:
            cid = comment.get("comment_id")
            if cid in seen_ids:
                return None, f"canonical comment id {cid} is duplicated"
            seen_ids.add(cid)
            all_ids.append(cid)
            if not isinstance(comment.get("node_id"), str) or not comment["node_id"]:
                return None, f"canonical comment {cid} is missing node_id"
            if comment["node_id"] in seen_node_ids:
                return None, f"canonical node id {comment['node_id']} is duplicated"
            seen_node_ids.add(comment["node_id"])
            if not isinstance(comment.get("body"), str) or not isinstance(comment.get("body_hash"), str):
                return None, f"canonical comment {cid} has invalid body"
            if sha256_text(comment["body"]) != comment["body_hash"]:
                return None, f"canonical comment {cid} has an invalid body hash"
            if not isinstance(comment.get("actor"), str) or not comment["actor"]:
                return None, f"canonical comment {cid} has no actor"
            reply_id = comment.get("reply_to_comment_id")
            reply_node = comment.get("reply_to_node_id")
            if reply_id is None:
                if reply_node is not None:
                    return None, f"canonical root {cid} has a reply node"
            else:
                if reply_id not in ids_in_thread or reply_node != next(
                    c.get("node_id") for c in comments if c.get("comment_id") == reply_id
                ):
                    return None, f"canonical comment {cid} has inconsistent reply topology"
                if reply_node != root_node:
                    return None, f"canonical comment {cid} is not a direct root reply"
        thread_material = thread_fingerprint_material(thread)
        expected_thread_fingerprint = json_hash(thread_material)
        if "thread_fingerprint" in thread and thread["thread_fingerprint"] != expected_thread_fingerprint:
            return None, f"canonical thread {tid} fingerprint is inconsistent"
        thread["thread_fingerprint"] = expected_thread_fingerprint
        material.append(thread_material)
    if canonical.get("comment_ids") != all_ids:
        return None, "canonical comment order is inconsistent"
    expected_fingerprint = json_hash(material)
    if canonical["fingerprint"] != expected_fingerprint:
        return None, "snapshot fingerprint does not match canonical content"
    canonical["fingerprint_material"] = material
    return canonical, None


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


def record_base(
    *,
    thread: dict[str, Any],
    root: dict[str, Any],
    reviewer: str,
    classification: str,
    verification_head_sha: str,
    plan_fingerprint: str,
    verified_fingerprint: str,
    verified_snapshot_fingerprint: str,
    classification_reply_id: int,
    reply_source: str,
    materialization_state: str,
    transport_outcome: str,
    verified_snapshot: dict[str, Any] | None = None,
) -> dict[str, Any]:
    anchor = next(
        comment for comment in thread["comments"] if comment["comment_id"] == classification_reply_id
    )
    record = {
        "thread_id": thread["thread_id"],
        "root_comment_id": root["comment_id"],
        "reviewer_login": reviewer,
        "classification": classification,
        "classification_reply_id": classification_reply_id,
        "reply_source": reply_source,
        "materialization_state": materialization_state,
        "transport_outcome": transport_outcome,
        "verification_head_sha": verification_head_sha,
        "plan_fingerprint": plan_fingerprint,
        # ``verified_fingerprint`` is deliberately scoped to this record's
        # target thread.  The full snapshot checkpoint remains available for
        # deterministic this-run delta reconciliation below.
        "verified_fingerprint": verified_fingerprint,
        "verified_snapshot_fingerprint": verified_snapshot_fingerprint,
        "anchor_body_hash": anchor["body_hash"],
        "anchor_updated_at": anchor.get("updated_at"),
        "anchor_last_edited_at": anchor.get("last_edited_at"),
        "anchor_reply_to_comment_id": anchor.get("reply_to_comment_id"),
    }
    if verified_snapshot is not None:
        # This is an in-memory checkpoint supplied to the next fresh
        # eligibility read.  Callers must not persist or restore it across a
        # restart; the required record fields above remain the portable
        # contract.
        record["verified_snapshot"] = deepcopy(verified_snapshot)
    return record


def operation_parse(input_data: dict[str, Any]) -> int:
    body = input_data.get("body")
    parsed = classification_from_body(body)
    if parsed is None:
        return emit("parse", decision="not_classification", classification=None)
    return emit("parse", decision="classification", **parsed)


def operation_reconcile(input_data: dict[str, Any]) -> int:
    snapshot, error = reconcile(input_data)
    if error:
        return stop("reconcile", "snapshot_invalid", detail=error)
    assert snapshot is not None
    return emit("reconcile", decision="ok", fingerprint=snapshot["fingerprint"], snapshot=snapshot)


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

    tail_parsed = classification_from_body(tail["body"])
    reusable = (
        classification == "Resolved"
        and tail["comment_id"] != root["comment_id"]
        and tail["actor"] == reviewer
        and tail.get("reply_to_comment_id") == root["comment_id"]
        and tail_parsed is not None
        and tail_parsed.get("classification") == "Resolved"
    )
    common = {
        "thread_id": thread["thread_id"],
        "root_comment_id": root["comment_id"],
        "reviewer_login": reviewer,
        "classification": classification,
        "plan_fingerprint": snapshot["fingerprint"],
        "verification_head_sha": input_data.get("verification_head_sha", input_data.get("head_sha")),
        "tail_comment_id": tail["comment_id"],
    }
    if common["verification_head_sha"] is None:
        return stop("plan", "verification_head_sha_missing", **common)
    if not isinstance(common["verification_head_sha"], str) or not common["verification_head_sha"]:
        return stop("plan", "invalid_verification_head_sha", **common)
    if reusable:
        return emit(
            "plan",
            decision="reuse",
            anchor_id=tail["comment_id"],
            anchor_body_hash=tail["body_hash"],
            **common,
        )
    return emit("plan", decision="post", anchor_id=None, **common)


def load_plan_snapshot(input_data: dict[str, Any], key: str) -> tuple[dict[str, Any] | None, str | None]:
    plan_snapshot = first_present(input_data, key, "snapshot", default=None)
    if plan_snapshot is None:
        return None, f"{key} is required"
    return snapshot_from(plan_snapshot)


def operation_verify_reuse(input_data: dict[str, Any]) -> int:
    plan = input_data.get("plan")
    if not isinstance(plan, dict) or plan.get("decision") != "reuse":
        return stop("verify_reuse", "reuse_plan_required")
    baseline, error = load_plan_snapshot(input_data, "plan_snapshot")
    if error:
        return stop("verify_reuse", "snapshot_invalid", detail=error)
    fresh, error = load_plan_snapshot(input_data, "fresh_snapshot")
    if error:
        return stop("verify_reuse", "snapshot_invalid", detail=error)
    assert baseline is not None and fresh is not None
    head = input_data.get("verification_head_sha", input_data.get("head_sha"))
    if head != plan.get("verification_head_sha"):
        return stop("verify_reuse", "head_changed")
    if baseline["fingerprint"] != plan.get("plan_fingerprint"):
        return stop("verify_reuse", "plan_fingerprint_mismatch")
    if fresh["fingerprint"] != plan.get("plan_fingerprint"):
        return stop("verify_reuse", "fingerprint_mismatch")
    thread, error = select_thread(fresh, plan.get("thread_id"))
    if error:
        return stop("verify_reuse", error)
    assert thread is not None
    root, tail, error = root_and_tail(thread, plan.get("root_comment_id"))
    if error:
        return stop("verify_reuse", error)
    assert root is not None and tail is not None
    parsed = classification_from_body(tail["body"])
    if thread["resolved"]:
        return stop("verify_reuse", "thread_already_resolved")
    if (
        tail["comment_id"] != plan.get("anchor_id")
        or tail["actor"] != plan.get("reviewer_login")
        or tail.get("reply_to_comment_id") != root["comment_id"]
        or parsed is None
        or parsed.get("classification") != "Resolved"
    ):
        return stop("verify_reuse", "anchor_invalid")
    record = record_base(
        thread=thread,
        root=root,
        reviewer=plan["reviewer_login"],
        classification="Resolved",
        verification_head_sha=head,
        plan_fingerprint=plan["plan_fingerprint"],
        verified_fingerprint=thread["thread_fingerprint"],
        verified_snapshot_fingerprint=fresh["fingerprint"],
        classification_reply_id=tail["comment_id"],
        reply_source="reused",
        materialization_state="reused_reply_verified",
        transport_outcome="none",
        verified_snapshot=fresh,
    )
    return emit(
        "verify_reuse",
        decision="reused_reply_verified",
        eligible=True,
        record=record,
    )


def canonical_equal(a: dict[str, Any], b: dict[str, Any]) -> bool:
    return a["fingerprint"] == b["fingerprint"] and a["threads"] == b["threads"]


def expected_comment_in_snapshot(snapshot: dict[str, Any], expected: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    thread = thread_for(snapshot, expected.get("thread_id"))
    if thread is None:
        return None, None
    candidates = [c for c in thread["comments"] if c["comment_id"] == expected.get("id")]
    return thread, candidates[0] if len(candidates) == 1 else None


def expected_only_delta(
    baseline: dict[str, Any], final: dict[str, Any], expected: dict[str, Any]
) -> tuple[bool, str]:
    if [t["thread_id"] for t in baseline["threads"]] != [t["thread_id"] for t in final["threads"]]:
        return False, "thread topology changed"
    expected_thread_id = expected.get("thread_id")
    found_added = False
    for old_thread, new_thread in zip(baseline["threads"], final["threads"]):
        if old_thread["resolved"] != new_thread["resolved"]:
            return False, "resolved state changed"
        old_comments = old_thread["comments"]
        new_comments = new_thread["comments"]
        old_ids = [c["comment_id"] for c in old_comments]
        new_ids = [c["comment_id"] for c in new_comments]
        if old_thread["thread_id"] == expected_thread_id:
            if new_ids[: len(old_ids)] != old_ids or len(new_ids) != len(old_ids) + 1:
                return False, "expected thread did not gain exactly one tail comment"
            if found_added:
                return False, "multiple expected comments"
            added = new_comments[-1]
            if added["comment_id"] != expected.get("id"):
                return False, "returned comment is not the connection tail"
            found_added = True
            if added["body"] != expected.get("body"):
                return False, "expected body mismatch"
            if added["actor"] != expected.get("actor"):
                return False, "expected actor mismatch"
            if added.get("reply_to_comment_id") != expected.get("root_comment_id"):
                return False, "expected root reply target mismatch"
            if expected.get("node_id") is not None and added.get("node_id") != expected.get("node_id"):
                return False, "expected GraphQL node id mismatch"
            for old, new in zip(old_comments, new_comments[:-1]):
                if old != new:
                    return False, f"existing comment {old.get('comment_id')} changed"
        else:
            if new_ids != old_ids or new_thread["comments"] != old_thread["comments"]:
                return False, "non-target thread changed"
    if not found_added:
        return False, "expected thread was not found"
    return True, "expected reply only"


def operation_verify_transport(input_data: dict[str, Any]) -> int:
    plan = input_data.get("plan")
    if not isinstance(plan, dict) or plan.get("decision") != "post":
        return stop("verify_transport", "post_plan_required")
    outcome = input_data.get("transport_outcome", input_data.get("outcome"))
    if outcome not in {"ok", "already_applied", "failed", "unknown_outcome"}:
        return stop("verify_transport", "invalid_transport_outcome")
    if outcome in {"failed", "unknown_outcome"}:
        return stop("verify_transport", outcome)
    baseline, error = load_plan_snapshot(input_data, "plan_snapshot")
    if error:
        return stop("verify_transport", "snapshot_invalid", detail=error)
    fresh, error = load_plan_snapshot(input_data, "fresh_snapshot")
    if error:
        return stop("verify_transport", "snapshot_invalid", detail=error)
    assert baseline is not None and fresh is not None
    if baseline["fingerprint"] != plan.get("plan_fingerprint"):
        return stop("verify_transport", "plan_fingerprint_mismatch")
    head = input_data.get("verification_head_sha", input_data.get("head_sha"))
    if head != plan.get("verification_head_sha"):
        return stop("verify_transport", "head_changed")
    expected = input_data.get("expected_reply")
    if not isinstance(expected, dict) or not is_int(expected.get("id")):
        return stop("verify_transport", "expected_reply_missing")
    expected = dict(expected)
    expected.setdefault("thread_id", plan.get("thread_id"))
    expected.setdefault("root_comment_id", plan.get("root_comment_id"))
    expected.setdefault("actor", plan.get("reviewer_login"))
    if expected.get("body") is None:
        return stop("verify_transport", "expected_body_missing")
    if expected.get("thread_id") != plan.get("thread_id") or expected.get("root_comment_id") != plan.get(
        "root_comment_id"
    ):
        return stop("verify_transport", "expected_target_mismatch")

    if outcome == "already_applied" and canonical_equal(baseline, fresh):
        return emit(
            "verify_transport",
            decision="transport_already_applied",
            eligible=False,
            transport_outcome="already_applied",
        )
    matched, detail = expected_only_delta(baseline, fresh, expected)
    if not matched:
        return stop("verify_transport", "precondition_changed", detail=detail)
    thread, comment = expected_comment_in_snapshot(fresh, expected)
    if thread is None or comment is None:
        return stop("verify_transport", "expected_reply_missing")
    materialization = (
        "new_reply_verified" if outcome == "ok" else "already_applied_reply_verified"
    )
    record = record_base(
        thread=thread,
        root=next(c for c in thread["comments"] if c["comment_id"] == plan["root_comment_id"]),
        reviewer=plan["reviewer_login"],
        classification=plan["classification"],
        verification_head_sha=head,
        plan_fingerprint=plan["plan_fingerprint"],
        verified_fingerprint=thread["thread_fingerprint"],
        verified_snapshot_fingerprint=fresh["fingerprint"],
        classification_reply_id=comment["comment_id"],
        reply_source="new",
        materialization_state=materialization,
        transport_outcome=outcome,
        verified_snapshot=fresh,
    )
    return emit(
        "verify_transport",
        decision=materialization,
        eligible=plan["classification"] == "Resolved",
        record=record,
    )


def common_record_checks(record: Any) -> tuple[dict[str, Any] | None, str | None]:
    if not isinstance(record, dict):
        return None, "record is not an object"
    required = {
        "thread_id",
        "root_comment_id",
        "reviewer_login",
        "classification",
        "classification_reply_id",
        "materialization_state",
        "transport_outcome",
        "verification_head_sha",
        "plan_fingerprint",
        "verified_fingerprint",
        "verified_snapshot_fingerprint",
    }
    missing = sorted(field for field in required if field not in record)
    if missing:
        return None, f"record is missing fields: {', '.join(missing)}"
    if record["classification"] != "Resolved":
        return None, "classification is not Resolved"
    if not isinstance(record["verified_fingerprint"], str) or not record["verified_fingerprint"]:
        return None, "verified thread fingerprint is invalid"
    if not isinstance(record["verified_snapshot_fingerprint"], str) or not record["verified_snapshot_fingerprint"]:
        return None, "verified snapshot fingerprint is invalid"
    if record["materialization_state"] not in MATERIALIZATION_STATES:
        return None, "materialization state is not verified"
    if record.get("reply_source") not in {"new", "reused"}:
        return None, "reply source is invalid"
    if record["materialization_state"] == "reused_reply_verified":
        if record.get("reply_source") != "reused" or record.get("transport_outcome") != "none":
            return None, "reused reply state has an invalid source or transport outcome"
        if record.get("verified_snapshot_fingerprint") != record.get("plan_fingerprint"):
            return None, "reused reply state does not preserve the plan snapshot fingerprint"
    elif record["materialization_state"] == "new_reply_verified":
        if record.get("reply_source") != "new" or record.get("transport_outcome") != "ok":
            return None, "new reply state has an invalid source or transport outcome"
    elif record["materialization_state"] == "already_applied_reply_verified":
        if record.get("reply_source") != "new" or record.get("transport_outcome") != "already_applied":
            return None, "already-applied reply state has an invalid source or transport outcome"
    return record, None


def operation_resolve_eligibility(input_data: dict[str, Any]) -> int:
    record, error = common_record_checks(input_data.get("record"))
    if error:
        return stop("resolve_eligibility", error)
    assert record is not None
    current_head = input_data.get("current_head_sha", input_data.get("head_sha"))
    lgtm_commit = input_data.get("lgtm_commit_id")
    if not input_data.get("lgtm_verified", False):
        return stop("resolve_eligibility", "lgtm_not_verified")
    if not isinstance(current_head, str) or not isinstance(lgtm_commit, str):
        return stop("resolve_eligibility", "head_or_lgtm_missing")
    if not (
        record["verification_head_sha"] == current_head == lgtm_commit
    ):
        return stop("resolve_eligibility", "head_changed")
    fresh, error = load_plan_snapshot(input_data, "fresh_snapshot")
    if error:
        return stop("resolve_eligibility", "snapshot_invalid", detail=error)
    assert fresh is not None
    verified_snapshot_value = input_data.get("verified_snapshot", record.get("verified_snapshot"))
    verified_snapshot, verified_error = snapshot_from(verified_snapshot_value)
    if verified_error:
        return stop("resolve_eligibility", "verified_snapshot_invalid", detail=verified_error)
    assert verified_snapshot is not None
    if verified_snapshot["fingerprint"] != record["verified_snapshot_fingerprint"]:
        return stop("resolve_eligibility", "verified_snapshot_fingerprint_mismatch")
    verified_thread = thread_for(verified_snapshot, record["thread_id"])
    if verified_thread is None:
        return stop("resolve_eligibility", "verified_thread_missing")
    if verified_thread["thread_fingerprint"] != record["verified_fingerprint"]:
        return stop("resolve_eligibility", "verified_thread_fingerprint_mismatch")
    run_ids, run_error = this_run_resolve_ids(input_data, record["thread_id"])
    if run_error:
        return stop("resolve_eligibility", run_error)
    delta_ok, delta_detail, target_changed = resolve_snapshot_delta(
        verified_snapshot,
        fresh,
        record["thread_id"],
        run_ids,
        allow_target_toggle=True,
    )
    if not delta_ok:
        return stop("resolve_eligibility", "fingerprint_mismatch", detail=delta_detail)
    thread, error = select_thread(fresh, record["thread_id"])
    if error:
        return stop("resolve_eligibility", error)
    assert thread is not None
    root, tail, error = root_and_tail(thread, record["root_comment_id"])
    if error:
        return stop("resolve_eligibility", error)
    assert root is not None and tail is not None
    if target_changed:
        return emit(
            "resolve_eligibility",
            decision="already_resolved_external",
            eligible=False,
            thread_id=record["thread_id"],
            anchor_id=record["classification_reply_id"],
        )
    if thread["thread_fingerprint"] != record["verified_fingerprint"]:
        return stop("resolve_eligibility", "thread_fingerprint_mismatch")
    if thread["resolved"]:
        return stop("resolve_eligibility", "unexpected_resolved_state")
    parsed = classification_from_body(tail["body"])
    if (
        root["actor"] != record["reviewer_login"]
        or record.get("anchor_reply_to_comment_id") != tail.get("reply_to_comment_id")
        or tail["comment_id"] != record["classification_reply_id"]
        or tail["actor"] != record["reviewer_login"]
        or tail.get("reply_to_comment_id") != root["comment_id"]
        or parsed is None
        or parsed.get("classification") != "Resolved"
        or tail["body_hash"] != record.get("anchor_body_hash")
        or tail.get("updated_at") != record.get("anchor_updated_at")
        or tail.get("last_edited_at") != record.get("anchor_last_edited_at")
    ):
        return stop("resolve_eligibility", "anchor_invalid")
    return emit(
        "resolve_eligibility",
        decision="eligible",
        eligible=True,
        thread_id=record["thread_id"],
        root_comment_id=record["root_comment_id"],
        anchor_id=record["classification_reply_id"],
        verified_fingerprint=record["verified_fingerprint"],
        verified_snapshot_fingerprint=fresh["fingerprint"],
    )


def this_run_resolve_ids(
    input_data: dict[str, Any], target_thread_id: str
) -> tuple[dict[str, dict[str, Any]], str | None]:
    """Validate prior successful Resolve results used as an expected delta.

    A thread-scoped fingerprint makes independent provisional targets stable,
    but it must not turn every other-thread change into an allowed change.  The
    caller therefore supplies the helper's own ``resolved_by_run`` results for
    earlier targets in this run.  Only those exact unresolved-to-resolved
    transitions are admitted by ``resolve_snapshot_delta``.
    """
    entries = first_present(
        input_data,
        "this_run_resolve_records",
        "run_resolve_records",
        default=[],
    )
    if entries is None:
        entries = []
    if not isinstance(entries, list):
        return {}, "this-run Resolve records are not an array"
    thread_records: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("decision") != "resolved_by_run":
            return {}, "this-run Resolve record is not a verified resolved_by_run result"
        thread_id = entry.get("thread_id")
        if not isinstance(thread_id, str) or not thread_id:
            return {}, "this-run Resolve record has no thread id"
        if thread_id == target_thread_id:
            return {}, "this-run Resolve records include the current target"
        if thread_id in thread_records:
            return {}, f"duplicate this-run Resolve record for thread {thread_id}"
        for field in (
            "before_snapshot_fingerprint",
            "after_snapshot_fingerprint",
            "before_thread_fingerprint",
            "after_thread_fingerprint",
        ):
            value = entry.get(field)
            if not isinstance(value, str) or not value:
                return {}, f"this-run Resolve record is missing {field}"
        thread_records[thread_id] = entry
    return thread_records, None


def thread_resolved_toggle(before: dict[str, Any], after: dict[str, Any]) -> tuple[bool, str]:
    if before["thread_id"] != after["thread_id"]:
        return False, "thread identity changed"
    if before["resolved"] is not False or after["resolved"] is not True:
        return False, "thread did not change from unresolved to resolved"
    if before["comments"] != after["comments"]:
        return False, "thread comments changed"
    return True, "resolved state only"


def after_thread_fingerprint(snapshot: dict[str, Any], thread_id: str) -> str:
    thread = thread_for(snapshot, thread_id)
    if thread is None:
        return ""
    return thread["thread_fingerprint"]


def resolve_snapshot_delta(
    baseline: dict[str, Any],
    fresh: dict[str, Any],
    target_thread_id: str,
    allowed_thread_records: dict[str, dict[str, Any]],
    *,
    allow_target_toggle: bool,
) -> tuple[bool, str, bool]:
    """Reconcile a Resolve checkpoint against a fresh full snapshot.

    The target may either remain byte-for-byte stable or, for eligibility,
    make one externally observed false-to-true state transition.  Other
    threads may change only through a declared, helper-verified prior
    ``resolved_by_run`` result whose thread fingerprints match; edits, replies, deletions, identity changes,
    and unlisted state changes remain fail-closed.
    """
    before_ids = [thread["thread_id"] for thread in baseline["threads"]]
    after_ids = [thread["thread_id"] for thread in fresh["threads"]]
    if before_ids != after_ids:
        return False, "thread topology changed", False
    if target_thread_id in allowed_thread_records:
        return False, "target thread is listed as an earlier Resolve", False
    expected_checkpoint = baseline["fingerprint"]
    for thread_id, run_record in allowed_thread_records.items():
        if run_record["before_snapshot_fingerprint"] != expected_checkpoint:
            return False, f"this-run Resolve checkpoint chain mismatch before thread {thread_id}", False
        expected_checkpoint = run_record["after_snapshot_fingerprint"]

    changed_allowed: set[str] = set()
    target_changed = False
    for before, after in zip(baseline["threads"], fresh["threads"]):
        if before == after:
            continue
        thread_id = before["thread_id"]
        if thread_id == target_thread_id:
            if not allow_target_toggle:
                return False, "target thread changed before Resolve", False
            toggled, detail = thread_resolved_toggle(before, after)
            if not toggled:
                return False, detail, False
            target_changed = True
            continue
        if thread_id not in allowed_thread_records:
            return False, f"unverified change in thread {thread_id}", False
        toggled, detail = thread_resolved_toggle(before, after)
        if not toggled:
            return False, detail, False
        run_record = allowed_thread_records[thread_id]
        if run_record["before_thread_fingerprint"] != before["thread_fingerprint"]:
            return False, f"this-run Resolve baseline fingerprint mismatch for thread {thread_id}", False
        if run_record["after_thread_fingerprint"] != after["thread_fingerprint"]:
            return False, f"this-run Resolve result fingerprint mismatch for thread {thread_id}", False
        changed_allowed.add(thread_id)

    missing_allowed = set(allowed_thread_records) - changed_allowed
    if missing_allowed:
        return False, f"declared Resolve delta is absent: {sorted(missing_allowed)}", False
    if not target_changed and allowed_thread_records and expected_checkpoint != fresh["fingerprint"]:
        return False, "this-run Resolve checkpoint chain does not reach fresh snapshot", False
    return True, "verified Resolve delta", target_changed


def only_resolved_toggle(before: dict[str, Any], after: dict[str, Any], thread_id: str) -> tuple[bool, str]:
    if [t["thread_id"] for t in before["threads"]] != [t["thread_id"] for t in after["threads"]]:
        return False, "thread topology changed"
    changed = 0
    for old, new in zip(before["threads"], after["threads"]):
        if old["thread_id"] == thread_id:
            if old["resolved"] is not False or new["resolved"] is not True:
                return False, "target thread did not change from unresolved to resolved"
            if old["comments"] != new["comments"]:
                return False, "target thread comments changed"
            changed += 1
        elif old != new:
            return False, "another thread changed"
    return (changed == 1, "resolved state only" if changed == 1 else "target thread missing")


def already_resolved_post_read(
    before: dict[str, Any], after: dict[str, Any], thread_id: str
) -> tuple[bool, str]:
    """Verify an already-applied Resolve without requiring a false->true delta."""
    if [t["thread_id"] for t in before["threads"]] != [t["thread_id"] for t in after["threads"]]:
        return False, "thread topology changed"
    target_found = False
    for old, new in zip(before["threads"], after["threads"]):
        if old["thread_id"] == thread_id:
            if new["resolved"] is not True:
                return False, "post-read target thread is not resolved"
            if old["comments"] != new["comments"]:
                return False, "target thread comments changed"
            target_found = True
        elif old != new:
            return False, "another thread changed"
    if not target_found:
        return False, "target thread missing"
    return True, "resolved target verified"


def operation_resolve_post(input_data: dict[str, Any]) -> int:
    record, error = common_record_checks(input_data.get("record"))
    if error:
        return stop("resolve_post", error)
    assert record is not None
    # A Resolve post-read is only attributable to an explicit transport
    # outcome.  Missing, null, and unknown values must never become ``ok`` by
    # default, because a caller can otherwise turn an external false->true
    # transition into ``resolved_by_run`` by omission.
    outcome = input_data.get("transport_outcome", input_data.get("outcome"))
    if not isinstance(outcome, str):
        return stop("resolve_post", "invalid_transport_outcome")
    if outcome in {"failed", "unknown_outcome"}:
        return stop("resolve_post", outcome)
    if outcome not in {"ok", "already_applied"}:
        return stop("resolve_post", "invalid_transport_outcome")
    before, error = load_plan_snapshot(input_data, "before_snapshot")
    if error:
        return stop("resolve_post", "snapshot_invalid", detail=error)
    after, error = load_plan_snapshot(input_data, "after_snapshot")
    if error:
        return stop("resolve_post", "snapshot_invalid", detail=error)
    assert before is not None and after is not None
    verified_snapshot_value = record.get("verified_snapshot")
    verified_snapshot, verified_error = snapshot_from(verified_snapshot_value)
    if verified_error:
        return stop("resolve_post", "verified_snapshot_invalid", detail=verified_error)
    assert verified_snapshot is not None
    if verified_snapshot["fingerprint"] != record["verified_snapshot_fingerprint"]:
        return stop("resolve_post", "verified_snapshot_fingerprint_mismatch")
    verified_thread = thread_for(verified_snapshot, record["thread_id"])
    if verified_thread is None:
        return stop("resolve_post", "verified_thread_missing")
    before_thread = thread_for(before, record["thread_id"])
    if before_thread is None:
        return stop("resolve_post", "before_thread_missing")
    run_ids, run_error = this_run_resolve_ids(input_data, record["thread_id"])
    if run_error:
        return stop("resolve_post", run_error)
    delta_ok, delta_detail, _ = resolve_snapshot_delta(
        verified_snapshot,
        before,
        record["thread_id"],
        run_ids,
        allow_target_toggle=True,
    )
    if not delta_ok:
        return stop("resolve_post", "before_fingerprint_mismatch", detail=delta_detail)
    if before_thread["thread_fingerprint"] != record["verified_fingerprint"]:
        toggled_before_action, _ = thread_resolved_toggle(verified_thread, before_thread)
        if not toggled_before_action:
            return stop("resolve_post", "before_thread_fingerprint_mismatch")
    if outcome == "already_applied":
        # ``already_applied`` means this invocation did not perform the
        # mutation.  The post-read must nevertheless prove that the target
        # is resolved; a before==after unresolved snapshot is not success.
        resolved, detail = already_resolved_post_read(before, after, record["thread_id"])
        if not resolved:
            return stop("resolve_post", "precondition_changed", detail=detail)
        return emit(
            "resolve_post",
            decision="already_resolved_external",
            eligible=False,
            thread_id=record["thread_id"],
            state_delta_verified=True,
        )
    changed, detail = only_resolved_toggle(before, after, record["thread_id"])
    if not changed:
        return stop("resolve_post", "precondition_changed", detail=detail)
    return emit(
        "resolve_post",
        decision="resolved_by_run",
        eligible=True,
        thread_id=record["thread_id"],
        anchor_id=record["classification_reply_id"],
        verified_fingerprint=after_thread_fingerprint(after, record["thread_id"]),
        before_snapshot_fingerprint=before["fingerprint"],
        after_snapshot_fingerprint=after["fingerprint"],
        before_thread_fingerprint=before_thread["thread_fingerprint"],
        after_thread_fingerprint=after_thread_fingerprint(after, record["thread_id"]),
    )


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
        record, error = common_record_checks(record_value)
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
    lgtm = {
        "eligible": True,
        "head_sha": head,
        "record_count": len(records),
    }
    if input_data.get("lgtm_verified") is True:
        lgtm["resolve_eligible"] = input_data.get("lgtm_commit_id") == head
    else:
        lgtm["resolve_eligible"] = False
    return emit("gate", decision="lgtm_eligible", **lgtm)


OPERATIONS = {
    "parse": operation_parse,
    "reconcile": operation_reconcile,
    "plan": operation_plan,
    "verify_reuse": operation_verify_reuse,
    "verify-reuse": operation_verify_reuse,
    "verify_transport": operation_verify_transport,
    "verify-transport": operation_verify_transport,
    "resolve_eligibility": operation_resolve_eligibility,
    "resolve-eligibility": operation_resolve_eligibility,
    "resolve_post": operation_resolve_post,
    "resolve-post": operation_resolve_post,
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
