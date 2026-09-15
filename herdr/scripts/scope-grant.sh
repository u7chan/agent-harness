#!/usr/bin/env bash
# Record, list, and revoke human authorization for delegation edges that the
# server-state shape rules cannot derive (see lib/scope.sh).
#
# The grant file is a record of who allowed what for which task. It is not a
# forgeable capability and not a permission boundary: an agent process can
# read and write it directly. See references/technical-delegation-boundary.md.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scope.sh
source "$script_dir/lib/scope.sh"

usage() {
  {
    printf 'Usage:\n'
    printf '  %s grant --source <workspace> (--target <workspace> | --target-repo <path>) --by <name> [--task <ref>] [--ttl <seconds>]\n' "$0"
    printf '  %s list\n' "$0"
    printf '  %s revoke <grant-id>\n' "$0"
  } >&2
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

valid_workspace() {
  [[ "$1" =~ ^[[:alnum:]_.-]+$ ]]
}

valid_id() {
  [[ "$1" =~ ^[[:alnum:]_.:-]+$ ]]
}

# single_line <value>
#
# Reject empty values and embedded newlines, carriage returns, or tabs. Used
# for names and references that become grant record fields.
single_line() {
  [ -n "$1" ] || return 1
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  return 0
}

scope_path_or_fail() {
  local path
  path="$(scope_file)" || fail 'set HERDR_SCOPE_FILE or HOME to resolve the scope file'
  printf '%s\n' "$path"
}

grant_command() {
  local source='' target='' target_repo='' by='' task='' ttl=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || usage; source="$2"; shift 2 ;;
      --target) [ "$#" -ge 2 ] || usage; target="$2"; shift 2 ;;
      --target-repo) [ "$#" -ge 2 ] || usage; target_repo="$2"; shift 2 ;;
      --by) [ "$#" -ge 2 ] || usage; by="$2"; shift 2 ;;
      --task) [ "$#" -ge 2 ] || usage; task="$2"; shift 2 ;;
      --ttl) [ "$#" -ge 2 ] || usage; ttl="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  valid_workspace "$source" || fail '--source must be a workspace ID'
  single_line "$by" || fail '--by must be a non-empty single-line name'
  if [ -n "$target" ] && [ -n "$target_repo" ]; then
    fail 'use either --target or --target-repo, not both'
  fi
  if [ -z "$target" ] && [ -z "$target_repo" ]; then
    fail 'one of --target or --target-repo is required'
  fi
  if [ -n "$target" ]; then
    valid_workspace "$target" || fail '--target must be a workspace ID'
  fi
  if [ -n "$target_repo" ]; then
    target_repo="$(scope_resolve_path "$target_repo")"
    case "$target_repo" in
      /*) ;;
      *) fail '--target-repo must resolve to an absolute path' ;;
    esac
  fi
  if [ -n "$task" ]; then
    single_line "$task" || fail '--task must be a single-line reference'
  fi
  if [ -n "$ttl" ]; then
    [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || fail '--ttl must be a positive integer number of seconds'
  fi

  local scope_path result rc=0
  scope_path="$(scope_path_or_fail)"
  result="$(python3 -I -c '
import json, os, secrets, sys, tempfile
from datetime import datetime, timedelta, timezone

path, source, target, target_repo, task, by, ttl = sys.argv[1:8]


def timestamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


document = {"version": 1, "grants": []}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except Exception:
        sys.stdout.write("error:grant file is unreadable or not valid JSON: %s" % path)
        sys.exit(1)
    if not isinstance(document, dict) or not isinstance(document.get("grants"), list):
        sys.stdout.write("error:grant file has an unexpected shape: %s" % path)
        sys.exit(1)
    if not all(isinstance(entry, dict) for entry in document["grants"]):
        sys.stdout.write("error:grant file has an unexpected shape: %s" % path)
        sys.exit(1)

now = datetime.now(timezone.utc)
grant = {
    "id": "g-" + secrets.token_hex(6),
    "source_workspace": source,
}
if target_repo:
    grant["target_repo_root"] = target_repo
else:
    grant["target_workspace"] = target
grant["task"] = task
grant["granted_by"] = by
grant["created_at"] = timestamp(now)
grant["expires_at"] = timestamp(now + timedelta(seconds=int(ttl))) if ttl else None

document["grants"] = list(document["grants"])
document["grants"].append(grant)
document.setdefault("version", 1)

directory = os.path.dirname(path) or "."
try:
    os.makedirs(directory, mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".delegation-scope-", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
except Exception:
    sys.stdout.write("error:cannot write grant file: %s" % path)
    sys.exit(1)

sys.stdout.write(grant["id"])
' "$scope_path" "$source" "$target" "$target_repo" "$task" "$by" "$ttl" 2>/dev/null)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    case "$result" in
      error:*) fail "${result#error:}" ;;
      *) fail "cannot record the grant in $scope_path" ;;
    esac
  fi
  printf 'granted %s\n' "$result"
}

list_command() {
  local scope_path result rc=0
  scope_path="$(scope_path_or_fail)"
  result="$(python3 -I -c '
import json, os, sys
from datetime import datetime, timezone

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    grants = document["grants"]
    if not isinstance(grants, list):
        raise ValueError("grants is not a list")
except Exception:
    sys.stdout.write("error:grant file is unreadable or not valid JSON: %s" % path)
    sys.exit(1)

current = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for grant in grants:
    if not isinstance(grant, dict):
        continue
    expires_at = grant.get("expires_at")
    if isinstance(expires_at, str) and expires_at:
        state = "active" if expires_at > current else "expired"
        expires = expires_at
    else:
        state = "active"
        expires = "never"
    if isinstance(grant.get("target_workspace"), str) and grant["target_workspace"]:
        target = "workspace:" + grant["target_workspace"]
    elif isinstance(grant.get("target_repo_root"), str) and grant["target_repo_root"]:
        target = "repo:" + grant["target_repo_root"]
    else:
        target = "-"
    sys.stdout.write("\t".join([
        str(grant.get("id", "")),
        str(grant.get("source_workspace", "")),
        target,
        state,
        expires,
        str(grant.get("task", "")),
        str(grant.get("granted_by", "")),
    ]) + "\n")
' "$scope_path" 2>/dev/null)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    case "$result" in
      error:*) fail "${result#error:}" ;;
      *) fail "cannot read the grant file: $scope_path" ;;
    esac
  fi
  [ -z "$result" ] || printf '%s\n' "$result"
}

revoke_command() {
  local id="$1"
  valid_id "$id" || fail 'grant id must match [A-Za-z0-9_.:-]+'
  local scope_path result rc=0
  scope_path="$(scope_path_or_fail)"
  result="$(python3 -I -c '
import json, os, sys, tempfile

path, grant_id = sys.argv[1:3]
if not os.path.exists(path):
    sys.stdout.write("missing")
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    grants = document["grants"]
    if not isinstance(grants, list):
        raise ValueError("grants is not a list")
except Exception:
    sys.stdout.write("error:grant file is unreadable or not valid JSON: %s" % path)
    sys.exit(1)

kept = [entry for entry in grants if not (isinstance(entry, dict) and entry.get("id") == grant_id)]
if len(kept) == len(grants):
    sys.stdout.write("missing")
    sys.exit(0)

document["grants"] = kept
directory = os.path.dirname(path) or "."
try:
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=".delegation-scope-", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
except Exception:
    sys.stdout.write("error:cannot write grant file: %s" % path)
    sys.exit(1)

sys.stdout.write("revoked")
' "$scope_path" "$id" 2>/dev/null)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    case "$result" in
      error:*) fail "${result#error:}" ;;
      *) fail "cannot update the grant file: $scope_path" ;;
    esac
  fi
  case "$result" in
    revoked) printf 'revoked %s\n' "$id" ;;
    *) fail "grant not found: $id" ;;
  esac
}

subcommand="${1:-}"
shift || true
case "$subcommand" in
  grant|list|revoke)
    command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
    ;;
  *) usage ;;
esac
case "$subcommand" in
  grant) grant_command "$@" ;;
  list) [ "$#" -eq 0 ] || usage; list_command ;;
  revoke) [ "$#" -eq 1 ] || usage; revoke_command "$1" ;;
esac
