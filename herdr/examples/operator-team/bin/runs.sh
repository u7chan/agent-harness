#!/usr/bin/env bash
# List the live workspaces by display name, with their pane and agent state.
#
# Generalized shape, not a supported harness: the label it accepts comes from
# the label file, and the report is the display name a report should quote.
#
# Usage: runs.sh
set -euo pipefail

LABEL_FILE="${LABEL_FILE:-$HOME/operator-team/panes.conf}"
# shellcheck source=/dev/null
. "$LABEL_FILE"

herdr workspace list | python3 -I -c '
import json, subprocess, sys

prefix = sys.argv[1]
workspaces = json.load(sys.stdin)["result"]["workspaces"]
for workspace in workspaces:
    label = workspace.get("label") or "(no label)"
    if not (label == prefix or label.startswith(prefix + "-")):
        continue
    workspace_id = workspace["workspace_id"]
    listed = subprocess.run(
        ["herdr", "pane", "list", "--workspace", workspace_id],
        capture_output=True, text=True)
    panes = json.loads(listed.stdout)["result"]["panes"]
    states = {}
    for pane in panes:
        state = pane.get("agent_status", "?")
        states[state] = states.get(state, 0) + 1
    summary = ", ".join(f"{k} x {v}" for k, v in sorted(states.items())) or "-"
    print(f"  {label} ({workspace_id}) panes={len(panes)} [{summary}]")
' "$WORKSPACE_LABEL"
