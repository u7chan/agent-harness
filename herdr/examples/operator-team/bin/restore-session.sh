#!/usr/bin/env bash
# Rebuild the standing composition in the workspace named by the label file.
#
# Generalized shape, not a supported harness: every label comes from the label
# file, and every path, agent name, provider, and model from the environment.
# The defaults are placeholders, so this file shows the sequence a restore runs
# rather than a supported install.
#
#   LABEL_FILE    label file with the workspace, role, tab, and plugin literals
#   CHECKOUT      checkout the role panes work in
#   RECORD_DIR    directory that holds roles/<role>.md and the records
#   AGENT_*       provider, model, thinking, and timeout given to `herdr agent start`
#
# Idempotent: a pane found by its label is reused, a running agent is never
# restarted, and a pane that already received its role document is not prompted
# again unless REPROMPT=1. --dry-run prints the write commands instead of
# running them.
set -euo pipefail

LABEL_FILE="${LABEL_FILE:-$HOME/operator-team/panes.conf}"
CHECKOUT="${CHECKOUT:-$PWD}"
RECORD_DIR="${RECORD_DIR:-$HOME/operator-team}"
AGENT_PROVIDER="${AGENT_PROVIDER:-<provider>}"
AGENT_MODEL="${AGENT_MODEL:-<model>}"
AGENT_THINKING="${AGENT_THINKING:-medium}"
AGENT_TIMEOUT_MS="${AGENT_TIMEOUT_MS:-60000}"
REPROMPT="${REPROMPT:-0}"

dry_run=0
[ "${1:-}" = --dry-run ] && dry_run=1

# The label file is the only place that holds a label literal.
# shellcheck source=/dev/null
. "$LABEL_FILE"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

field() { # $1 = dotted path; stdin = a Herdr JSON envelope
  python3 -I -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value if isinstance(value, str) else "")
' "$1"
}

pane_table() { # $1 = workspace id; TSV: pane_id, tab_id, label, agent
  herdr pane list --workspace "$1" | python3 -I -c '
import json, sys
for pane in json.load(sys.stdin)["result"]["panes"]:
    print("\t".join([pane.get("pane_id", ""), pane.get("tab_id", ""),
                     pane.get("label", ""), pane.get("agent", "")]))
'
}

plugin_linked() { # $1 = plugin id
  herdr plugin list --json | python3 -I -c '
import json, sys
wanted = sys.argv[1]
for plugin in json.load(sys.stdin)["result"]["plugins"]:
    if (plugin.get("plugin_id") or "") == wanted and plugin.get("enabled") is not False:
        raise SystemExit(0)
raise SystemExit(1)
' "$1"
}

# A restore writes only inside the caller's workspace, so this fails closed when
# the label resolves to another workspace instead of writing across the boundary.
[ "${HERDR_ENV:-}" = 1 ] || fail 'run this inside a Herdr pane (HERDR_ENV=1)'
[ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] ||
  fail 'HERDR_WORKSPACE_ID and HERDR_PANE_ID must both be set'

workspace_id="$(herdr workspace list | python3 -I -c '
import json, sys
wanted = sys.argv[1]
found = [w["workspace_id"] for w in json.load(sys.stdin)["result"]["workspaces"]
         if (w.get("label") or "") == wanted]
print(found[0] if len(found) == 1 else "")
' "$WORKSPACE_LABEL")"
[ -n "$workspace_id" ] || fail "no single workspace carries the label '$WORKSPACE_LABEL'"
[ "$workspace_id" = "$HERDR_WORKSPACE_ID" ] ||
  fail "the label '$WORKSPACE_LABEL' resolves to workspace $workspace_id, not the caller's $HERDR_WORKSPACE_ID; restore never writes outside the caller's workspace"
case "$HERDR_PANE_ID" in
  "$workspace_id":*) ;;
  *) fail "HERDR_PANE_ID '$HERDR_PANE_ID' does not belong to workspace $workspace_id" ;;
esac

table="$(pane_table "$workspace_id")"
pane_by_label() { printf '%s\n' "$table" | awk -F'\t' -v want="$1" '$3 == want { print $1 }'; }
agent_of() { printf '%s\n' "$table" | awk -F'\t' -v pane="$1" '$1 == pane { print $4 }'; }

role_keys=(orchestrator advisor scribe controller)
role_label=("$ORCHESTRATOR_LABEL" "$ADVISOR_LABEL" "$SCRIBE_LABEL" "$CONTROLLER_LABEL")
role_tab=("" "$ADVISOR_TAB" "$SCRIBE_TAB" "$CONTROLLER_TAB")

