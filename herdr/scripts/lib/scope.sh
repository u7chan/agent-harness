#!/usr/bin/env bash
# Workspace-scope rules for Herdr delegation.
#
# Sourced by parent-delegate-async.sh, child-return-result.sh,
# worktree-team-start.sh, and scope-grant.sh. The rules derive the allowed
# delegation edges from live `herdr workspace list` state and from
# human-recorded grants; the only caller-supplied values they trust are the
# two workspace IDs being classified.
#
# scope_classify prints exactly one line to stdout:
#
#   allow:same-workspace   source and target are the same workspace
#   allow:worktree-team    same repo_root, exactly one side a linked worktree
#   allow:granted          an unexpired grant covers the edge
#   reject:<reason>        every other outcome, including undecidable ones
#
# A classification outcome is data, not a transport failure: scope_classify
# exits 0 and prints a reject line when server state is unavailable or
# unusable. Wrappers must turn a reject into exit 3 with `scope-reject:
# <reason>` on stderr and no target write; scope_require does exactly that.
#
# The rules are an operational safeguard, not a permission boundary; see
# references/technical-delegation-boundary.md.
#
# Grants are matched by workspace ID only. Workspace IDs are server-local and
# the scope file is shared per user, so a grant recorded for one Herdr server
# also matches the same workspace-ID pair on another server of that user;
# cross-server delegation is out of scope and the file is per-user state.

# scope_reject <reason>
#
# Print the reject contract on stderr and exit 3. Intended for wrapper scripts:
# it terminates the caller.
scope_reject() {
  printf 'scope-reject: %s\n' "${1:-unknown}" >&2
  exit 3
}

# scope_file
#
# Print the delegation-scope file path:
# ${HERDR_SCOPE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/delegation-scope.json}
# Returns 1 without output when no base directory is available; the caller
# owns the failure message.
scope_file() {
  local path="${HERDR_SCOPE_FILE:-}"
  if [ -z "$path" ]; then
    local base="${XDG_CONFIG_HOME:-}"
    [ -n "$base" ] || base="${HOME:-}"
    [ -n "$base" ] || return 1
    path="$base/herdr/delegation-scope.json"
  fi
  printf '%s\n' "$path"
}

# scope_resolve_path <path>
#
# Print the resolved absolute path when the local system can resolve it, and
# the input unchanged otherwise. Used for grant --target-repo so a recorded
# repository path matches the repo_root reported by `herdr workspace list`.
scope_resolve_path() {
  local resolved=''
  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f -- "$1" 2>/dev/null)" || resolved=''
  fi
  if [ -n "$resolved" ]; then
    printf '%s\n' "$resolved"
  else
    printf '%s\n' "$1"
  fi
}

# scope_workspace_lookup <workspace-id> [<workspace-list-json>]
#
# Print one tab-separated line for the workspace found in `herdr workspace
# list` state:
#
#   <repo_root|->\t<true|false|unknown>
#
# repo_root is `-` when the workspace carries no worktree information, and
# is_linked_worktree is `unknown` when the field is absent.
#
# Exit status: 0 found, 1 not found, 2 `herdr workspace list` failed, 3
# unusable JSON. The optional second argument reuses one server-state snapshot
# for several lookups; without it the function fetches the list itself.
scope_workspace_lookup() {
  if [ "$#" -lt 1 ]; then
    printf 'Usage: scope_workspace_lookup <workspace-id> [<workspace-list-json>]\n' >&2
    return 2
  fi
  local workspace="$1"
  local json="${2:-}"
  if [ -z "$json" ]; then
    local rc=0
    json="$(herdr workspace list 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
      return 2
    fi
  fi
  printf '%s' "$json" | python3 -I -c '
import json, sys

workspace_id = sys.argv[1]
try:
    payload = json.load(sys.stdin)
    workspaces = payload["result"]["workspaces"]
    if not isinstance(workspaces, list):
        raise ValueError("workspaces is not a list")
except Exception:
    sys.exit(3)

for entry in workspaces:
    if isinstance(entry, dict) and entry.get("workspace_id") == workspace_id:
        worktree = entry.get("worktree")
        repo_root = worktree.get("repo_root") if isinstance(worktree, dict) else None
        linked = worktree.get("is_linked_worktree") if isinstance(worktree, dict) else None
        repo = repo_root if isinstance(repo_root, str) and repo_root else "-"
        if linked is True:
            state = "true"
        elif linked is False:
            state = "false"
        else:
            state = "unknown"
        sys.stdout.write("%s\t%s\n" % (repo, state))
        sys.exit(0)

sys.exit(1)
' "$workspace"
}

# _scope_lookup_reason <scope_workspace_lookup-status>
_scope_lookup_reason() {
  case "$1" in
    1) printf 'unknown-workspace' ;;
    2) printf 'workspace-list-failed' ;;
    3) printf 'workspace-list-invalid-json' ;;
    *) printf 'classify-failed' ;;
  esac
}

