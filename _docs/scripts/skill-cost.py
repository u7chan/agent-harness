#!/usr/bin/env python3
"""Offline analyzer for pi session JSONL files.

Reads one or more pi session JSONL files and emits, per session (one agent
role), token usage, LLM tool-call counts, gh CLI dispatch counts, approximate
tool-result byte volumes, repeated re-reads, elapsed time, and error counts.
Pure offline analysis: no network, no daemon, no persistent state, and a
deterministic output for the same input.

The session log does not record HTTP requests made inside the gh CLI, so
"HTTP/API requests" is reported as a documented lower bound (network tool
calls + gh dispatches), never as an exact count.  Parent/child relationships
between agents are not derivable from the log; each file is one role and the
caller supplies the role mapping.

Exit codes: 0 ok, 2 invalid input (fail closed).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import Any

SCHEMA_VERSION = 1

NETWORK_TOOL_NAMES = ("fetch_content", "web_search", "source_check")
RAW_GH_RE = re.compile(r"\bgh\s+(?:pr|issue|api|repo|release|run|workflow|gist|label|search|auth|secret|variable)\b")
GH_DISPATCH_RE = re.compile(r"\bgh\.sh\s+([A-Za-z0-9._-]+)")
HANDOFF_MARKER = "child-return-result.sh"
TARGET_KEY_RES = (
    ("reference", re.compile(r'"reference"\s*:\s*"([^"]+)"')),
    ("number", re.compile(r'"number"\s*:\s*(\d+)')),
    ("thread_id", re.compile(r'"thread_id"\s*:\s*"([^"]+)"')),
)
USAGE_FIELD_MAP = (
    ("input", "input"),
    ("output", "output"),
    ("cacheRead", "cache_read"),
    ("cacheWrite", "cache_write"),
    ("reasoning", "reasoning"),
    ("totalTokens", "total"),
)

ERROR_INVALID_INPUT = "INVALID_INPUT"


def new_usage() -> dict[str, float]:
    return {
        "input": 0,
        "output": 0,
        "cache_read": 0,
        "cache_write": 0,
        "reasoning": 0,
        "total": 0,
        "cost": 0.0,
    }


def add_usage(dst: dict[str, float], usage: Any) -> None:
    if not isinstance(usage, dict):
        return
    for src_key, dst_key in USAGE_FIELD_MAP:
        value = usage.get(src_key)
        if isinstance(value, (int, float)):
            dst[dst_key] += value
    cost = usage.get("cost")
    if isinstance(cost, dict):
        total = cost.get("total")
        if isinstance(total, (int, float)):
            dst["cost"] += total


def entry_timestamp_ms(entry: dict[str, Any]) -> float | None:
    """Return the entry timestamp in epoch milliseconds, or None.

    Message entries carry a numeric message.timestamp (epoch ms).  Other
    entries carry an ISO-8601 string in timestamp.  Both forms are accepted.
    """
    message = entry.get("message")
    if isinstance(message, dict):
        ts = message.get("timestamp")
        if isinstance(ts, (int, float)):
            return float(ts)
    ts = entry.get("timestamp")
    if isinstance(ts, (int, float)):
        return float(ts)
    if isinstance(ts, str):
        try:
            parsed = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp() * 1000.0
    return None


def content_text_bytes(content: Any) -> int:
    """Approximate UTF-8 byte size of a message content payload."""
    if isinstance(content, str):
        return len(content.encode("utf-8"))
    total = 0
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict):
                text = block.get("text")
                if isinstance(text, str):
                    total += len(text.encode("utf-8"))
    return total


def extract_gh_target(command: str) -> str:
    parts: list[str] = []
    for key, pattern in TARGET_KEY_RES:
        match = pattern.search(command)
        if match:
            parts.append(f"{key}={match.group(1)}")
    return "|".join(parts) if parts else "-"


class SessionAnalysis:
    """Aggregated metrics for one session JSONL file."""

    def __init__(self, label: str) -> None:
        self.label = label
        self.session_id: str | None = None
        self.session_version: int | None = None
        self.thinking_levels: list[str] = []
        self.models_observed: list[list[str]] = []
        self.timestamps: list[float] = []
        self.usage = new_usage()
        self.usage_by_model: dict[tuple[str, str], dict[str, Any]] = {}
        self.compaction_calls = 0
        self.compaction_tokens_before = 0
        self.compaction_usage = new_usage()
        self.tool_calls: Counter[str] = Counter()
        self.call_meta: dict[str, tuple[str, str]] = {}
        self.gh_actions: Counter[str] = Counter()
        self.gh_targets: Counter[tuple[str, str]] = Counter()
        self.raw_gh_commands = 0
        self.handoff_return_calls = 0
        self.network_calls: Counter[str] = Counter()
        self.custom_types: Counter[str] = Counter()
        self.read_paths: Counter[str] = Counter()
        self.fetch_urls: Counter[str] = Counter()
        self.result_bytes: Counter[str] = Counter()
        self.result_error_count = 0
        self.assistant_error_messages = 0
        self.stop_reasons: Counter[str] = Counter()
        self.skipped_lines = 0
        self.entry_count = 0

    # -- call-side classification -------------------------------------

    def note_tool_call(self, item: dict[str, Any]) -> None:
        name = item.get("name")
        if not isinstance(name, str):
            return
        self.tool_calls[name] += 1
        arguments = item.get("arguments")
        command = ""
        if isinstance(arguments, dict):
            raw_command = arguments.get("command")
            if isinstance(raw_command, str):
                command = raw_command
            if name == "read":
                path = arguments.get("path")
                if isinstance(path, str):
                    self.read_paths[path] += 1
            if name in NETWORK_TOOL_NAMES:
                for key in ("url", "urls"):
                    urls = arguments.get(key)
                    if isinstance(urls, str):
                        self.fetch_urls[urls] += 1
                    elif isinstance(urls, list):
                        for url in urls:
                            if isinstance(url, str):
                                self.fetch_urls[url] += 1
        call_id = item.get("id")
        if isinstance(call_id, str):
            self.call_meta[call_id] = (name, command)
        if name == "bash":
            if "gh.sh" in command:
                match = GH_DISPATCH_RE.search(command)
                action = match.group(1) if match else "?"
                self.gh_actions[action] += 1
                self.gh_targets[(action, extract_gh_target(command))] += 1
            elif RAW_GH_RE.search(command):
                self.raw_gh_commands += 1
            if HANDOFF_MARKER in command:
                self.handoff_return_calls += 1
        elif name in NETWORK_TOOL_NAMES:
            self.network_calls[name] += 1

    def note_tool_result(self, message: dict[str, Any]) -> None:
        is_error = message.get("isError")
        if is_error is True:
            self.result_error_count += 1
        tool_name = message.get("toolName")
        if not isinstance(tool_name, str):
            tool_name = "unknown"
        call_id = message.get("toolCallId")
        meta = self.call_meta.get(call_id) if isinstance(call_id, str) else None
        if meta is None:
            category = "unknown"
        else:
            call_name, command = meta
            if call_name == "read":
                category = "doc_read"
            elif call_name == "bash":
                if "gh.sh" in command:
                    category = "gh_api"
                else:
                    category = "bash_other"
            elif call_name in NETWORK_TOOL_NAMES:
                category = "network_tool"
            else:
                category = "bash_other"
        self.result_bytes[category] += content_text_bytes(message.get("content"))

    # -- message dispatch ----------------------------------------------

    def note_message(self, entry: dict[str, Any]) -> None:
        message = entry.get("message")
        if not isinstance(message, dict):
            return
        ts = message.get("timestamp")
        if isinstance(ts, (int, float)):
            self.timestamps.append(float(ts))
        role = message.get("role")
        if role == "assistant":
            self.note_assistant(message)
        elif role == "toolResult":
            self.note_tool_result(message)

    def note_assistant(self, message: dict[str, Any]) -> None:
        stop_reason = message.get("stopReason")
        if isinstance(stop_reason, str):
            self.stop_reasons[stop_reason] += 1
        if message.get("errorMessage"):
            self.assistant_error_messages += 1
        add_usage(self.usage, message.get("usage"))
        model_key = (str(message.get("provider") or "?"), str(message.get("model") or "?"))
        bucket = self.usage_by_model.setdefault(model_key, {"assistant_messages": 0, "usage": new_usage()})
        bucket["assistant_messages"] += 1
        add_usage(bucket["usage"], message.get("usage"))
        content = message.get("content")
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "toolCall":
                    self.note_tool_call(item)

    # -- entry dispatch -------------------------------------------------

    def note_entry(self, entry: dict[str, Any]) -> None:
        self.entry_count += 1
        ts = entry_timestamp_ms(entry)
        if ts is not None:
            self.timestamps.append(ts)
        entry_type = entry.get("type")
        if entry_type == "session":
            session_id = entry.get("id")
            if isinstance(session_id, str):
                self.session_id = session_id
            version = entry.get("version")
            if isinstance(version, int):
                self.session_version = version
        elif entry_type == "message":
            self.note_message(entry)
        elif entry_type == "thinking_level_change":
            level = entry.get("thinkingLevel")
            if isinstance(level, str) and level not in self.thinking_levels:
                self.thinking_levels.append(level)
        elif entry_type == "model_change":
            provider = entry.get("provider")
            model_id = entry.get("modelId")
            if isinstance(provider, str) and isinstance(model_id, str):
                observed = [provider, model_id]
                if observed not in self.models_observed:
                    self.models_observed.append(observed)
        elif entry_type == "compaction":
            self.compaction_calls += 1
            before = entry.get("tokensBefore")
            if isinstance(before, (int, float)):
                self.compaction_tokens_before += before
            add_usage(self.compaction_usage, entry.get("usage"))
        elif entry_type == "custom":
            custom_type = entry.get("customType")
            if isinstance(custom_type, str):
                self.custom_types[custom_type] += 1

    # -- reporting ------------------------------------------------------

    def usage_with_compaction(self) -> dict[str, float]:
        merged = dict(self.usage)
        for key, value in self.compaction_usage.items():
            merged[key] = merged.get(key, 0) + value
        return merged

    def repeated(self, counter: Counter, minimum: int) -> list[dict[str, Any]]:
        return [
            {"target": key, "count": count}
            for key, count in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))
            if count >= minimum
        ]

    def to_record(self) -> dict[str, Any]:
        elapsed = None
        if self.timestamps:
            elapsed = round((max(self.timestamps) - min(self.timestamps)) / 1000.0, 2)
        http_lower_bound = (
            sum(self.network_calls.values()) + sum(self.gh_actions.values()) + self.raw_gh_commands
        )
        return {
            "label": self.label,
            "session_id": self.session_id,
            "session_version": self.session_version,
            "elapsed_seconds": elapsed,
            "models_observed": ["/".join(pair) for pair in self.models_observed],
            "thinking_levels": list(self.thinking_levels),
            "usage": dict(self.usage),
            "usage_by_model": {
                "/".join(key): {
                    "assistant_messages": value["assistant_messages"],
                    "usage": dict(value["usage"]),
                }
                for key, value in sorted(self.usage_by_model.items())
            },
            "compaction": {
                "calls": self.compaction_calls,
                "tokens_before": self.compaction_tokens_before,
                "usage": dict(self.compaction_usage),
            },
            "tokens_including_compaction": self.usage_with_compaction(),
            "tool_calls": {
                "total": sum(self.tool_calls.values()),
                "by_name": dict(sorted(self.tool_calls.items())),
            },
            "gh_cli": {
                "dispatches": sum(self.gh_actions.values()),
                "by_action": dict(sorted(self.gh_actions.items())),
                "raw_gh_commands": self.raw_gh_commands,
                "handoff_return_calls": self.handoff_return_calls,
                "repeated_targets": [
                    {"action": action, "target": target, "count": count}
                    for (action, target), count in sorted(
                        self.gh_targets.items(), key=lambda kv: (-kv[1], kv[0])
                    )
                    if count > 1
                ],
            },
            "network_tools": {
                "total": sum(self.network_calls.values()),
                "by_name": dict(sorted(self.network_calls.items())),
            },
            "http_api_lower_bound": http_lower_bound,
            "result_bytes_approx": {
                "doc_read": self.result_bytes["doc_read"],
                "gh_api": self.result_bytes["gh_api"],
                "bash_other": self.result_bytes["bash_other"],
                "network_tool": self.result_bytes["network_tool"],
                "unknown": self.result_bytes["unknown"],
                "total": sum(self.result_bytes.values()),
            },
            "refetch": {
                "read_paths": self.repeated(self.read_paths, 2),
                "fetch_urls": self.repeated(self.fetch_urls, 2),
            },
            "custom_types": dict(sorted(self.custom_types.items())),
            "errors": {
                "tool_results_with_error": self.result_error_count,
                "assistant_error_messages": self.assistant_error_messages,
            },
            "stop_reasons": dict(sorted(self.stop_reasons.items())),
            "skipped_lines": self.skipped_lines,
        }


USAGE_KEYS = ("input", "output", "cache_read", "cache_write", "reasoning", "total", "cost")


def build_totals(records: list[dict[str, Any]]) -> dict[str, Any]:
    totals: dict[str, Any] = {
        "sessions": len(records),
        "usage": new_usage(),
        "tokens_including_compaction": new_usage(),
        "compaction_calls": 0,
        "compaction_tokens_before": 0,
        "tool_calls_total": 0,
        "gh_dispatches": 0,
        "raw_gh_commands": 0,
        "handoff_return_calls": 0,
        "network_tool_calls": 0,
        "http_api_lower_bound": 0,
        "result_bytes_approx": 0,
        "errors": 0,
        "elapsed_seconds_sum": 0.0,
    }
    by_name: Counter[str] = Counter()
    for record in records:
        for key in USAGE_KEYS:
            totals["usage"][key] += record["usage"][key]
            totals["tokens_including_compaction"][key] += record["tokens_including_compaction"][key]
        totals["compaction_calls"] += record["compaction"]["calls"]
        totals["compaction_tokens_before"] += record["compaction"]["tokens_before"]
        totals["tool_calls_total"] += record["tool_calls"]["total"]
        for name, count in record["tool_calls"]["by_name"].items():
            by_name[name] += count
        gh = record["gh_cli"]
        totals["gh_dispatches"] += gh["dispatches"]
        totals["raw_gh_commands"] += gh["raw_gh_commands"]
        totals["handoff_return_calls"] += gh["handoff_return_calls"]
        totals["network_tool_calls"] += record["network_tools"]["total"]
        totals["http_api_lower_bound"] += record["http_api_lower_bound"]
        totals["result_bytes_approx"] += record["result_bytes_approx"]["total"]
        totals["errors"] += (
            record["errors"]["tool_results_with_error"] + record["errors"]["assistant_error_messages"]
        )
        if record["elapsed_seconds"] is not None:
            totals["elapsed_seconds_sum"] += record["elapsed_seconds"]
    totals["tool_calls_by_name"] = dict(sorted(by_name.items()))
    totals["elapsed_seconds_sum"] = round(totals["elapsed_seconds_sum"], 2)
    return totals


def parse_file(path: str, analysis: SessionAnalysis) -> None:
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                entry = json.loads(stripped)
            except ValueError:
                analysis.skipped_lines += 1
                continue
            if not isinstance(entry, dict):
                analysis.skipped_lines += 1
                continue
            analysis.note_entry(entry)


def render_text(doc: dict[str, Any]) -> str:
    lines: list[str] = []
    for record in doc["sessions"]:
        usage = record["tokens_including_compaction"]
        bytes_approx = record["result_bytes_approx"]
        lines.append(f"session {record['label']}")
        lines.append(
            "  id={} version={} elapsed={}s compaction={}x(before {})".format(
                record["session_id"],
                record["session_version"],
                record["elapsed_seconds"],
                record["compaction"]["calls"],
                record["compaction"]["tokens_before"],
            )
        )
        lines.append(
            "  tokens(incl compaction): in={} out={} cache_read={} cache_write={} reasoning={} total={} cost={:.6f}".format(
                usage["input"],
                usage["output"],
                usage["cache_read"],
                usage["cache_write"],
                usage["reasoning"],
                usage["total"],
                usage["cost"],
            )
        )
        lines.append(f"  models: {', '.join(record['models_observed']) or '-'}  thinking: {', '.join(record['thinking_levels']) or '-'}")
        lines.append(
            "  tool calls: {} {} | gh dispatches: {} {} | raw gh: {} | network: {} {} | handoff returns: {}".format(
                record["tool_calls"]["total"],
                record["tool_calls"]["by_name"],
                record["gh_cli"]["dispatches"],
                record["gh_cli"]["by_action"],
                record["gh_cli"]["raw_gh_commands"],
                record["network_tools"]["total"],
                record["network_tools"]["by_name"],
                record["gh_cli"]["handoff_return_calls"],
            )
        )
        lines.append(
            "  bytes approx: doc={} gh={} bash={} network={} unknown={} total={}".format(
                bytes_approx["doc_read"],
                bytes_approx["gh_api"],
                bytes_approx["bash_other"],
                bytes_approx["network_tool"],
                bytes_approx["unknown"],
                bytes_approx["total"],
            )
        )
        refetch = record["refetch"]
        lines.append(
            "  refetch: read paths repeated={} fetch urls repeated={} gh targets repeated={}".format(
                len(refetch["read_paths"]),
                len(refetch["fetch_urls"]),
                len(record["gh_cli"]["repeated_targets"]),
            )
        )
        lines.append(
            "  errors: tool results={} assistant messages={} | stop reasons: {}".format(
                record["errors"]["tool_results_with_error"],
                record["errors"]["assistant_error_messages"],
                record["stop_reasons"],
            )
        )
        if record["skipped_lines"]:
            lines.append(f"  skipped malformed lines: {record['skipped_lines']}")
    totals = doc["totals"]
    lines.append("totals ({} sessions)".format(totals["sessions"]))
    lines.append(
        "  tokens(incl compaction): in={} out={} cache_read={} cache_write={} reasoning={} total={} cost={:.6f}".format(
            totals["tokens_including_compaction"]["input"],
            totals["tokens_including_compaction"]["output"],
            totals["tokens_including_compaction"]["cache_read"],
            totals["tokens_including_compaction"]["cache_write"],
            totals["tokens_including_compaction"]["reasoning"],
            totals["tokens_including_compaction"]["total"],
            totals["tokens_including_compaction"]["cost"],
        )
    )
    lines.append(
        "  tool calls: {} {} | gh dispatches: {} | raw gh: {} | network: {} | http/api lower bound: {} | handoff returns: {}".format(
            totals["tool_calls_total"],
            totals["tool_calls_by_name"],
            totals["gh_dispatches"],
            totals["raw_gh_commands"],
            totals["network_tool_calls"],
            totals["http_api_lower_bound"],
            totals["handoff_return_calls"],
        )
    )
    lines.append(
        "  bytes approx total: {} | errors: {} | elapsed sum: {}s".format(
            totals["result_bytes_approx"],
            totals["errors"],
            totals["elapsed_seconds_sum"],
        )
    )
    return "\n".join(lines)


def fail(message: str) -> int:
    print(
        json.dumps(
            {
                "schema_version": SCHEMA_VERSION,
                "status": "failed",
                "error": {"code": ERROR_INVALID_INPUT, "message": message},
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Analyze pi session JSONL files for token, tool-call, and byte costs (offline)."
    )
    parser.add_argument("files", nargs="+", help="one or more pi session JSONL files")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    analyses: list[SessionAnalysis] = []
    for path in args.files:
        analysis = SessionAnalysis(path)
        try:
            parse_file(path, analysis)
        except OSError as error:
            return fail(f"cannot read {path}: {error}")
        analyses.append(analysis)

    document = {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "sessions": [analysis.to_record() for analysis in analyses],
        "totals": build_totals([analysis.to_record() for analysis in analyses]),
    }
    if args.json:
        print(json.dumps(document, ensure_ascii=False, separators=(",", ":")))
    else:
        print(render_text(document))
    return 0


if __name__ == "__main__":
    sys.exit(main())