request_pane=""
for i in "${!role_keys[@]}"; do
  key="${role_keys[$i]}"
  label="${role_label[$i]}"
  tab="${role_tab[$i]}"
  document="$RECORD_DIR/roles/$key.md"
  [ -s "$document" ] || fail "$label: role document is missing or empty: $document"

  pane="$(pane_by_label "$label")"
  matches="$(pane_by_label "$label" | wc -l | tr -d ' ')"
  [ "$matches" -le 1 ] || fail "$label: $matches panes carry this label; resolve by hand"

  if [ -z "$pane" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'create %-24s tab=%s\n' "$label" "${tab:-<default tab>}"
      printf '  herdr tab create --workspace %s --cwd %s%s --no-focus\n' \
        "$workspace_id" "$CHECKOUT" "${tab:+ --label $tab}"
      printf '  herdr agent start %s --kind pi --pane <new-pane> --timeout %s -- --provider %s --model %s --thinking %s\n' \
        "$key" "$AGENT_TIMEOUT_MS" "$AGENT_PROVIDER" "$AGENT_MODEL" "$AGENT_THINKING"
      printf '  herdr pane rename <new-pane> %s\n' "$label"
      printf '  herdr agent prompt <new-pane> < %s\n' "$document"
      continue
    fi
    created="$(herdr tab create --workspace "$workspace_id" --cwd "$CHECKOUT" \
      ${tab:+--label "$tab"} --no-focus)"
    pane="$(printf '%s' "$created" | field result.root_pane.pane_id)"
    [ -n "$pane" ] || fail "$label: the tab create response carried no pane id"
  else
    printf 'reuse  %-24s %s\n' "$label" "$pane"
  fi

  if [ "$i" -eq 0 ]; then
    request_pane="$pane"
  fi

  kind="$(agent_of "$pane")"
  if [ -n "$kind" ] && [ "$kind" != pi ]; then
    fail "$label: pane $pane runs '$kind'; hand it back to the user instead of taking it over"
  fi
  if [ -z "$kind" ] && [ "$dry_run" -eq 0 ]; then
    if ! herdr agent start "$key" --kind pi --pane "$pane" --timeout "$AGENT_TIMEOUT_MS" \
      -- --provider "$AGENT_PROVIDER" --model "$AGENT_MODEL" --thinking "$AGENT_THINKING" >/dev/null; then
      printf 'WARN: %s: agent start reported a failure; check the pane before continuing\n' "$label" >&2
    fi
    herdr agent wait "$pane" --until idle --until done --until blocked \
      --timeout "$AGENT_TIMEOUT_MS" >/dev/null ||
      fail "$label: the agent did not become ready in $AGENT_TIMEOUT_MS ms"
  fi

  [ "$dry_run" -eq 0 ] && herdr pane rename "$pane" "$label"
  # The pane running this restore re-reads its own document.
  if [ "$pane" != "${HERDR_PANE_ID:-}" ] && [ "$dry_run" -eq 0 ] &&
    { [ -z "$kind" ] || [ "$REPROMPT" = 1 ]; }; then
    herdr agent prompt "$pane" "$(cat "$document")" >/dev/null
  fi
done

# Optional plugin pane beside the request pane: reuse it, skip it when the
# plugin is not linked, and never let the skip fail the restore.
if [ -n "${BOARD_LABEL:-}" ]; then
  board_pane="$(pane_by_label "$BOARD_LABEL")"
  if [ -n "$board_pane" ]; then
    printf 'reuse  %-24s %s\n' "$BOARD_LABEL" "$board_pane"
  elif [ "$dry_run" -eq 1 ]; then
    printf '  herdr plugin pane open --plugin %s --entrypoint %s --placement split --target-pane %s --direction right\n' \
      "$BOARD_PLUGIN" "$BOARD_ENTRYPOINT" "${request_pane:-<request pane>}"
  elif ! plugin_linked "$BOARD_PLUGIN"; then
    printf 'WARN: %s: plugin %s is not linked; skipping the pane\n' "$BOARD_LABEL" "$BOARD_PLUGIN" >&2
  else
    opened="$(herdr plugin pane open --plugin "$BOARD_PLUGIN" --entrypoint "$BOARD_ENTRYPOINT" \
      --placement split --target-pane "$request_pane" --direction right)"
    board_pane="$(printf '%s' "$opened" | field result.pane.pane_id)"
    [ -n "$board_pane" ] ||
      printf 'WARN: %s: the plugin opened but reported no pane id\n' "$BOARD_LABEL" >&2
  fi
fi