# scope_classify <source-workspace> <target-workspace>
#
# Print one allow: or reject: verdict line for the delegation edge
# source -> target. Always exits 0 for a classification outcome; only a usage
# error returns 2.
scope_classify() {
  if [ "$#" -ne 2 ]; then
    printf 'Usage: scope_classify <source-workspace> <target-workspace>\n' >&2
    return 2
  fi
  local source="$1" target="$2"
  local list_json list_rc=0 lookup_rc=0 info reason
  local source_repo='-' source_link='unknown' target_repo='-' target_link='unknown'
  local shape_reason='repo-mismatch' scope_path verdict

  if [ "$source" = "$target" ]; then
    printf 'allow:same-workspace\n'
    return 0
  fi

  list_json="$(herdr workspace list 2>/dev/null)" || list_rc=$?
  if [ "$list_rc" -ne 0 ] || [ -z "$list_json" ]; then
    printf 'reject:workspace-list-failed\n'
    return 0
  fi

  info="$(scope_workspace_lookup "$source" "$list_json")" || lookup_rc=$?
  if [ "$lookup_rc" -ne 0 ]; then
    reason="$(_scope_lookup_reason "$lookup_rc")"
    printf 'reject:%s\n' "$reason"
    return 0
  fi
  source_repo="${info%%$'\t'*}"
  source_link="${info##*$'\t'}"

  lookup_rc=0
  info="$(scope_workspace_lookup "$target" "$list_json")" || lookup_rc=$?
  if [ "$lookup_rc" -ne 0 ]; then
    reason="$(_scope_lookup_reason "$lookup_rc")"
    printf 'reject:%s\n' "$reason"
    return 0
  fi
  target_repo="${info%%$'\t'*}"
  target_link="${info##*$'\t'}"

  if [ "$source_repo" != '-' ] && [ "$source_repo" = "$target_repo" ]; then
    if [ "$source_link" != "$target_link" ] &&
      [ "$source_link" != 'unknown' ] && [ "$target_link" != 'unknown' ]; then
      printf 'allow:worktree-team\n'
      return 0
    fi
    if [ "$source_link" = true ] && [ "$target_link" = true ]; then
      shape_reason='sibling-worktrees'
    else
      shape_reason='duplicate-checkout'
    fi
  fi

  scope_path="$(scope_file)" || {
    printf 'reject:scope-file-unavailable\n'
    return 0
  }

  verdict="$(python3 -I -c '
import json, sys
from datetime import datetime, timezone

source, target, source_repo, target_repo, shape_reason, scope_path = sys.argv[1:7]

try:
    with open(scope_path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except FileNotFoundError:
    document = None
except Exception:
    print("reject:scope-file-invalid")
    sys.exit(0)

grants = []
if document is not None:
    if not isinstance(document, dict) or not isinstance(document.get("grants"), list):
        print("reject:scope-file-invalid")
        sys.exit(0)
    grants = [grant for grant in document["grants"] if isinstance(grant, dict)]

def covers(grant):
    grant_source = grant.get("source_workspace")
    grant_target = grant.get("target_workspace")
    grant_repo = grant.get("target_repo_root")
    if grant_source == source and grant_target == target:
        return True
    if grant_source == target and grant_target == source:
        return True
    if target_repo != "-" and grant_source == source and grant_repo == target_repo:
        return True
    if source_repo != "-" and grant_source == target and grant_repo == source_repo:
        return True
    return False

current = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

expired = False
for grant in grants:
    if not covers(grant):
        continue
    expires_at = grant.get("expires_at")
    if expires_at in (None, "") or (isinstance(expires_at, str) and expires_at > current):
        print("allow:granted")
        sys.exit(0)
    expired = True

if expired:
    print("reject:grant-expired")
else:
    print("reject:%s" % shape_reason)
' "$source" "$target" "$source_repo" "$target_repo" "$shape_reason" "$scope_path" 2>/dev/null)" || verdict='reject:classify-failed'

  verdict="${verdict%%$'\n'*}"
  case "$verdict" in
    allow:granted) ;;
    reject:*) ;;
    *) verdict='reject:classify-failed' ;;
  esac
  printf '%s\n' "$verdict"
}

# scope_require <source-workspace> <target-workspace>
#
# Classify the edge and return 0 when it is allowed; otherwise print the
# reject contract and exit 3. Wrapper scripts call this instead of inspecting
# scope_classify output themselves, so the reject contract has one definition.
scope_require() {
  if [ "$#" -ne 2 ]; then
    printf 'Usage: scope_require <source-workspace> <target-workspace>\n' >&2
    return 2
  fi
  local verdict
  verdict="$(scope_classify "$1" "$2")" || verdict='reject:classify-failed'
  case "$verdict" in
    allow:*) return 0 ;;
    reject:*) scope_reject "${verdict#reject:}" ;;
    *) scope_reject classify-failed ;;
  esac
}
